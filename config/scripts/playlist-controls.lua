-- One queue authority; the side window sends IDs, never cached queue indexes.
local mp = require('mp')
local utils = require('mp.utils')
local paths = dofile(mp.command_native({'expand-path', '~~/script-modules/mpvnet-paths.lua'}))
local helper = mp.command_native({'expand-path', '~~/helpers/playlist-window.ps1'})
local powershell = paths.powershell()
local token = string.format('%.0f-%.0f', mp.get_property_number('pid', 0), mp.get_time() * 1000000)
local wanted, running, ready, closing = false, false, false, false
local payload_path, helper_pid
local forwarded_keys = {}
local approved_keys = {}
for _, key in ipairs({
    'd', 'Space', 'Left', 'Right', 'Shift+Left', 'Shift+Right', 'Ctrl+Left', 'Ctrl+Right', ',', '.',
    'Ctrl+r', 'Ctrl+[', 'Ctrl+]', 'Ctrl+BS', 's', 'Alt+s', 'PGUP', 'PGDWN', 'Alt+Left', 'Alt+Right',
    'Alt+BS', 'Ctrl+Shift+s', 'Ctrl+c', 'm', 'M', 'l', 'Ctrl+Shift+l', 'Home', 'End', 'Enter',
    'Ctrl+t', 'Ctrl+0', 'Ctrl+i', 'Ctrl+m', 'TAB', 'Alt+o', '`', 'Ctrl+Shift+c', 'Ctrl+Shift+v', 'p',
}) do approved_keys[key] = true end

local named_keys = {
    space = 'Space', left = 'Left', right = 'Right', home = 'Home', ['end'] = 'End',
    enter = 'Enter', ['return'] = 'Enter', bs = 'BS', backspace = 'BS', tab = 'TAB',
    pgup = 'PGUP', pageup = 'PGUP', pgdwn = 'PGDWN', pgdown = 'PGDWN', pagedown = 'PGDWN',
    up = 'Up', down = 'Down',
}

local function normalize_key(raw)
    if type(raw) ~= 'string' or #raw > 32 or raw:find('%s') then return end
    local modifiers = {}
    while true do
        local prefix, rest = raw:match('^([^+]+)%+(.+)$')
        if not prefix then break end
        prefix = prefix:lower()
        if (prefix ~= 'ctrl' and prefix ~= 'alt' and prefix ~= 'shift') or modifiers[prefix] then return end
        modifiers[prefix], raw = true, rest
    end
    local base = named_keys[raw:lower()] or (#raw == 1 and raw or nil)
    if not base then return end
    if base:match('^%a$') and modifiers.shift then
        if modifiers.ctrl or modifiers.alt then base = base:lower()
        else base, modifiers.shift = base:upper(), nil end
    end
    local prefix = (modifiers.ctrl and 'Ctrl+' or '') .. (modifiers.alt and 'Alt+' or '')
        .. (modifiers.shift and 'Shift+' or '')
    return prefix .. base
end

local function adjust_key_active(key)
    local binding = key == 'Up' and 'adjust-up' or key == 'Down' and 'adjust-down'
    if not binding then return false end
    local command = 'script-binding subtitle_controls/' .. binding
    for _, entry in ipairs(mp.get_property_native('input-bindings', {})) do
        if entry.owner == 'subtitle_controls' and entry.is_weak == false and (tonumber(entry.priority) or -1) >= 0
            and entry.key and entry.key:lower() == key:lower()
            and (entry.cmd == command or entry.cmd == 'nonscalable ' .. command) then return true end
    end
    return false
end

local function release_keys()
    for key in pairs(forwarded_keys) do
        mp.commandv('no-osd', 'keyup', key)
    end
    forwarded_keys = {}
end

-- Window-local API. GUI keeps search editing/Ctrl+F/Delete and transfers focus before UI-opening press.
local function key(received_token, phase, raw_key)
    if received_token ~= token then return end
    if phase == 'release' then release_keys(); return end
    local normalized = normalize_key(raw_key)
    if not normalized then return end
    if phase == 'up' then
        if forwarded_keys[normalized] then
            forwarded_keys[normalized] = nil
            mp.commandv('no-osd', 'keyup', normalized)
        end
        return
    end
    if closing or not wanted or not running or not ready then return end
    if not approved_keys[normalized] and not adjust_key_active(normalized) then return end
    if phase == 'down' then
        if forwarded_keys[normalized] then return end
        -- mpv owns autorepeat; Windows autorepeated KeyDown must not restart it or enqueue presses.
        if mp.commandv('no-osd', 'keydown', normalized) then forwarded_keys[normalized] = true end
    elseif phase == 'press' and not forwarded_keys[normalized] then
        mp.commandv('no-osd', 'keypress', normalized)
    end
end

local function publish()
    mp.set_property_native('user-data/mpvnet/playlist-window', {
        token = token, visible = wanted, ready = ready,
    })
end

local function queue()
    return mp.get_property_native('playlist', {})
end

local function find_id(entries, id)
    for index, entry in ipairs(entries) do
        if entry.id ~= nil and tostring(entry.id) == tostring(id) then return index - 1 end
    end
end

local function step(direction)
    local entries = queue()
    if #entries == 0 then return end
    local current = mp.get_property_number('playlist-pos', -1)
    if current < 0 then current = 0 end
    local target = math.max(0, math.min(#entries - 1, current + direction))
    -- Explicitly replays the boundary entry rather than wrapping or doing nothing.
    mp.commandv('no-osd', 'playlist-play-index', target)
end

local function extension_sets()
    local sets = {video = {}, audio = {}}
    for kind, set in pairs(sets) do
        local values = mp.get_property_native('options/' .. kind .. '-exts', {})
        if type(values) == 'string' then
            local parsed = {}
            for value in values:gmatch('[^,]+') do parsed[#parsed + 1] = value end
            values = parsed
        end
        if type(values) == 'table' then
            for _, value in ipairs(values) do
                if type(value) == 'string' then set[value:lower():gsub('^%.', '')] = true end
            end
        end
    end
    return sets
end

local function media_kind(path, sets)
    if type(path) ~= 'string' then return nil end
    if path:find('://', 1, true) then path = path:gsub('[?#].*$', '') end
    local ext = path:match('%.([^./\\]+)$')
    if not ext then return nil end
    ext = ext:lower()
    if sets.video[ext] then return 'video' end
    if sets.audio[ext] then return 'audio' end
end

local function action(received_token, operation, id, target_id, side)
    if received_token ~= token or closing then return end
    if operation == 'append' then
        local files = utils.parse_json(id or '')
        if type(files) ~= 'table' then return end
        local sets = extension_sets()
        local kind = media_kind(mp.get_property('path'), sets)
        for _, file in ipairs(files) do
            if type(file) == 'string' and not file:find('://', 1, true) then
                local info = utils.file_info(file)
                local candidate = media_kind(file, sets)
                if info and info.is_file and candidate and (not kind or kind == candidate) then
                    kind = kind or candidate
                    mp.commandv('no-osd', 'loadfile', file, 'append')
                end
            end
        end
        return
    end
    local entries = queue()
    local source = find_id(entries, id)
    if source == nil then return end -- A stale or filtered view cannot target another item.
    if operation == 'play' then
        mp.commandv('no-osd', 'playlist-play-index', source)
    elseif operation == 'remove' then
        mp.commandv('no-osd', 'playlist-remove', source)
    elseif operation == 'move' then
        local target = find_id(entries, target_id)
        if target == nil or target == source or (side ~= 'before' and side ~= 'after') then return end
        -- mpv inserts before the original destination entry; count means the end.
        mp.commandv('no-osd', 'playlist-move', source, target + (side == 'after' and 1 or 0))
    end
end

local function start_window()
    local pipe = mp.get_property('options/input-ipc-server', '')
    if pipe == '' then
        pipe = '\\\\.\\pipe\\mpvnet-playlist-' .. token
        local ok = mp.set_property('options/input-ipc-server', pipe)
        if not ok then mp.msg.warn('Playlist window failed: ipc'); wanted = false; publish(); return end
    end
    local temp = os.getenv('TEMP') or os.getenv('TMP')
    if not temp then wanted = false; publish(); return end
    payload_path = utils.join_path(temp, 'mpvnet-playlist-' .. token .. '.json')
    local file = io.open(payload_path, 'wb')
    if not file then wanted = false; publish(); return end
    local written = file:write(utils.format_json({
        parent_pid = mp.get_property_number('pid', 0), pipe = pipe, token = token,
        script = mp.get_script_name(), visible = wanted, working_directory = mp.get_property('working-directory'),
    }))
    local closed = file:close()
    if not written or not closed then
        os.remove(payload_path); payload_path = nil; wanted = false; publish(); return
    end
    running = true
    mp.command_native_async({name = 'subprocess', args = {
        powershell, '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', helper,
        '-PayloadPath', payload_path,
    }, capture_stdout = true, capture_stderr = false, playback_only = false}, function(ok, result)
        release_keys()
        running, ready, helper_pid = false, false, nil
        if payload_path then os.remove(payload_path); payload_path = nil end
        if not closing then
            wanted = false
            publish()
            if not ok or not result or result.status ~= 0 then
                local data = result and utils.parse_json(result.stdout or '')
                local phase = data and type(data.phase) == 'string'
                    and data.phase:match('^[a-z-]+$') and data.phase or 'worker'
                local class = data and type(data.error_class) == 'string'
                    and data.error_class:match('^[%w_]+$') and data.error_class or 'unknown'
                local member = data and type(data.error_member) == 'string'
                    and data.error_member:match('^[%w_]+$') and data.error_member or 'unknown'
                local member_type = data and type(data.error_type) == 'string'
                    and data.error_type:match('^[%w_%.%+]+$') and data.error_type or 'unknown'
                local callers = {}
                if data and type(data.error_callers) == 'table' then
                    for index, caller in ipairs(data.error_callers) do
                        if index > 12 then break end
                        if type(caller) == 'string' and #caller <= 180
                            and caller:match('^[%w_%.%+]+$')
                            and (caller:match('^System%.Windows%.Forms%.') or caller:match('^System%.Drawing%.')) then
                            callers[#callers + 1] = caller
                        end
                    end
                end
                local parameter = data and type(data.error_parameter) == 'string'
                    and data.error_parameter:match('^[%a_][%w_]*$') and data.error_parameter or ''
                mp.msg.warn('Playlist window failed: ' .. phase .. '/' .. class
                    .. '/' .. tostring(tonumber(data and data.error_line) or 0)
                    .. '/' .. member_type .. '.' .. member
                    .. ' / parameter=' .. parameter .. ' / callers=' .. table.concat(callers, ','))
            end
        end
    end)
end

mp.add_key_binding(nil, 'toggle', function()
    wanted = not wanted
    if not wanted then release_keys() end
    publish()
    if wanted and not running then start_window() end
end)
mp.add_key_binding(nil, 'previous', function() step(-1) end)
mp.add_key_binding(nil, 'next', function() step(1) end)
mp.register_script_message('action', action)
mp.register_script_message('key', key)
mp.register_script_message('window-hidden', function(received_token)
    if received_token == token then release_keys(); wanted = false; publish() end
end)
mp.register_script_message('helper-ready', function(received_token, pid)
    if received_token ~= token then return end
    helper_pid = tonumber(pid)
    ready = true
    publish()
end)
mp.register_event('shutdown', function()
    release_keys()
    closing, wanted = true, false
    mp.commandv('script-message', 'mpvnet-playlist-close', token)
    if helper_pid then
        -- Let the side window drain the close event before mpv kills subprocesses.
        mp.command_native({name = 'subprocess', args = {
            powershell, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', helper,
            '-WaitPid', tostring(helper_pid),
        }, capture_stdout = true, capture_stderr = false, playback_only = false})
    end
    if payload_path then os.remove(payload_path) end
end)

-- Native EOF advances once. "yes" holds only the final entry, unlike "always".
mp.set_property('keep-open', 'yes')
mp.set_property('loop-playlist', 'no')
publish()
