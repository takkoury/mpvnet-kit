-- Returning to a webpage is an explicit handoff for the current media only.
local M = {}

-- Accept a canonical page, which may already select a part with ?p=.
function M.url_at_time(page, seconds)
    if not seconds then return page end
    local separator = page:find('?', 1, true) and '&' or '?'
    return page .. separator .. 't=' .. seconds
end

local function part_for_cid(pages, cid)
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

local function episode_for_cid(index, cid, parse_page)
    if type(index) ~= 'table' or not cid then return end
    local found
    local function scan(section)
        if type(section) ~= 'table' or type(section.episodes) ~= 'table' then return false end
        for _, row in ipairs(section.episodes) do
            if type(row) ~= 'table' then return false end
            if row.cid == cid then
                local id = row.id
                if type(id) ~= 'number' or id < 1 or id >= 2^53 or id ~= math.floor(id) then return false end
                local episode = 'ep' .. string.format('%.0f', id)
                if found and episode ~= found then return false end
                if row.share_url then
                    local _, linked = parse_page(row.share_url)
                    if linked ~= episode then return false end
                end
                found = episode
            end
        end
        return true
    end
    if index.main_section and not scan(index.main_section) then return end
    if index.section ~= nil then
        if type(index.section) ~= 'table' then return end
        for _, section in ipairs(index.section) do
            if not scan(section) then return end
        end
    end
    if found then return 'https://www.bilibili.com/bangumi/play/' .. found end
end

function M.bind(mp, utils, feedback, source, open_address, parse_page)
    local pending
    local function retire()
        local old = pending
        pending = nil
        if old and old.handle then mp.abort_async_command(old.handle) end
    end
    local function playing_id()
        local pos = mp.get_property_number('playlist-playing-pos', -1)
        if pos >= 0 then return mp.get_property_native('playlist/' .. pos .. '/id') end
    end
    local function current(job)
        if pending ~= job then return false end
        if job.path == mp.get_property('path') and job.id == playing_id() then return true end
        pending = nil
        return false
    end

    mp.add_key_binding(nil, 'resume-webpage', function()
        if pending then return end
        local page, id, from_cdn, raw = source()
        if not page then feedback.show('当前媒体没有可接续的 B 站来源页', 'error'); return end
        local season = id:sub(1, 2) == 'ss'
        local time = mp.get_property_number('time-pos')
        if not time or not (time >= 0 and time < math.huge) then
            feedback.show('暂时无法取得播放位置', 'error'); return
        end
        local job = {path=mp.get_property('path'), id=playing_id()}
        pending = job
        local function launch(target)
            local address = M.url_at_time(target, math.floor(time))
            job.handle = open_address(address, 'URL', function(ok)
                if not current(job) then return end
                pending = nil
                if ok then
                    mp.set_property_bool('pause', true)
                else
                    feedback.show('无法打开网页，请检查默认浏览器', 'error')
                end
            end)
        end
        if not season and (id:sub(1, 2) == 'ep' or not from_cdn or page:find('?p=', 1, true)) then
            launch(page); return
        end

        -- Resolve only within the index for the confirmed source, at click time.
        local function unresolved()
            pending = nil
            feedback.show(season and '无法确认当前集数\n请从番剧的具体分集页打开视频'
                or '无法确认当前分 P\n请从原网页选择分集', 'error')
        end
        local windows = os.getenv('SystemRoot') or os.getenv('WINDIR')
        local cid = raw and tostring(raw):match('^[1-9]%d*$') and tonumber(raw)
        if not windows or (raw ~= nil and (not cid or cid >= 2^53)) or (season and (not from_cdn or not cid)) then
            unresolved(); return
        end
        local endpoint = season and ('https://api.bilibili.com/pgc/web/season/section?season_id=' .. id:sub(3))
            or ('https://api.bilibili.com/x/player/pagelist?bvid=' .. id)
        feedback.show(season and '正在确认番剧分集…' or '正在确认当前分 P…', 'action')
        job.handle = mp.command_native_async({name='subprocess', playback_only=true, capture_stdout=true,
            capture_size=2097152, args={utils.join_path(windows, 'System32/curl.exe'), '--disable',
                '--silent', '--fail', '--max-time', '4', '--max-filesize', '2097152',
                endpoint}}, function(ok, result)
            if not current(job) then return end
            local data = ok and result and result.status == 0 and utils.parse_json(result.stdout or '')
            if type(data) ~= 'table' or data.code ~= 0 then unresolved(); return end
            if season then
                local target = episode_for_cid(data.result, cid, parse_page)
                if target then launch(target) else unresolved() end
                return
            end
            local part = part_for_cid(data.data, cid)
            if not part then unresolved(); return end
            launch(page .. '?p=' .. part)
        end)
    end)
    for _, name in ipairs({'start-file', 'end-file', 'shutdown'}) do mp.register_event(name, retire) end
end

return M
