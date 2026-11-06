-- Own only the persistent OSD option. Native messages retain their own lifetime.
local mp = require('mp')
local policy = dofile(mp.command_native({'expand-path', '~~/script-modules/feedback.lua'}))
local root, owners = policy.root, policy.owners
local states = {}
for _, owner in ipairs(owners) do states[owner] = '' end
local original, owned, lost, timer, serial, stopping = nil, nil, false, nil, 0, false

local function has_states()
    for _, owner in ipairs(owners) do
        if states[owner] ~= '' then return true end
    end
    return false
end

local function current()
    return mp.get_property('osd-msg1', '')
end

local function release()
    if owned ~= nil and current() == owned then mp.set_property('osd-msg1', original) end
    original, owned = nil, nil
end

local function suspended()
    return timer ~= nil or mp.get_property_number('osd-level', 1) ~= 1
        or mp.get_property_native('user-data/mpv/console/open') == true
        or mp.get_property_native('user-data/mpvnet/track-selector/open') == true
end

local function render()
    if stopping then return end
    if owned ~= nil and current() ~= owned then
        -- Another writer wins, including while our status was temporarily hidden.
        original, owned, lost = nil, nil, true
    end
    if not has_states() then release(); lost = false; return end
    if lost then return end
    if owned == nil then original = current(); owned = original end
    local lines = {}
    for _, owner in ipairs(owners) do
        if states[owner] ~= '' then lines[#lines + 1] = states[owner] end
    end
    local text = table.concat(lines, '\n')
    -- Escape property expansion in plain status text, preserving the user's prefix.
    local value = suspended() and original or (original .. (original ~= '' and '\n' or '') .. text:gsub('%$', '$$'))
    if value ~= owned then
        owned = value
        local ok = mp.set_property('osd-msg1', value)
        if not ok then original, owned, lost = nil, nil, true end
    end
end

local function status(owner, value)
    value = type(value) == 'string' and value or ''
    if #value > 240 or value:gsub('\n', ''):find('%c') then value = '' end
    states[owner] = value
    render()
end

mp.register_script_message('show', function(text, seconds)
    if stopping or type(text) ~= 'string' or #text > 600 then return end
    local duration = tonumber(seconds)
    if not policy.accepts_duration(duration) then return end
    serial = serial + 1
    local revision = serial
    if timer then timer:kill() end
    timer = mp.add_timeout(duration, function()
        if stopping or revision ~= serial then return end
        timer = nil
        render() -- Never resend or clear someone else's native OSD message.
    end)
    render()
    mp.osd_message(text, duration)
end)

for _, owner in ipairs(owners) do
    local key = owner
    mp.observe_property(root .. key, 'native', function(_, value) status(key, value) end)
end
for _, name in ipairs({'osd-msg1', 'osd-level', 'user-data/mpv/console/open',
    'user-data/mpvnet/track-selector/open'}) do
    mp.observe_property(name, 'native', render)
end
mp.register_event('shutdown', function()
    stopping = true
    serial = serial + 1
    if timer then timer:kill(); timer = nil end
    mp.set_property_native(root .. 'ready', false)
    release()
end)
mp.set_property_native(root .. 'ready', true)
