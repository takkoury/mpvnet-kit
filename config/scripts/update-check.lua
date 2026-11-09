-- Startup scheduling and the owned helper session; network/cache/UI live in KitUpdate.
local mp = require('mp')
local utils = require('mp.utils')
local function expand(path) return mp.command_native({'expand-path', '~~/' .. path}) end
local settings = dofile(expand('script-modules/user-settings.lua'))
local active, closing, sequence, timer = nil, false, 0, nil
local ready, automatic_enabled, startup_consumed = false, true, false
local instance = tostring(mp.get_property_number('pid', 0)) .. '-' .. string.format('%.0f', mp.get_time() * 1000000)
local function failure() mp.osd_message('无法检查更新，请稍后重试或检查配置包文件。', 3) end
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
local function stop_automatic()
    if timer then timer:kill(); timer = nil end
    if active and active.automatic then
        local session = active
        active = nil
        if session.request then mp.abort_async_command(session.request) end
        cleanup(session)
    end
end
local open
open = function(automatic)
    if closing then return end
    if not automatic then startup_consumed = true; if timer then timer:kill(); timer = nil end end
    if active then
        if automatic then return end
        local serial = active.serial + 1
        if write(active.activation, tostring(serial)) then
            active.serial, active.automatic = serial, false
        else failure() end
        return
    end
    local executable = expand('helpers/KitUpdate.exe')
    local helper = utils.file_info(executable)
    if not helper or not helper.is_file then if not automatic then failure() end; return end
    local directory = os.getenv('TEMP') or os.getenv('TMP')
    local absolute = directory and (directory:match('^%a:[\\/]') or directory:match('^\\\\'))
    local info = absolute and utils.file_info(directory)
    if not info or not info.is_dir then if not automatic then failure() end; return end
    sequence = sequence + 1
    local token = instance .. '-' .. sequence
    local path = utils.join_path(directory, 'mpvnet-update-' .. token .. '.json')
    local session = {path=path, activation=path .. '.activate', serial=automatic and 0 or 1, automatic=automatic==true}
    local payload = {schema=1, token=token, parent_pid=mp.get_property_number('pid', 0),
        config_directory=expand(''), automatic=session.automatic, activation_path=session.activation}
    if not write(path, utils.format_json(payload)) or not write(session.activation, tostring(session.serial)) then
        cleanup(session); if not automatic then failure() end; return
    end
    active = session
    local launched, request = pcall(mp.command_native_async, {name='subprocess', args={executable, '-RequestPath', path},
        capture_stdout=true, capture_stderr=false, playback_only=false}, function(ok, result)
        cleanup(session)
        if active ~= session then return end
        active = nil
        if closing then return end
        local reply = ok and result and result.status == 0 and utils.parse_json(result.stdout or '')
        if type(reply) ~= 'table' or reply.ok ~= true then if not session.automatic then failure() end; return end
        local seen = tonumber(reply.last_seen_serial)
        -- Only explicit requests received after the helper stopped reading replay.
        if seen and seen >= 0 and seen < session.serial then open(false) end
    end)
    if not launched or not request then
        cleanup(session)
        if active == session then active = nil; if not session.automatic then failure() end end
    else session.request = request end
end
settings.owner(mp, {
    id='updates.auto-check', initialize_on_ready=true, default_source='套件默认开启；新实例启动时检查',
    read=function() return automatic_enabled end,
    write=function(value) automatic_enabled = value; return true end,
})
local function settings_ready(_, snapshot)
    snapshot = mp.get_property_native('user-data/mpvnet/settings-values') or snapshot
    if closing or type(snapshot) ~= 'table' or snapshot.schema ~= 1 then return end
    -- Disabling takes effect for outstanding automatic work immediately. Enabling
    -- never creates a second startup opportunity in an already running player.
    if type(snapshot.values) == 'table' and snapshot.values['updates.auto-check'] == false then stop_automatic() end
    if ready then return end
    local seed = snapshot.startup
    if type(seed) ~= 'table' or type(seed.values) ~= 'table' then return end
    ready = true
    local initial = seed.values['updates.auto-check']
    automatic_enabled = not (seed.available == true and initial == false)
    if not automatic_enabled or startup_consumed or type(snapshot.values) == 'table' and snapshot.values['updates.auto-check'] == false then return end
    timer = mp.add_timeout(5, function()
        timer = nil
        if not closing and not startup_consumed then startup_consumed = true; open(true) end
    end)
end
mp.observe_property('user-data/mpvnet/settings-values', 'native', settings_ready)
settings_ready()
mp.add_key_binding(nil, 'open', function() open(false) end)
mp.register_script_message('open', function() open(false) end)
mp.register_event('shutdown', function()
    closing = true
    if timer then timer:kill(); timer = nil end
    if active then
        local session = active
        active = nil
        if session.request then mp.abort_async_command(session.request) end
        cleanup(session)
    end
end)
