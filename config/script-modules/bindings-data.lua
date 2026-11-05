-- Resolve input-bindings like the native picker. An effective ignore masks
-- weaker entries for the same key even though it has no selectable row.
local M = {}

function M.effective(source)
    if type(source) ~= 'table' then return nil end
    local winners = {}
    for _, item in ipairs(source) do
        if type(item) == 'table' then
            local key, command, priority, weak = item.key, item.cmd, item.priority, item.is_weak
            if type(key) == 'string' and key:match('%S') and not key:find('[%z\1-\31\127]') and
                type(priority) == 'number' and priority >= 0 and priority < math.huge and
                type(weak) == 'boolean' then
                local winner = winners[key]
                if not winner or (winner.is_weak and not weak) or
                    (winner.is_weak == weak and priority > winner.priority) then
                    winners[key] = {key=key, cmd=command, priority=priority, is_weak=weak}
                end
            end
        end
    end
    for key, winner in pairs(winners) do
        -- A malformed winner cannot turn a shadowed command into an action.
        local command = winner.cmd
        if type(command) ~= 'string' or not command:match('%S') or command:find('%z') or command == 'ignore' then
            winners[key] = nil
        end
    end
    return winners
end

function M.rows(effective, by_command)
    local keys, rows, targets = {}, {}, {}
    for key in pairs(effective) do keys[#keys+1] = key end
    table.sort(keys)
    for id, key in ipairs(keys) do
        local command = effective[key].cmd
        local action = by_command and by_command[command]
        local label = type(action) == 'table' and action.label
        rows[id] = {id=id, title=type(label) == 'string' and label:match('%S') and label or command,
            time_text=key, action_command=command}
        targets[id] = {key=key, cmd=command}
    end
    return rows, targets
end

return M
