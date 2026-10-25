-- Native source screenshots and asynchronous source-timeline clips.
-- All media data goes to the helper in owned UTF-8 JSON files; never shell code.
local mp = require('mp')
local utils = require('mp.utils')
local paths = dofile(mp.command_native({'expand-path', '~~/script-modules/mpvnet-paths.lua'}))
local a, busy, latest, sequence = nil, false, nil, 0
local media_generation, pending_clip = 0, nil
-- The existing message/property name is retained; this now selects the only
-- exported format as well as the file copied after success.
local clipboard_format = 'webp'
local shutting_down = false
local helper = mp.command_native({'expand-path', '~~/helpers/capture-media.ps1'})
local powershell = paths.powershell()
local pending_png, pending_job, pending_payload

local function publish()
    mp.set_property_native('user-data/mpvnet/capture', {
        busy = busy, a = a, has_clip = latest ~= nil, clipboard_format = clipboard_format,
        latest_format = latest and latest.format or nil,
        media_generation = media_generation, pending_clip = pending_clip,
    })
end

local function feedback(text)
    if not shutting_down then mp.osd_message(text, 1) end
end

local failure_reasons = {
    ['ffmpeg-missing'] = 'FFMPEG NOT FOUND', ['file-missing'] = 'FILE NOT FOUND',
    ['invalid-range'] = 'INVALID RANGE', ['invalid-path'] = 'INVALID PATH',
    ['access-denied'] = 'ACCESS DENIED', ['clipboard'] = 'CLIPBOARD FAILED',
    ['directory'] = 'FOLDER UNAVAILABLE', ['temporary-file'] = 'TEMP UNAVAILABLE · CHECK TEMP FOLDER',
    ['no-video'] = 'NO VIDEO · OPEN A VIDEO',
    ['stream-unavailable'] = 'STREAM NOT EXPORTABLE · TRY ANOTHER VIDEO',
    ['save'] = 'CANNOT SAVE FILE', ['encode-mp4'] = 'MP4 ENCODING FAILED',
    ['encode-webp'] = 'WEBP ENCODING FAILED', ['encode-gif'] = 'GIF ENCODING FAILED',
    ['cancelled'] = 'CANCELLED',
}
local legacy_phases = {ffmpeg = 'ffmpeg-missing', clipboard = 'clipboard', directory = 'directory',
    staging = 'temporary-file', commit = 'save', mp4 = 'encode-mp4', webp = 'encode-webp', gif = 'encode-gif'}

local function report_failure(fallback, data)
    data = type(data) == 'table' and data or {}
    local reason = data.reason or legacy_phases[data.phase]
    local detail = failure_reasons[reason]
    -- Log only our allowlisted codes, not helper text, paths or signed media URLs.
    mp.msg.warn('Capture failed: ' .. (detail and reason or 'worker'))
    feedback(detail and (fallback .. ' · ' .. detail) or fallback)
end

local function clock(value)
    local ms = math.floor(value * 1000 + 0.5)
    return string.format('%02d:%02d:%02d.%03d', math.floor(ms / 3600000),
        math.floor(ms / 60000) % 60, math.floor(ms / 1000) % 60, ms % 1000)
end

local function token()
    sequence = sequence + 1
    return string.format('%.0f-%d-%.0f', mp.get_property_number('pid', 0), sequence,
        math.floor(mp.get_time() * 1000000))
end

local function title()
    local value = mp.get_property('media-title') or mp.get_property('filename') or 'Media'
    if value:find('://', 1, true) or value == mp.get_property('filename') then
        value = value:gsub('[?#].*$', '')
    end
    return value
end

local function write_payload(payload)
    paths.capture_payload(payload)
    local temp = os.getenv('TEMP') or os.getenv('TMP')
    if not temp then return nil end
    local path = utils.join_path(temp, 'mpvnet-capture-payload-' .. token() .. '.json')
    local file = io.open(path, 'wb')
    if not file then return nil end
    local written = file:write(utils.format_json(payload))
    local closed = file:close()
    if not written or not closed then os.remove(path); return nil end
    return path
end

local function run(payload, success, failure, done)
    busy = true
    publish()
    payload.parent_pid = mp.get_property_number('pid', 0)
    pending_job = payload.action ~= 'copy' and token() or nil
    payload.job_id = pending_job
    -- mpv's Win32 subprocess stdin_data does not reliably reach the worker.
    -- Keep media URLs/headers in an owned UTF-8 Temp file, never command args.
    pending_payload = write_payload(payload)
    if not pending_payload then
        busy = false
        pending_clip = nil
        if pending_png then os.remove(pending_png) end
        pending_png, pending_job = nil, nil
        publish()
        report_failure(failure, {reason = 'temporary-file'})
        return
    end
    mp.command_native_async({name = 'subprocess', args = {
        powershell, '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', helper,
        '-PayloadPath', pending_payload,
    }, capture_stdout = true,
        capture_stderr = false, playback_only = false}, function(ok, result)
        busy = false
        pending_clip = nil
        local data = result and utils.parse_json(result.stdout or '')
        data = type(data) == 'table' and data or nil
        if ok and result and result.status == 0 and data and data.ok then
            if done then done(data) end
            feedback(success)
        else
            report_failure(failure, data)
        end
        if pending_png then os.remove(pending_png) end
        if pending_payload then os.remove(pending_payload) end
        pending_png, pending_job, pending_payload = nil, nil, nil
        publish()
    end)
end

-- Directory opening owns its payload and never participates in the export job state.
local function open_folder()
    local payload_path = write_payload({action = 'open-directory'})
    if not payload_path then report_failure('CAPTURE FOLDER FAILED', {reason = 'temporary-file'}); return end
    mp.command_native_async({name = 'subprocess', args = {
        powershell, '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', helper,
        '-PayloadPath', payload_path,
    }, capture_stdout = true, capture_stderr = false, playback_only = false}, function(ok, result)
        os.remove(payload_path)
        local data = result and utils.parse_json(result.stdout or '')
        data = type(data) == 'table' and data or nil
        if not (ok and result and result.status == 0 and data and data.ok) then
            report_failure('CAPTURE FOLDER FAILED', data)
        end
    end)
end

local function screenshot()
    if busy then feedback('CAPTURE BUSY'); return end
    if mp.get_property_native('idle-active') or not mp.get_property_native('video-out-params') then
        report_failure('SCREENSHOT FAILED', {reason = 'no-video'}); return
    end
    local temp = os.getenv('TEMP') or os.getenv('TMP')
    if not temp then
        report_failure('SCREENSHOT FAILED', {reason = 'temporary-file'}); return
    end
    pending_png = utils.join_path(temp, 'mpvnet-capture-' .. token() .. '.png')
    local ok, _, err = pcall(mp.command_native, {'screenshot-to-file', pending_png, 'video'})
    if not ok or err or not utils.file_info(pending_png) then
        os.remove(pending_png)
        pending_png = nil
        feedback('SCREENSHOT FAILED')
        return
    end
    run({action = 'screenshot', title = title(), temp_png = pending_png},
        'SCREENSHOT SAVED', 'SCREENSHOT FAILED')
end

local function absolute_source(source)
    if not source or source == '' then return nil end
    if source:match('^%a[%w+.-]*://') or source:match('^%a:[/\\]')
        or source:match('^[/\\]') then return source end
    return utils.join_path(mp.get_property('working-directory', ''), source)
end

local function selected(kind)
    local id = mp.get_property_native(kind == 'video' and 'vid' or 'aid')
    for _, track in ipairs(mp.get_property_native('track-list', {})) do
        if track.type == kind and tostring(track.id) == tostring(id) then return track end
    end
end

local function track_source(track, main)
    -- ff-index is the demuxer's actual stream index, including external audio.
    -- Guessing a different stream would silently export the wrong track.
    if not track or type(track['ff-index']) ~= 'number' or track['ff-index'] < 0 then return nil end
    local source = absolute_source(track.external and track['external-filename'] or main)
    if not source then return nil end
    return {path = source, index = track['ff-index']}
end

local function clip_point()
    if busy then feedback('CAPTURE BUSY'); return end
    local pos = mp.get_property_number('time-pos')
    if not pos or pos < 0 then feedback('CLIP FAILED'); return end
    if not a then a = pos; publish(); feedback('CLIP A ' .. clock(a)); return end
    if pos <= a then feedback('CLIP B MUST BE AFTER A'); return end
    local main = mp.get_property('stream-open-filename') or mp.get_property('path')
    local video_track = selected('video')
    if not video_track then report_failure('CLIP FAILED', {reason = 'no-video'}); return end
    local video = track_source(video_track, main)
    local audio_track = selected('audio')
    local audio = audio_track and track_source(audio_track, main)
    if not video or (audio_track and not audio) then
        report_failure('CLIP FAILED', {reason = 'stream-unavailable'}); return
    end
    local format = clipboard_format -- Freeze the choice for this asynchronous export.
    local payload = {action = 'clip', title = title(), start = a, finish = pos,
        clipboard_format = format,
        video = video, audio = audio, audio_delay = mp.get_property_number('audio-delay', 0),
        headers = mp.get_property_native('http-header-fields', {}),
        user_agent = mp.get_property('user-agent'), referrer = mp.get_property('referrer')}
    pending_clip = {start = a, finish = pos, media_generation = media_generation}
    a = nil
    feedback('CLIP EXPORTING')
    run(payload, 'CLIP SAVED · ' .. format:upper() .. ' COPIED', 'CLIP FAILED', function(data)
        latest = {format = format, file = data.files[format]}
    end)
end

mp.register_script_message('set-default-format', function(format)
    if format ~= 'webp' and format ~= 'gif' and format ~= 'mp4' then return end
    clipboard_format = format
    publish()
end)

local function copy_latest()
    if busy then feedback('CAPTURE BUSY'); return end
    if not latest or not latest.file then feedback('NO CLIP'); return end
    run({action = 'copy', file = latest.file}, latest.format:upper() .. ' COPIED', 'CLIP FAILED')
end

mp.add_key_binding(nil, 'screenshot', screenshot)
mp.add_key_binding(nil, 'open-folder', open_folder)
mp.add_key_binding(nil, 'clip-point', clip_point)
mp.add_key_binding(nil, 'copy-latest', copy_latest)
local function clear_media_range()
    media_generation = media_generation + 1
    a, pending_clip = nil, nil
    publish()
end
mp.register_event('start-file', clear_media_range)
mp.register_event('end-file', clear_media_range)
mp.register_event('shutdown', function()
    shutting_down = true
    -- Allow the worker to stop its own FFmpeg and remove staging before mpv
    -- terminates subprocesses. No unrelated process is killed.
    if pending_job then
        local cancel_payload = write_payload({action = 'cancel', job_id = pending_job})
        if cancel_payload then
            mp.command_native({name = 'subprocess', args = {
                powershell, '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', helper,
                '-PayloadPath', cancel_payload,
            }, capture_stdout = true, capture_stderr = false, playback_only = false})
            os.remove(cancel_payload)
        end
    end
    if pending_png then os.remove(pending_png) end
    if pending_payload then os.remove(pending_payload) end
end)
publish()
