-- Native source screenshots and asynchronous source-timeline clips.
-- All media data goes to the helper in owned UTF-8 JSON files; never shell code.
local mp = require('mp')
local utils = require('mp.utils')
local paths = dofile(mp.command_native({'expand-path', '~~/script-modules/mpvnet-paths.lua'}))
local a, busy, latest, sequence = nil, false, nil, 0
local clipboard_format = 'webp'
local shutting_down = false
local helper = mp.command_native({'expand-path', '~~/helpers/capture-media.ps1'})
local powershell = paths.powershell()
local pending_png, pending_job, pending_payload

local function publish()
    mp.set_property_native('user-data/mpvnet/capture', {
        busy = busy, a = a, has_clip = latest ~= nil, clipboard_format = clipboard_format,
    })
end

local function feedback(text)
    if not shutting_down then mp.osd_message(text, 1) end
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
        if pending_png then os.remove(pending_png) end
        pending_png, pending_job = nil, nil
        publish()
        feedback(failure)
        return
    end
    mp.command_native_async({name = 'subprocess', args = {
        powershell, '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', helper,
        '-PayloadPath', pending_payload,
    }, capture_stdout = true,
        capture_stderr = false, playback_only = false}, function(ok, result)
        busy = false
        local data = result and utils.parse_json(result.stdout or '')
        if ok and result and result.status == 0 and data and data.ok then
            if done then done(data) end
            feedback(success)
        else
            -- The helper reports phase codes only, never input URLs or headers.
            mp.msg.warn('Capture failed: ' .. tostring(data and data.phase or 'worker'))
            feedback(payload.action == 'clip' and data and data.phase == 'ffmpeg'
                and 'CLIP FAILED · FFMPEG NOT FOUND' or failure)
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
    if not payload_path then feedback('CAPTURE FOLDER FAILED'); return end
    mp.command_native_async({name = 'subprocess', args = {
        powershell, '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', helper,
        '-PayloadPath', payload_path,
    }, capture_stdout = true, capture_stderr = false, playback_only = false}, function(ok, result)
        os.remove(payload_path)
        local data = result and utils.parse_json(result.stdout or '')
        if not (ok and result and result.status == 0 and data and data.ok) then
            feedback('CAPTURE FOLDER FAILED')
        end
    end)
end

local function screenshot()
    if busy then feedback('CAPTURE BUSY'); return end
    if not mp.get_property_native('video-out-params') then feedback('SCREENSHOT FAILED'); return end
    local temp = os.getenv('TEMP') or os.getenv('TMP')
    if not temp then feedback('SCREENSHOT FAILED'); return end
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
    local video = track_source(selected('video'), main)
    local audio_track = selected('audio')
    local audio = audio_track and track_source(audio_track, main)
    if not video or (audio_track and not audio) then feedback('CLIP FAILED'); return end
    local format = clipboard_format -- Freeze the choice for this asynchronous export.
    local payload = {action = 'clip', title = title(), start = a, finish = pos,
        clipboard_format = format,
        video = video, audio = audio, audio_delay = mp.get_property_number('audio-delay', 0),
        headers = mp.get_property_native('http-header-fields', {}),
        user_agent = mp.get_property('user-agent'), referrer = mp.get_property('referrer')}
    a = nil
    feedback('CLIP EXPORTING')
    run(payload, 'CLIP SAVED · ' .. format:upper() .. ' COPIED', 'CLIP FAILED', function(data) latest = data.files end)
end

mp.register_script_message('set-default-format', function(format)
    if format ~= 'webp' and format ~= 'gif' and format ~= 'mp4' then return end
    clipboard_format = format
    publish()
end)

local function copy(kind)
    if busy then feedback('CAPTURE BUSY'); return end
    if not latest or not latest[kind] then feedback('NO CLIP'); return end
    run({action = 'copy', file = latest[kind]}, kind:upper() .. ' COPIED', 'CLIP FAILED')
end

mp.add_key_binding(nil, 'screenshot', screenshot)
mp.add_key_binding(nil, 'open-folder', open_folder)
mp.add_key_binding(nil, 'clip-point', clip_point)
for _, kind in ipairs({'webp', 'gif', 'mp4'}) do
    local format = kind
    mp.add_key_binding(nil, 'copy-' .. kind, function() copy(format) end)
end
mp.register_event('start-file', function() a = nil; publish() end)
mp.register_event('end-file', function() a = nil; publish() end)
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
