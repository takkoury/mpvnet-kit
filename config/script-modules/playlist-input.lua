-- Prepare explicit inputs before touching mpv's queue. The helper owns Windows
-- paths and dialogs; this module alone decides whether a result is still current.
local M = {}

function M.new(mp, utils, feedback, read_include_images)
    local executable = mp.command_native({'expand-path', '~~/helpers/KitPlaylistInput.exe'})
    local session = string.format('%.0f-%.0f', mp.get_property_number('pid', 0), mp.get_time() * 1000000)
    local sequence, pending, saving, closing = 0, nil, nil, false
    local last_save_path = ''
    -- These are per-entry loading policies, not another queue or title store.
    -- mpv owns both the IDs and the titles parsed from the validated M3U body.
    local exact_entries = {}
    local function image_key(path) return path:gsub("\\", "/"):lower() end

    local function snapshot()
        local entries = {}
        for _, entry in ipairs(mp.get_property_native('playlist', {})) do
            entries[#entries + 1] = {id=entry.id, filename=entry.filename, title=entry.title}
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

    mp.observe_property('playlist', 'native', function()
        local live = {}
        for _, entry in ipairs(mp.get_property_native('playlist', {})) do
            if entry.id ~= nil then live[entry.id] = entry.filename end
        end
        for id, policy in pairs(exact_entries) do
            if live[id] ~= policy.path then exact_entries[id] = nil end
        end
    end)
    mp.add_hook('on_load', 50, function()
        local list = mp.get_property_native('playlist', {})
        local entry = list[mp.get_property_number('playlist-pos', -1) + 1]
        local policy = entry and exact_entries[entry.id]
        if policy and policy.path == entry.filename then
            mp.set_property('file-local-options/autocreate-playlist', 'no')
            if policy.image then mp.set_property('file-local-options/image-display-duration', 'inf') end
        end
    end)

    local errors = {
        native_entry_required='此格式请拖入播放器主窗口打开',
        parent_unavailable='播放器已不可用，请重新打开',
        input_unavailable='无法读取所选文件或剪贴板',
        input_too_large='文件数量或路径内容过多，未修改播放列表',
        playlist_read_failed='未能读取播放列表，请检查文件内容或编码',
        playlist_core_unavailable='无法读取播放列表，请检查播放器组件是否完整',
        target_changed='目标文件已变化，未覆盖；请重新保存',
        save_failed='保存播放列表失败，请检查目标文件',
        invalid_target='请将播放列表保存为 .m3u8 文件',
        target_busy='目标文件正在保存，请稍后重试',
    }

    local function valid_entries(entries)
        if type(entries) ~= 'table' or #entries > 10000 then return false end
        for _, entry in ipairs(entries) do
            if type(entry) ~= 'table' or type(entry.path) ~= 'string' or entry.path == ''
                or #entry.path > 131072 or entry.path:find('[%z\1-\31\127]')
                or (entry.kind ~= 'media' and entry.kind ~= 'image' and entry.kind ~= 'subtitle' and entry.kind ~= 'native') then return false end
            if entry.from_playlist ~= nil and type(entry.from_playlist) ~= 'boolean' then return false end
            if entry.title ~= nil and type(entry.title) ~= 'string' then return false end
            if entry.from_playlist and entry.kind == 'subtitle' then return false end
        end
        return true
    end

    local function count(value)
        value = tonumber(value)
        return value and value >= 0 and value <= 10000 and value == math.floor(value) and value or 0
    end

    local function cleanup_segments(segments)
        for _, segment in pairs(segments) do os.remove(segment.path) end
    end

    local function prepare_segments(entries, generation)
        local segments, index = {}, 1
        while index <= #entries do
            if entries[index].from_playlist then
                local first, lines, images = index, {'#EXTM3U'}, {}
                repeat
                    local entry = entries[index]
                    if entry.title and entry.title ~= '' then
                        lines[#lines+1] = '#EXTINF:-1,' .. entry.title:gsub('[%z\1-\31\127]', ' ')
                    end
                    lines[#lines+1] = entry.path
                    if entry.kind == 'image' then images[image_key(entry.path)] = true end
                    index = index + 1
                until not entries[index] or not entries[index].from_playlist
                local temp = os.getenv('TEMP') or os.getenv('TMP')
                if not temp or temp == '' then cleanup_segments(segments); return nil end
                local path = utils.join_path(temp, 'mpvnet-import-' .. session .. '-' .. generation .. '-' .. first .. '.m3u8')
                local file = io.open(path, 'wb')
                if not file then cleanup_segments(segments); return nil end
                segments[first] = {path=path, last=index-1, images=images}
                local written = file:write(table.concat(lines, '\n') .. '\n')
                local closed = file:close()
                if not written or not closed then cleanup_segments(segments); return nil end
            else index = index + 1 end
        end
        return segments
    end

    local function load_list_segment(segment, replace, generation)
        local before = {}
        for _, entry in ipairs(mp.get_property_native('playlist', {})) do
            if entry.id ~= nil then before[entry.id] = true end
        end
        -- A memory:// body becomes every entry's playlist-path. A short-lived
        -- file keeps that provenance short even for a large list.
        local encoding = mp.get_property('options/metadata-codepage', 'auto')
        local forced = encoding:sub(1, 1) == '+' and encoding:lower() ~= '+utf-8' and encoding:lower() ~= '+utf8'
        if forced then
            local ok, err = mp.set_property('options/metadata-codepage', 'utf-8')
            if not ok then return err or 'encoding' end
        end
        local _, err = mp.command_native({'loadlist', segment.path,
            replace and 'replace' or 'append'})
        -- The source has already been decoded by the helper. Only the synchronous
        -- parse of our normalized UTF-8 transport needs this temporary override.
        if forced and mp.get_property('options/metadata-codepage') == 'utf-8' then
            mp.set_property('options/metadata-codepage', encoding)
        end
        if not err and not closing and generation == sequence then
            for _, entry in ipairs(mp.get_property_native('playlist', {})) do
                if entry.id ~= nil and not before[entry.id] and entry['playlist-path'] == segment.path then
                    exact_entries[entry.id] = {path=entry.filename, image=segment.images[image_key(entry.filename)] == true}
                end
            end
        end
        return err
    end

    local function commit(mode, operation, data, generation)
        if #data.entries == 0 then
            if (tonumber(data.unreadable_directories) or 0) > 0 then
                feedback.show(string.format('无法读取 %d 个文件夹，当前队列保持不变', count(data.unreadable_directories)), 'error')
            elseif count(data.skipped_images) > 0 then
                feedback.show(string.format('图片管理未开启，已跳过 %d 个图片文件', count(data.skipped_images)), 'action')
            elseif count(data.skipped_links) > 0 then
                feedback.show(string.format('已跳过 %d 个目录链接，当前队列保持不变', count(data.skipped_links)), 'action')
            elseif count(data.missing_files) > 0 then
                feedback.show(string.format('已跳过 %d 个缺失文件，当前队列保持不变', count(data.missing_files)), 'error')
            elseif data.had_playlist then
                feedback.show('播放列表文件中没有可用条目', 'action')
            elseif (tonumber(data.duplicates) or 0) > 0 then
                feedback.show('所选文件已在播放列表中', 'action')
            elseif operation == 'folder' then feedback.show('文件夹中没有可添加的媒体', 'action')
            else feedback.show('没有可添加的媒体文件', 'error') end
            return
        end
        local segments = prepare_segments(data.entries, generation)
        if not segments then
            if not closing and generation == sequence then feedback.show('无法准备播放列表，当前队列保持不变', 'error') end
            return
        end
        local replaced, failed, index = false, 0, 1
        while index <= #data.entries do
            if closing or generation ~= sequence then break end
            local entry = data.entries[index]
            if entry.from_playlist then
                local segment = segments[index]
                local last = segment.last
                local replace = mode == 'open' and not replaced
                local err = load_list_segment(segment, replace, generation)
                if err then failed = failed + last-index+1
                elseif replace then
                    replaced = true
                    if not closing and generation == sequence then mp.set_property_native('pause', false) end
                end
                index = last
            elseif entry.kind == 'subtitle' then
                local _, err = mp.command_native({'sub-add', entry.path})
                if err then failed = failed + 1 end
            else
                local replace = mode == 'open' and not replaced
                local args = {'loadfile', entry.path, replace and 'replace' or 'append'}
                -- Explicit batches are exact selections. Retain the user's
                -- autocreate-playlist preference only for one selected media.
                if entry.kind == 'image' or entry.kind == 'media' and not (replace and data.single_media == true) then
                    args[4], args[5] = -1, {['autocreate-playlist']='no'}
                    -- mpv applies this only to single-frame images. Animated
                    -- images retain core timing; the option stays file-local.
                    if entry.kind == 'image' then args[5]['image-display-duration'] = 'inf' end
                end
                local _, err = mp.command_native(args)
                if err then failed = failed + 1
                elseif replace then
                    replaced = true
                    if not closing and generation == sequence then mp.set_property_native('pause', false) end
                end
            end
            index = index + 1
        end
        cleanup_segments(segments)
        if closing or generation ~= sequence then return end
        local notices = {}
        if failed > 0 then notices[#notices+1] = '部分文件未能加入播放列表' end
        if count(data.unreadable_directories) > 0 then notices[#notices+1] = string.format('已添加可用文件，%d 个文件夹无法读取', count(data.unreadable_directories)) end
        if count(data.skipped_images) > 0 then notices[#notices+1] = string.format('图片管理未开启，已跳过 %d 个图片文件', count(data.skipped_images)) end
        if count(data.skipped_links) > 0 then notices[#notices+1] = string.format('已跳过 %d 个目录链接', count(data.skipped_links)) end
        if count(data.missing_files) > 0 then notices[#notices+1] = string.format('已跳过 %d 个缺失文件', count(data.missing_files)) end
        if count(data.skipped) > 0 then notices[#notices+1] = '已跳过无法加入的文件' end
        if #notices > 0 then feedback.show(table.concat(notices, '\n'),
            (failed > 0 or count(data.unreadable_directories) > 0) and 'error' or 'action') end
    end

    local function payload_for(mode, operation, files, state, id)
        local existing = {}
        for _, entry in ipairs(state.entries) do
            if type(entry.filename) == 'string' then existing[#existing+1] = entry.filename end
        end
        return {schema=1, request_id=id, parent_pid=mp.get_property_number('pid', 0),
            operation=operation, mode=mode, paths=files or {}, working_directory=state.cwd,
            include_images=read_include_images ~= nil and read_include_images() == true,
            video_exts=extensions('video-exts'), audio_exts=extensions('audio-exts'),
            image_exts=extensions('image-exts'), subtitle_exts=extensions('sub-auto-exts'),
            metadata_codepage=mp.get_property('options/metadata-codepage', 'auto'), existing_paths=existing}
    end

    local function cancel_writer(job)
        if job.timer then job.timer:kill() end
        local flag = io.open(job.path .. '.cancel', 'wb')
        if flag then flag:write('cancel'); flag:close() end
        -- Only our identified reply can be removed. An unknown occupied result
        -- path is never treated as a temporary file owned by this request.
        local file = io.open(job.path .. '.result', 'rb')
        if file then
            local raw = file:read(4*1024*1024+1) or ''; file:close()
            local data = #raw <= 4*1024*1024 and utils.parse_json(raw) or nil
            if type(data) == 'table' and data.schema == 1 and data.request_id == job.id then os.remove(job.path .. '.result') end
        end
        if not utils.file_info(job.path) then os.remove(job.path .. '.cancel') end
    end

    local function launch(payload, is_save, completed)
        local temp = os.getenv('TEMP') or os.getenv('TMP')
        if not temp or temp == '' or not utils.file_info(executable) then
            feedback.show('无法打开文件操作，请检查套件是否完整', 'error'); return
        end
        local id = payload.request_id
        local path = utils.join_path(temp, 'mpvnet-input-' .. id .. '.json')
        local raw_payload = utils.format_json(payload)
        if not raw_payload or #raw_payload > 2*1024*1024 then
            feedback.show('文件操作内容过多，未修改播放列表', 'error'); return
        end
        local file = io.open(path, 'wb')
        if not file then feedback.show('无法准备文件操作', 'error'); return end
        local written = file:write(raw_payload)
        local closed = file:close()
        if not written or not closed then os.remove(path); feedback.show('无法准备文件操作', 'error'); return end
        local job = {id=id, path=path, generation=sequence}
        if is_save then saving = job else pending = job end
        local function finish(ok, result, parsed)
            os.remove(path)
            if job.timer then job.timer:kill() end
            if closing or (is_save and saving ~= job) or (not is_save and pending ~= job) then return end
            if is_save then saving = nil else pending = nil end
            local raw = result and result.stdout or ''
            local data = parsed or (#raw <= 4*1024*1024 and utils.parse_json(raw) or nil)
            if closing or (not is_save and job.generation ~= sequence) then return end
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
            completed(data, job)
        end
        if not is_save then
            job.handle = mp.command_native_async({name='subprocess', args={executable, '-RequestPath', path},
                capture_stdout=true, capture_stderr=false, playback_only=false}, finish)
            return
        end
        -- mpv kills ordinary subprocesses during shutdown even when
        -- playback_only=false. Detach only the already-confirmed atomic writer.
        local result = mp.command_native({name='subprocess', args={executable, '-RequestPath', path, '-DetachedSave'},
            detach=true, capture_stdout=false, capture_stderr=false, playback_only=false})
        if not result or result.status ~= 0 then
            os.remove(path); saving=nil
            feedback.show('未能启动保存，请重试', 'error'); return
        end
        job.deadline = mp.get_time() + 30
        local function poll()
            if closing or saving ~= job then job.timer:kill(); return end
            local file = io.open(path .. '.result', 'rb')
            if file then
                local raw = file:read(4*1024*1024+1) or ''; file:close()
                local data = #raw <= 4*1024*1024 and utils.parse_json(raw) or nil
                if type(data) == 'table' and data.schema == 1 and data.request_id == id then
                    os.remove(path .. '.result')
                    finish(true, {status=0}, data)
                else
                    cancel_writer(job); saving=nil
                    feedback.show('未能确认保存结果，请检查目标文件', 'error')
                end
            elseif mp.get_time() >= job.deadline then
                cancel_writer(job); saving=nil
                feedback.show('保存尚未确认完成，请检查目标文件后重试', 'error')
            end
        end
        job.timer = mp.add_periodic_timer(0.1, poll)
        poll()
    end

    local function request(mode, operation, files)
        if closing then return end
        retire()
        sequence = sequence + 1
        local generation, state = sequence, snapshot()
        launch(payload_for(mode, operation, files, state, session .. '-' .. sequence), false, function(data)
            if not valid_entries(data.entries) then feedback.show('未能读取文件操作结果', 'error'); return end
            if not unchanged(state) then feedback.show('播放列表已变化，请重新选择文件', 'action'); return end
            commit(mode, operation, data, generation)
        end)
    end

    local function valid_target(data)
        return type(data.target_path) == 'string' and #data.target_path > 0 and #data.target_path <= 131072
            and not data.target_path:find('[%z\1-\31\127]')
            and type(data.target_exists) == 'boolean' and type(data.target_sha256) == 'string'
            and ((not data.target_exists and data.target_sha256 == '') or
                (data.target_exists and #data.target_sha256 == 64 and not data.target_sha256:find('[^0-9a-f]')))
    end

    local function save()
        if closing then return end
        if saving then feedback.show('正在保存播放列表，请稍候', 'action'); return end
        if #snapshot().entries == 0 then feedback.show('播放列表为空，无法保存', 'action'); return end
        retire()
        sequence = sequence + 1
        local dialog = payload_for('save', 'save-dialog', {}, snapshot(), session .. '-' .. sequence)
        dialog.existing_paths = {}
        dialog.suggested_path = last_save_path
        launch(dialog, false, function(target, job)
            if not valid_target(target) then feedback.show('未能确认保存位置，未写入文件', 'error'); return end
            -- The queue may legitimately change while the user chooses a path.
            -- Snapshot after confirmation, then keep this explicit write independent
            -- of later open/append requests. Do not kill an atomic write mid-flight.
            local state = snapshot()
            if #state.entries == 0 then feedback.show('播放列表为空，未保存', 'action'); return end
            local write = payload_for('save', 'save', {}, state, job.id .. '-write')
            write.existing_paths, write.save_entries = {}, {}
            write.target_path, write.target_exists, write.target_sha256 = target.target_path, target.target_exists, target.target_sha256
            for _, entry in ipairs(state.entries) do
                if type(entry.filename) ~= 'string' or entry.filename == '' then
                    feedback.show('无法读取完整播放列表，未保存', 'error'); return
                end
                write.save_entries[#write.save_entries+1] = {path=entry.filename,
                    title=type(entry.title) == 'string' and entry.title or ''}
            end
            launch(write, true, function(data)
                if data.saved ~= true or data.target_path ~= target.target_path then
                    feedback.show('未能确认保存结果，请检查目标文件', 'error'); return
                end
                last_save_path = data.target_path
                feedback.show('已保存播放列表', 'success')
            end)
        end)
    end

    return {
        request=request,
        save=save,
        clear=function()
            if closing then return end
            -- Retire pending input before stopping, so late scan/dialog results
            -- cannot refill the cleared queue. A confirmed save stays independent.
            retire(); sequence=sequence+1
            local _, err=mp.command_native({'stop'})
            if err then feedback.show('无法清空播放列表，请重试', 'error') end
        end,
        shutdown=function()
            closing=true; retire()
            -- Parent-exit cancellation is owned by the writer, which can finish
            -- its cleanup without being terminated between Flush and Replace.
            if saving then cancel_writer(saving) end
        end,
    }
end

return M
