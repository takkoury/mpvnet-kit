-- mpv owns the playlist. A view assigns local IDs to unambiguous native entries.
local M = {}

local function integer(value, minimum)
    return type(value) == 'number' and value >= minimum and value <= 9007199254740991
        and value == math.floor(value)
end

local function array_size(entries)
    if type(entries) ~= 'table' then return nil end
    local count, last = 0, 0
    for index in pairs(entries) do
        if not integer(index, 1) then return nil end
        count, last = count + 1, math.max(last, index)
    end
    if count == last then return count end
end

local function native_id(entry)
    if type(entry) == 'table' and integer(entry.id, 0) then return entry.id end
end

local function display_name(entry, mode, platform)
    local title = entry.title
    if type(title) ~= 'string' or not title:match('%S') or title:find('%z') then title = nil end
    if title and mode == 'title' then return title end
    local filename = entry.filename
    if not filename:find('://', 1, true) then
        local separators = platform == 'windows' and '/\\' or '/'
        local basename = filename:gsub('[' .. separators .. ']+$', ''):match('([^' .. separators .. ']+)$')
        filename = basename or filename
    end
    return title and mode == 'both' and (title .. ' (' .. filename .. ')') or filename
end

function M.new()
    local previous, next_id = {}, 0
    return function(entries, mode, platform)
        local rows, targets, current_id = {}, {}, 0
        local identities = {}
        local size = array_size(entries)
        local status = 'unavailable'
        if size then
            local counts = {}
            for _, entry in ipairs(entries) do
                local id = native_id(entry)
                if id then counts[id] = (counts[id] or 0) + 1 end
            end
            local playing_count = 0
            for index, entry in ipairs(entries) do
                local id = native_id(entry)
                if id and counts[id] == 1 and type(entry.filename) == 'string'
                    and entry.filename ~= '' and not entry.filename:find('%z') then
                    local identity = previous[id]
                    if not identity or identity.filename ~= entry.filename then
                        next_id = next_id + 1
                        identity = {id=next_id, real_id=id, filename=entry.filename}
                    end
                    identities[id], targets[identity.id] = identity, identity
                    rows[#rows + 1] = {id=identity.id, title=display_name(entry, mode, platform),
                        time_text=tostring(index), history_path=entry.filename}
                    if entry.playing == true then
                        current_id, playing_count = identity.id, playing_count + 1
                    end
                end
            end
            if playing_count > 1 then current_id = 0 end
            if size == 0 then status = 'empty'
            elseif #rows == 0 then status = 'invalid'
            elseif #rows < size then status = 'partial'
            else status = 'ready' end
        end
        -- Removed, replaced and ambiguous IDs never regain their old UI identity.
        previous = identities
        return {rows=rows, targets=targets, current_id=current_id, status=status}
    end
end

function M.resolve(entries, target)
    if not target or not array_size(entries) then return nil end
    local position
    for index, entry in ipairs(entries) do
        if native_id(entry) == target.real_id then
            if position or entry.filename ~= target.filename then return nil end
            position = index - 1
        end
    end
    return position
end

return M
