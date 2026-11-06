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

local function feedback(text, duration)
    if shutting_down then return end
    duration = duration or 4
    if mp.get_property_native('user-data/mpvnet/feedback/ready') == true then
        mp.commandv('script-message-to', 'feedback_osd', 'show', text, tostring(duration))
    else
        mp.osd_message(text, duration)
    end
end

local function export_status(active)
    mp.set_property_native('user-data/mpvnet/feedback/capture', active and '正在导出片段…' or '')
    if active then feedback('正在导出片段…', 1.5) end
end

local failure_reasons = {
    ['ffmpeg-missing'] = '未找到 FFmpeg', ['file-missing'] = '找不到文件',
    ['invalid-range'] = '片段范围无效', ['invalid-path'] = '输出路径无效',
    ['access-denied'] = '权限不足', ['clipboard'] = '复制失败',
    ['directory'] = '文件夹不可用', ['temporary-file'] = '请检查临时文件夹',
    ['no-video'] = '请先打开视频',
    ['stream-unavailable'] = '此视频无法导出片段\n请换一个视频',
    ['save'] = '无法保存文件', ['encode-mp4'] = 'MP4 生成失败',
    ['encode-webp'] = 'WebP 生成失败', ['encode-gif'] = 'GIF 生成失败',
    ['cancelled'] = '操作已取消',
}
local legacy_phases = {ffmpeg = 'ffmpeg-missing', clipboard = 'clipboard', directory = 'directory',
    staging = 'temporary-file', commit = 'save', mp4 = 'encode-mp4', webp = 'encode-webp', gif = 'encode-gif'}

local function report_failure(fallback, data)
    data = type(data) == 'table' and data or {}
    local reason = data.reason or legacy_phases[data.phase]
    local detail = failure_reasons[reason]
    -- Log only our allowlisted codes, not helper text, paths or signed media URLs.
    mp.msg.warn('Capture failed: ' .. (detail and reason or 'worker'))
    local text = detail and (fallback .. '\n' .. detail) or fallback
    if reason == 'stream-unavailable' or reason == 'clipboard' or reason == 'cancelled'
        or reason == 'encode-mp4' or reason == 'encode-webp' or reason == 'encode-gif' then
        text = detail
    elseif reason == 'ffmpeg-missing' and fallback == '导出失败' then
        text = '无法导出\n' .. detail
    elseif reason == 'access-denied' then
        text = fallback .. '：' .. detail
    end
    feedback(text)
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
    export_status(payload.action == 'clip')
    publish()
    payload.parent_pid = mp.get_property_number('pid', 0)
    pending_job = payload.action ~= 'copy' and token() or nil
    payload.job_id = pending_job
    -- mpv's Win32 subprocess stdin_data does not reliably reach the worker.
    -- Keep media URLs/headers in an owned UTF-8 Temp file, never command args.
    pending_payload = write_payload(payload)
    if not pending_payload then
        busy = false
        export_status(false)
        pending_clip = nil
        if pending_png then os.remove(pending_png) end
        pending_png, pending_job = nil, nil
        publish()
        report_failure(failure, {reason = 'temporary-file'})
        return
    end
    local request_payload = pending_payload
    mp.command_native_async({name = 'subprocess', args = {
        powershell, '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', helper,
        '-PayloadPath', pending_payload,
    }, capture_stdout = true,
        capture_stderr = false, playback_only = false}, function(ok, result)
        if pending_payload ~= request_payload then return end
        busy = false
        export_status(false)
        pending_clip = nil
        local data = result and utils.parse_json(result.stdout or '')
        data = type(data) == 'table' and data or nil
        if ok and result and result.status == 0 and data and data.ok then
            if done then done(data) end
            feedback(success, 2)
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
    if not payload_path then report_failure('无法打开输出文件夹', {reason = 'temporary-file'}); return end
    mp.command_native_async({name = 'subprocess', args = {
        powershell, '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', helper,
        '-PayloadPath', payload_path,
    }, capture_stdout = true, capture_stderr = false, playback_only = false}, function(ok, result)
        os.remove(payload_path)
        local data = result and utils.parse_json(result.stdout or '')
        data = type(data) == 'table' and data or nil
        if not (ok and result and result.status == 0 and data and data.ok) then
            report_failure('无法打开输出文件夹', data)
        end
    end)
end

local function screenshot()
    if busy then feedback('正在处理，请稍候', 2); return end
    if mp.get_property_native('idle-active') or not mp.get_property_native('video-out-params') then
        report_failure('无法截图', {reason = 'no-video'}); return
    end
    local temp = os.getenv('TEMP') or os.getenv('TMP')
    if not temp then
        report_failure('无法截图', {reason = 'temporary-file'}); return
    end
    pending_png = utils.join_path(temp, 'mpvnet-capture-' .. token() .. '.png')
    local ok, _, err = pcall(mp.command_native, {'screenshot-to-file', pending_png, 'video'})
    if not ok or err or not utils.file_info(pending_png) then
        os.remove(pending_png)
        pending_png = nil
        feedback('无法截图')
        return
    end
    run({action = 'screenshot', title = title(), temp_png = pending_png},
        '截图已保存', '无法截图')
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
    if busy then feedback('正在处理，请稍候', 2); return end
    local pos = mp.get_property_number('time-pos')
    if not pos or pos < 0 then feedback('导出失败'); return end
    if not a then a = pos; publish(); feedback('片段起点 A  ' .. clock(a), 1.5); return end
    if pos <= a then feedback('片段终点要晚于起点'); return end
    local main = mp.get_property('stream-open-filename') or mp.get_property('path')
    local video_track = selected('video')
    if not video_track then report_failure('导出失败', {reason = 'no-video'}); return end
    local video = track_source(video_track, main)
    local audio_track = selected('audio')
    local audio = audio_track and track_source(audio_track, main)
    if not video or (audio_track and not audio) then
        report_failure('导出失败', {reason = 'stream-unavailable'}); return
    end
    local format = clipboard_format -- Freeze the choice for this asynchronous export.
    local payload = {action = 'clip', title = title(), start = a, finish = pos,
        clipboard_format = format,
        video = video, audio = audio, audio_delay = mp.get_property_number('audio-delay', 0),
        headers = mp.get_property_native('http-header-fields', {}),
        user_agent = mp.get_property('user-agent'), referrer = mp.get_property('referrer')}
    pending_clip = {start = a, finish = pos, media_generation = media_generation}
    a = nil
    run(payload, format:upper() .. ' 已保存并复制', '导出失败', function(data)
        latest = {format = format, file = data.files[format]}
    end)
end

mp.register_script_message('set-default-format', function(format)
    if format ~= 'webp' and format ~= 'gif' and format ~= 'mp4' then return end
    clipboard_format = format
    publish()
end)

local function copy_latest()
    if busy then feedback('正在处理，请稍候', 2); return end
    if not latest or not latest.file then feedback('暂无可复制的片段'); return end
    run({action = 'copy', file = latest.file}, latest.format:upper() .. ' 已复制', '复制失败')
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
    export_status(false)
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
