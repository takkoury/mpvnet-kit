-- Read only the public index for an already identified Bilibili source.
local M = {}

function M.fetch(mp, utils, id, done)
    local windows = os.getenv('SystemRoot') or os.getenv('WINDIR')
    if not windows or type(id) ~= 'string' then done(nil); return end
    local endpoint, field
    if id:match('^ss[1-9]%d*$') then
        endpoint, field = 'https://api.bilibili.com/pgc/web/season/section?season_id=' .. id:sub(3), 'result'
    elseif id:match('^ep[1-9]%d*$') then
        endpoint, field = 'https://api.bilibili.com/pgc/view/web/season?ep_id=' .. id:sub(3), 'result'
    elseif #id == 12 and id:match('^BV%w+$') then
        endpoint, field = 'https://api.bilibili.com/x/player/pagelist?bvid=' .. id, 'data'
    else
        done(nil); return
    end
    return mp.command_native_async({name='subprocess', playback_only=true, capture_stdout=true,
        capture_size=2097152, args={utils.join_path(windows, 'System32/curl.exe'), '--disable',
            '--silent', '--fail', '--max-time', '4', '--max-filesize', '2097152', endpoint}},
        function(ok, result)
            local data = ok and result and result.status == 0 and utils.parse_json(result.stdout or '')
            if type(data) ~= 'table' or data.code ~= 0 then done(nil); return end
            done(data[field])
        end)
end

function M.part_for_cid(pages, cid)
    if type(pages) ~= 'table' then return end
    local part
    for _, row in ipairs(pages) do
        if type(row) == 'table' and type(row.cid) == 'number'
            and (row.cid == cid or (cid == nil and #pages == 1)) then
            if part or type(row.page) ~= 'number' or row.page < 1 or row.page > #pages
                or row.page ~= math.floor(row.page) then return end
            part = row.page
        end
    end
    return part
end

local function video_parts(bv, pages, part)
    if type(pages) ~= 'table' or #pages == 0 or #pages > 10000 then return end
    local entries = {}
    for _, row in ipairs(pages) do
        local n = type(row) == 'table' and row.page
        if type(n) ~= 'number' or n < 1 or n > #pages or n ~= math.floor(n)
            or entries[n] or type(row.part) ~= 'string' then return end
        local title = row.part:gsub('%c', ' ')
        entries[n] = {title='P' .. n .. ' · ' .. (title:find('%S') and title or ('第 ' .. n .. ' P')),
            path='https://www.bilibili.com/video/' .. bv .. '/?p=' .. n}
    end
    return entries, part
end

local function positive_id(n)
    return type(n) == 'number' and n >= 1 and n < 2^53 and n == math.floor(n)
end

local function label(value)
    if type(value) == 'string' and value:find('%S') then return (value:gsub('%c', ' ')) end
end

local function season_episodes(ep, season)
    if type(season) ~= 'table' or not positive_id(season.season_id) then return end
    local rows = season.episodes
    if type(rows) ~= 'table' or #rows < 2 or #rows > 10000 then return end
    local entries, seen, current = {}, {}, nil
    for _, row in ipairs(rows) do
        if type(row) ~= 'table' or type(row.section_type) ~= 'number' then return end
        -- The season's top-level episodes are the regular program. Other
        -- sections can have their own EP links (trailers, highlights, etc.).
        if row.section_type == 0 then
            if not positive_id(row.id) or seen[row.id] or (row.ep_id ~= nil and row.ep_id ~= row.id) then return end
            seen[row.id] = true
            local id = 'ep' .. string.format('%.0f', row.id)
            local title = label(row.show_title)
            if not title then
                local number = label(row.title) or id
                if number:match('^%d+$') then number = '第' .. number .. '集' end
                local name = label(row.long_title)
                title = name and (number .. ' ' .. name) or number
            end
            entries[#entries+1] = {title=title, path='https://www.bilibili.com/bangumi/play/' .. id}
            if id == ep then current = #entries end
        end
    end
    return entries, current
end

function M.queue_entries(source, data)
    local id = source.content_id
    if id:sub(1, 2) == 'ep' then return season_episodes(id, data) end
    return video_parts(id, data, source.part)
end

return M
