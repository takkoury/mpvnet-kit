-- Returning to a webpage is an explicit handoff for the current media only.
local M = {}

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

function M.bind(mp, utils, feedback, source, open_address)
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
        local page, id, from_cdn = source()
        if not page then feedback.show('当前媒体没有可接续的 B 站来源页', 'error'); return end
        if id:sub(1, 2) == 'ss' then
            feedback.show('无法确认当前集数\n请从番剧的具体分集页打开视频', 'error'); return
        end
        local time = mp.get_property_number('time-pos')
        if not time or not (time >= 0 and time < math.huge) then
            feedback.show('暂时无法取得播放位置', 'error'); return
        end
        local job = {path=mp.get_property('path'), id=playing_id()}
        pending = job
        local function launch(target)
            local address = target .. (target:find('?', 1, true) and '&t=' or '?t=') .. math.floor(time)
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
        if id:sub(1, 2) == 'ep' or not from_cdn or page:find('?p=', 1, true) then launch(page); return end

        -- External Player can supply a BV Referer without ?p=. Only the published
        -- part list for this BV may map the current CID to a part number.
        local function unresolved()
            pending = nil
            feedback.show('无法确认当前分 P\n请从原网页选择分集', 'error')
        end
        local raw = mp.get_opt('cid')
        local cid = raw and tostring(raw):match('^[1-9]%d*$') and tonumber(raw)
        local windows = os.getenv('SystemRoot') or os.getenv('WINDIR')
        if (raw ~= nil and not cid) or not windows then unresolved(); return end
        feedback.show('正在确认当前分 P…', 'action')
        job.handle = mp.command_native_async({name='subprocess', playback_only=true, capture_stdout=true,
            capture_size=2097152, args={utils.join_path(windows, 'System32/curl.exe'), '--disable',
                '--silent', '--fail', '--max-time', '4', '--max-filesize', '2097152',
                'https://api.bilibili.com/x/player/pagelist?bvid=' .. id}}, function(ok, result)
            if not current(job) then return end
            local data = ok and result and result.status == 0 and utils.parse_json(result.stdout or '')
            local part = type(data) == 'table' and data.code == 0 and part_for_cid(data.data, cid)
            if not part then unresolved(); return end
            launch(page .. '?p=' .. part)
        end)
    end)
    for _, name in ipairs({'start-file', 'end-file', 'shutdown'}) do mp.register_event(name, retire) end
end

return M
