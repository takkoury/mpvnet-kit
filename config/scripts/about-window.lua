-- Read-only about window; one helper and owned request pair per player.
local mp = require('mp')
local utils = require('mp.utils')
local function expand(path) return mp.command_native({'expand-path', '~~/' .. path}) end
local paths = dofile(expand('script-modules/mpvnet-paths.lua'))
local active, closing, sequence = nil, false, 0
local instance = tostring(mp.get_property_number('pid', 0)) .. '-' .. string.format('%.0f', mp.get_time() * 1000000)
local function failure() mp.osd_message('无法打开关于窗口，请检查配置包文件。', 3) end
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
local function version(name)
    -- user-data string properties are JSON-quoted in the textual API.
    local value = mp.get_property_native(name, '')
    return type(value) == 'string' and value:sub(1, 2048) or ''
end
local open
open = function()
    if closing then return end
    if active then
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
    local path = utils.join_path(directory, 'mpvnet-about-' .. token .. '.json')
    local session = {path=path, activation=path .. '.activate', serial=1}
    local payload = {schema=1, token=token, parent_pid=mp.get_property_number('pid', 0),
        activation_path=session.activation, host_version=version('user-data/frontend/version'),
        mpv_version=version('mpv-version'), ffmpeg_version=version('ffmpeg-version')}
    if not write(path, utils.format_json(payload)) or not write(session.activation, '1') then
        cleanup(session); failure(); return
    end
    active = session
    local launched, request = pcall(mp.command_native_async, {name='subprocess', args={paths.powershell(),
        '-NoProfile', '-NonInteractive', '-STA', '-ExecutionPolicy', 'Bypass', '-File',
        expand('helpers/about-window.ps1'), '-RequestPath', path},
        capture_stdout=true, capture_stderr=false, playback_only=false}, function(ok, result)
        cleanup(session)
        if active ~= session then return end
        active = nil
        if closing then return end
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
