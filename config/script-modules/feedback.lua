-- One client contract for action feedback; feature scripts still own their tasks.
local M = {}
local durations = {action = 1.5, success = 2, notice = 2, error = 4}

M.root = 'user-data/mpvnet/feedback/'
-- Fixed display order, shared with the coordinator; not a registration system.
M.owners = {'capture', 'danmaku', 'subtitle'}

function M.accepts_duration(value)
    for _, duration in pairs(durations) do
        if value == duration then return true end
    end
    return false
end

function M.new(mp)
    local client = {}

    function client.is_ready()
        return mp.get_property_native(M.root .. 'ready') == true
    end

    function client.show(text, kind)
        local duration = assert(durations[kind], 'Unknown feedback kind: ' .. tostring(kind))
        if client.is_ready() then
            return mp.commandv('script-message-to', 'feedback_osd', 'show', text, tostring(duration))
        end
        return mp.osd_message(text, duration)
    end

    return client
end

return M
