-- Returning to a webpage is an explicit handoff for the current media only.
local M = {}

local function episode_for_cid(index, cid, web_source)
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
                    local linked = web_source.parse(row.share_url)
                    if not linked or linked.id ~= episode or linked.kind ~= 'bilibili' then return false end
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

function M.bind(mp, utils, feedback, source, open_address, web_source, catalog)
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
        local page, id, raw = source()
        if not page then feedback.show('当前媒体没有可接续的网页', 'error'); return end
        local time = mp.get_property_number('time-pos')
        if not time or not (time >= 0 and time < math.huge) then
            feedback.show('暂时无法取得播放位置', 'error'); return
        end
        local job = {path=mp.get_property('path'), id=playing_id()}
        pending = job
        local function launch(target)
            local address = web_source.url_at_time(target, math.floor(time))
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
        if not id then launch(page); return end

        -- Resolve only within the index for the confirmed source, at click time.
        local season = id:sub(1, 2) == 'ss'
        local function unresolved()
            pending = nil
            feedback.show(season and '无法确认当前集数\n请从番剧的具体分集页打开视频'
                or '无法确认当前分 P\n请从原网页选择分集', 'error')
        end
        local cid = raw and tostring(raw):match('^[1-9]%d*$') and tonumber(raw)
        if (raw ~= nil and (not cid or cid >= 2^53)) or (season and not cid) then
            unresolved(); return
        end
        feedback.show(season and '正在确认番剧分集…' or '正在确认当前分 P…', 'action')
        job.handle = catalog.fetch(mp, utils, id, function(data)
            if not current(job) then return end
            if season then
                local target = episode_for_cid(data, cid, web_source)
                if target then launch(target) else unresolved() end
                return
            end
            local part = catalog.part_for_cid(data, cid)
            if not part then unresolved(); return end
            launch(page .. '?p=' .. part)
        end)
    end)
    for _, name in ipairs({'start-file', 'end-file', 'shutdown'}) do mp.register_event(name, retire) end
end

return M
