-- Read only the public index for an already identified Bilibili source.
local M = {}

function M.fetch(mp, utils, id, done)
    local windows = os.getenv('SystemRoot') or os.getenv('WINDIR')
    if not windows then done(nil); return end
    local season = id:sub(1, 2) == 'ss'
    local endpoint = season and ('https://api.bilibili.com/pgc/web/season/section?season_id=' .. id:sub(3))
        or ('https://api.bilibili.com/x/player/pagelist?bvid=' .. id)
    return mp.command_native_async({name='subprocess', playback_only=true, capture_stdout=true,
        capture_size=2097152, args={utils.join_path(windows, 'System32/curl.exe'), '--disable',
            '--silent', '--fail', '--max-time', '4', '--max-filesize', '2097152', endpoint}},
        function(ok, result)
            local data = ok and result and result.status == 0 and utils.parse_json(result.stdout or '')
            if type(data) ~= 'table' or data.code ~= 0 then done(nil); return end
            if season then done(data.result) else done(data.data) end
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

function M.titles(pages)
    if type(pages) ~= 'table' or #pages == 0 or #pages > 10000 then return end
    local titles = {}
    for _, row in ipairs(pages) do
        local n = type(row) == 'table' and row.page
        if type(n) ~= 'number' or n < 1 or n > #pages or n ~= math.floor(n)
            or titles[n] or type(row.part) ~= 'string' then return end
        local title = row.part:gsub('%c', ' ')
        titles[n] = title:find('%S') and title or ('第 ' .. n .. ' P')
    end
    return titles
end

return M
