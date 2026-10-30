-- Read-only media information window; one helper and owned request pair per player.
local mp = require('mp')
local utils = require('mp.utils')
local function expand(path) return mp.command_native({'expand-path', '~~/' .. path}) end
local paths = dofile(expand('script-modules/mpvnet-paths.lua'))
local active, closing, sequence = nil, false, 0
local instance = tostring(mp.get_property_number('pid', 0)) .. '-' .. string.format('%.0f', mp.get_time() * 1000000)
local function failure() mp.osd_message('无法打开媒体信息窗口，请检查配置包文件。', 3) end
local function write(path, value)
    local file = io.open(path, 'wb')
    if not file then return false end
    local written = file:write(value)
    local closed = file:close()
    return written and closed
end
local function cleanup(session)
    os.remove(session.path)
    os.remove(session.activation)
end
local function snapshot()
    local path = mp.get_property_native('path', '')
    local local_path = ''
    if type(path) ~= 'string' then path = '' end
    if path ~= '' and not path:find('://', 1, true) and not path:lower():find('\\\\.\\pipe\\', 1, true) then
        local candidate = path
        if not candidate:match('^%a:[\\/]') and not candidate:match('^\\\\') then
            candidate = utils.join_path(mp.get_property_native('working-directory', ''), candidate)
        end
        -- File probing belongs to the helper, not the playback thread. Keep
        -- missing local paths local so their failure is not mislabeled network.
        if candidate:match('^%a:[\\/]') or candidate:match('^\\\\') then local_path = candidate end
    end
    local title = mp.get_property_native('media-title', '')
    if path == '' then title = '尚未打开媒体' end
    if local_path == '' and type(title) == 'string' and title == mp.get_property_native('filename', '') then
        title = title:gsub('[?#].*$', '')
    end
    if type(title) ~= 'string' or title == '' or title:find('://',1,true) then
        title = local_path ~= '' and (local_path:match('[^/\\]+$') or '本地媒体') or (path ~= '' and '网络媒体' or '尚未打开媒体')
    end
    local properties = {}
    local names = {duration='duration',file_size='file-size',container='file-format',
        video_format='video-format',width='video-params/w',height='video-params/h',fps='container-fps',
        aspect='video-params/aspect',video_bitrate='video-bitrate',total_bitrate='container-bitrate',
        audio_codec='audio-codec-name',sample_rate='audio-params/samplerate',channels='audio-params/channel-count',
        gamma='video-params/gamma'}
    for key,name in pairs(names) do
        local value = mp.get_property_native(name)
        if type(value)=='number' and value==value and math.abs(value)~=math.huge or type(value)=='string' then properties[key]=value end
    end
    properties.tracks = {}
    for _,track in ipairs(mp.get_property_native('track-list',{})) do
        local item={}
        for _,key in ipairs({'id','type','lang','selected','codec','audio-channels','demux-samplerate'}) do item[key]=track[key] end
        properties.tracks[#properties.tracks+1]=item
    end
    return {has_media=path~='',local_path=local_path,title=title:sub(1,4096),properties=properties}
end
local open
open = function()
    if closing then return end
    if active then
        if active.media_key ~= mp.get_property_native('path', '') then
            -- Keep the displayed snapshot stable while reading. An explicit
            -- open for another media replaces it only after the old helper exits.
            if not active.reopen then
                active.reopen = true
                if active.request then mp.abort_async_command(active.request) end
            end
            return
        end
        local serial = active.serial + 1
        if write(active.activation, tostring(serial)) then active.serial = serial else failure() end
        return
    end
    local directory = os.getenv('TEMP') or os.getenv('TMP')
    local absolute = directory and (directory:match('^%a:[\\/]') or directory:match('^\\\\'))
    local info = absolute and utils.file_info(directory)
    if not info or not info.is_dir then failure(); return end
    sequence = sequence + 1
    local token = instance .. '-' .. sequence
    local path = utils.join_path(directory, 'mpvnet-media-info-' .. token .. '.json')
    local session = {path=path, activation=path .. '.activate', serial=1, media_key=mp.get_property_native('path', '')}
    local payload = snapshot()
    payload.schema=1;payload.token=token;payload.parent_pid=mp.get_property_number('pid',0)
    payload.activation_path=session.activation
    if not write(path, utils.format_json(payload)) or not write(session.activation, '1') then
        cleanup(session); failure(); return
    end
    active = session
    local launched, request = pcall(mp.command_native_async, {name='subprocess', args={paths.powershell(),
        '-NoProfile', '-NonInteractive', '-STA', '-ExecutionPolicy', 'Bypass', '-File',
        expand('helpers/media-info-window.ps1'), '-RequestPath', path},
        capture_stdout=true, capture_stderr=false, playback_only=false}, function(ok, result)
        cleanup(session)
        if active ~= session then return end
        active = nil
        if closing then return end
        if session.reopen then open(); return end
        local reply = ok and result and result.status == 0 and utils.parse_json(result.stdout or '')
        if type(reply) ~= 'table' or reply.ok ~= true then failure(); return end
        local seen = tonumber(reply.last_seen_serial)
        -- An open received after the old window stopped polling belongs to a new window.
        if seen and seen >= 0 and seen < session.serial then open() end
    end)
    if not launched or not request then
        cleanup(session)
        if active == session then active = nil; failure() end
    else session.request = request end
end
mp.add_key_binding(nil, 'open', open)
mp.register_script_message('open', open)
mp.register_event('shutdown', function()
    closing = true
    if active then
        local session = active
        active = nil
        if session.request then mp.abort_async_command(session.request) end
        cleanup(session)
    end
end)
