-- Prepare explicit inputs before touching mpv's queue. The helper owns Windows
-- paths and dialogs; this module alone decides whether a result is still current.
local M = {}

function M.new(mp, utils, feedback)
    local executable = mp.command_native({'expand-path', '~~/helpers/KitPlaylistInput.exe'})
    local session = string.format('%.0f-%.0f', mp.get_property_number('pid', 0), mp.get_time() * 1000000)
    local sequence, pending, closing = 0, nil, false

    local function snapshot()
        local entries = {}
        for _, entry in ipairs(mp.get_property_native('playlist', {})) do
            entries[#entries + 1] = {id=entry.id, filename=entry.filename}
        end
        return {entries=entries, cwd=mp.get_property('working-directory', ''),
            current=mp.get_property_number('playlist-pos', -1), path=mp.get_property('path', '')}
    end

    local function unchanged(before)
        local after = snapshot()
        if before.cwd ~= after.cwd or before.current ~= after.current or before.path ~= after.path
            or #before.entries ~= #after.entries then return false end
        for i, entry in ipairs(before.entries) do
            if entry.id ~= after.entries[i].id or entry.filename ~= after.entries[i].filename then return false end
        end
        return true
    end

    local function extensions(kind)
        local values = mp.get_property_native('options/' .. kind, {})
        if type(values) == 'table' then return values end
        local result = {}
        if type(values) == 'string' then
            for item in values:gmatch('[^,]+') do result[#result+1] = item end
        end
        return result
    end

    local function retire()
        local old = pending
        pending = nil
        if old then
            if old.handle then mp.abort_async_command(old.handle) end
            os.remove(old.path)
        end
    end

    local errors = {
        native_entry_required='此格式请拖入播放器主窗口打开',
        parent_unavailable='播放器已不可用，请重新打开',
        input_unavailable='无法读取所选文件或剪贴板',
        input_too_large='文件数量或路径内容过多，未修改播放列表',
    }

    local function valid_entries(entries)
        if type(entries) ~= 'table' or #entries > 10000 then return false end
        for _, entry in ipairs(entries) do
            if type(entry) ~= 'table' or type(entry.path) ~= 'string' or entry.path == ''
                or #entry.path > 131072 or entry.path:find('[%z\1-\31\127]')
                or (entry.kind ~= 'media' and entry.kind ~= 'subtitle' and entry.kind ~= 'native') then return false end
        end
        return true
    end

    local function commit(mode, operation, data, generation)
        if #data.entries == 0 then
            if (tonumber(data.unreadable_directories) or 0) > 0 then
                feedback.show('无法读取所选文件夹', 'error')
            elseif (tonumber(data.duplicates) or 0) > 0 then
                feedback.show('所选文件已在播放列表中', 'action')
            elseif operation == 'folder' then feedback.show('文件夹中没有可添加的音视频', 'action')
            else feedback.show('没有可添加的媒体文件', 'error') end
            return
        end
        local replaced, failed = false, 0
        for _, entry in ipairs(data.entries) do
            if closing or generation ~= sequence then return end
            if entry.kind == 'subtitle' then
                local _, err = mp.command_native({'sub-add', entry.path})
                if err then failed = failed + 1 end
            else
                local replace = mode == 'open' and not replaced
                local args = {'loadfile', entry.path, replace and 'replace' or 'append'}
                -- Explicit batches are exact selections. Retain the user's
                -- autocreate-playlist preference only for one selected media.
                if entry.kind == 'media' and not (replace and data.single_media == true) then
                    args[4], args[5] = -1, {['autocreate-playlist']='no'}
                end
                local _, err = mp.command_native(args)
                if err then failed = failed + 1
                elseif replace then
                    replaced = true
                    if not closing and generation == sequence then mp.set_property_native('pause', false) end
                end
            end
        end
        if closing or generation ~= sequence then return end
        if failed > 0 then feedback.show('部分文件未能加入播放列表', 'error')
        elseif (tonumber(data.unreadable_directories) or 0) > 0 then
            feedback.show('已添加可用文件，部分文件夹无法读取', 'error')
        elseif (tonumber(data.skipped) or 0) > 0 then feedback.show('已跳过无法加入的文件', 'action') end
    end

    local function request(mode, operation, files)
        if closing then return end
        retire()
        sequence = sequence + 1
        local generation = sequence
        local temp = os.getenv('TEMP') or os.getenv('TMP')
        if not temp or temp == '' or not utils.file_info(executable) then
            feedback.show('无法打开文件操作，请检查套件是否完整', 'error'); return
        end
        local id = session .. '-' .. sequence
        local state = snapshot()
        local existing = {}
        for _, entry in ipairs(state.entries) do
            if type(entry.filename) == 'string' then existing[#existing+1] = entry.filename end
        end
        local path = utils.join_path(temp, 'mpvnet-input-' .. id .. '.json')
        local payload = utils.format_json({schema=1, request_id=id, parent_pid=mp.get_property_number('pid', 0),
            operation=operation, mode=mode, paths=files or {}, working_directory=state.cwd,
            video_exts=extensions('video-exts'), audio_exts=extensions('audio-exts'),
            image_exts=extensions('image-exts'),
            subtitle_exts=extensions('sub-auto-exts'), existing_paths=existing})
        if not payload or #payload > 2*1024*1024 then
            feedback.show('文件操作内容过多，未修改播放列表', 'error'); return
        end
        local file = io.open(path, 'wb')
        if not file then feedback.show('无法准备文件操作', 'error'); return end
        local written = file:write(payload)
        local closed = file:close()
        if not written or not closed then os.remove(path); feedback.show('无法准备文件操作', 'error'); return end
        local job = {id=id, path=path, state=state}
        pending = job
        job.handle = mp.command_native_async({name='subprocess', args={executable, '-RequestPath', path},
            capture_stdout=true, capture_stderr=false, playback_only=false}, function(ok, result)
            os.remove(path)
            if closing or pending ~= job then return end
            pending = nil
            local raw = result and result.stdout or ''
            local data = #raw <= 4*1024*1024 and utils.parse_json(raw) or nil
            if not ok or not result or type(data) ~= 'table'
                or data.schema ~= 1 or data.request_id ~= id then
                feedback.show('文件操作失败，请重试', 'error'); return
            end
            if data.status == 'error' then
                feedback.show(errors[data.error_code] or '文件操作失败，请重试', 'error'); return
            end
            if result.status ~= 0 then feedback.show('文件操作失败，请重试', 'error'); return end
            if data.status == 'cancelled' then return end
            if data.status ~= 'ok' then feedback.show('文件操作失败，请重试', 'error'); return end
            if not valid_entries(data.entries) then feedback.show('未能读取文件操作结果', 'error'); return end
            if not unchanged(state) then
                feedback.show('播放列表已变化，请重新选择文件', 'action'); return
            end
            commit(mode, operation, data, generation)
        end)
    end

    return {
        request=request,
        shutdown=function() closing=true; retire() end,
    }
end

return M
