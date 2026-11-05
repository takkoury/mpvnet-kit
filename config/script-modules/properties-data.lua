-- Read the native property tree once. Only the controller may display a
-- selected detail; this module never publishes values or reports raw errors.
local mp = require('mp')
local utils = require('mp.utils')
local M = {}

local max_depth, max_nodes = 32, 20000
local max_bytes, max_entry = 8 * 1024 * 1024, 64 * 1024
local extras = {'current-tracks/audio', 'current-tracks/video', 'current-tracks/sub', 'current-tracks/sub2'}
local limit, cycle = {}, {}

local function display_text(text)
    -- mpv's ASS escape command also recognizes in-band OSD controls. Make
    -- them and C string terminators visible before passing values to any UI.
    text = text:gsub('[%z\1-\8\11-\31\127]', function(byte) return ('\\x%02X'):format(byte:byte()) end)
    return (text:gsub('\194[\128-\159]', function(code) return ('\\x%02X'):format(code:byte(2)) end))
end

local function segment(key, native_array)
    local kind = type(key)
    if kind == 'number' then
        -- mpv pushes native arrays into Lua at index 1, but the property
        -- interface addresses their first item at /0. Map keys stay literal.
        if native_array and key >= 1 and key == math.floor(key) then key = key - 1 end
        return tostring(key)
    end
    if kind ~= 'string' then return '[' .. kind .. ':' .. tostring(key) .. ']' end
    if #key > max_entry then error(limit) end
    if key == '' then return '%' end
    -- Preserve a map key containing '/' as one visible path component.
    key = key:gsub('[%%/%z\1-\31\127]', function(byte) return ('%%%02X'):format(byte:byte()) end)
    return (key:gsub('\194[\128-\159]', function(code) return ('%%C2%%%02X'):format(code:byte(2)) end))
end

local function collect(names, read)
    local covered, stack, leaves = {}, {}, {}
    local nodes, bytes = 0, 0
    local function visit(path, value, depth)
        nodes = nodes + 1
        if depth > max_depth or nodes > max_nodes or #path > max_entry then error(limit) end
        local branch = type(value) == 'table' and next(value) ~= nil
        if branch and stack[value] then error(cycle) end
        if covered[path] then return end
        covered[path] = true
        bytes = bytes + #path
        if bytes > max_bytes then error(limit) end
        if branch then
            stack[value] = true
            local native_array = mp.ARRAY ~= nil and getmetatable(value) == mp.ARRAY
            for key, child in next, value do
                visit(path .. '/' .. segment(key, native_array), child, depth + 1)
            end
            stack[value] = nil
            return
        end
        if type(value) == 'string' and #value > max_entry then error(limit) end
        local formatted = display_text(utils.to_string(value))
        local title = display_text(path)
        bytes = bytes + #title - #path + #formatted + 2
        if #title + #formatted + 2 > max_entry or bytes > max_bytes then error(limit) end
        leaves[#leaves+1] = {title=title, value=formatted}
    end

    for _, name in ipairs(names) do
        if not covered[name] then visit(name, read(name), 0) end
    end
    if #names > 0 then
        for _, name in ipairs(extras) do
            if not covered[name] then visit(name, read(name), 0) end
        end
    end
    table.sort(leaves, function(a, b) return a.title < b.title end)
    local rows = {}
    for id, item in ipairs(leaves) do
        rows[id] = {id=id, title=item.title, property_value=item.value}
    end
    return rows, leaves
end

local function snapshot_sources()
    local source = mp.get_property_native('property-list')
    if type(source) ~= 'table' then return nil end
    local names, seen, count, bytes = {}, {}, 0, 0
    for _, name in next, source do
        count = count + 1
        if count > max_nodes then error(limit) end
        if type(name) ~= 'string' or name == '' or name:find('%z') then return nil end
        if not seen[name] then
            bytes = bytes + #name
            if #name > max_entry or bytes > max_bytes then error(limit) end
            names[#names+1], seen[name] = name, true
        end
    end
    table.sort(names)
    local saved = {['property-list']={value=source}}
    -- Snapshot the log option before borrowing it, including when a parent
    -- property exposes it as a nested value.
    for _, name in ipairs({'msg-level', 'options', 'options/msg-level', 'file-local-options', 'file-local-options/msg-level'}) do
        if seen[name] then saved[name] = {value=mp.get_property_native(name)} end
    end
    return names, function(name)
        if saved[name] then return saved[name].value end
        return mp.get_property_native(name)
    end
end

local function quiet_level(original)
    local entries = {}
    if original ~= '' then
        for entry in (original .. ','):gmatch('(.-),') do
            local name = entry:match('^([^=]+)=[a-z]+$')
            -- Do not borrow a string that cannot be round-tripped as mpv's
            -- comma-separated property representation.
            if not name or name:match('^["%[%%]') then return nil end
            if name ~= 'cplayer' then entries[#entries+1] = entry end
        end
    end
    -- mpv removes duplicate keys and preserves order. Append the override
    -- last, so cplayer=no also wins over a previous all=... entry.
    entries[#entries+1] = 'cplayer=no'
    return table.concat(entries, ',')
end

function M.snapshot()
    local ok, names, read = pcall(snapshot_sources)
    if not ok or not names then return nil, nil, names == limit and 'limit' or 'read' end
    if #names == 0 then return {}, {} end

    -- Match the native selector's suppression of deprecated-property warnings.
    -- Treat the log level as a short loan, including if collection throws.
    local level_ok, original = pcall(mp.get_property, 'msg-level')
    if not level_ok or type(original) ~= 'string' then return nil, nil, 'read' end
    local quiet = quiet_level(original)
    if not quiet then return nil, nil, 'read' end
    local borrowed = original ~= quiet
    local muted, applied = true, true
    if borrowed then muted, applied = pcall(mp.set_property, 'msg-level', quiet) end
    local collected, rows, targets
    if muted and applied == true then collected, rows, targets = pcall(collect, names, read) end

    if borrowed then
        local checked, current = pcall(mp.get_property, 'msg-level')
        if not checked or type(current) ~= 'string' then return nil, nil, 'restore' end
        if current == quiet then
            local restored, success = pcall(mp.set_property, 'msg-level', original)
            if not restored or success ~= true then return nil, nil, 'restore' end
        end
    end
    if not collected then return nil, nil, rows == limit and 'limit' or rows == cycle and 'cycle' or 'read' end
    return rows, targets
end

return M
