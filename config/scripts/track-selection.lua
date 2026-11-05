-- One selector session owns track, chapter, subtitle line, device, binding and saved media submissions.
-- mpv normalizes this filename to the script name track_selection.
local mp = require('mp')
local selector
local media_generation, session_generation = 0, 0
local active_kind
local chapter_snapshot
local edition_snapshot
local history_data, history_snapshot
local watch_later_data, refresh_watch_later
local subtitle_lines, refresh_subtitle_lines, retire_subtitle_lines
local bindings_data, binding_labels
local device_ids, device_names, device_rows, next_device_id
local track_ids, track_targets, next_track_id
local kinds = {
    all = {label='全部轨道'},
    audio = {property='aid', type='audio', label='音轨'},
    video = {property='vid', type='video', label='视频轨'},
    subtitle = {property='sid', type='sub', label='字幕'},
    primary = {property='sid', type='sub', label='主字幕', other='secondary-sid', other_label='次字幕'},
    secondary = {property='secondary-sid', type='sub', label='次字幕', other='sid', other_label='主字幕'},
    chapter = {property='chapter', label='章节'},
    lines = {label='字幕行'},
    edition = {property='edition', label='媒体版本'},
    device = {property='audio-device', label='音频设备'},
    history = {label='播放历史'},
    watchlater = {label='稍后继续播放'},
    bindings = {label='快捷键'},
}

local function valid_device_name(name)
    return type(name) == 'string' and name:match('%S') and not name:find('[%z\1-\31\127]')
end

-- Walk backward over UTF-8 continuation bytes, so a short identifier never
-- starts in the middle of a character. Raw names remain unchanged for submit.
local function name_suffix(name, count)
    local start = #name + 1
    for _ = 1, count do
        if start <= 1 then break end
        start = start - 1
        while start > 1 and name:byte(start) >= 128 and name:byte(start) < 192 do start = start - 1 end
    end
    return name:sub(start)
end

local function output_devices()
    local source = mp.get_property_native('audio-device-list', {})
    local rows, seen, bases = {}, {}, {}
    for _, device in ipairs(type(source) == 'table' and source or {}) do
        local name = type(device) == 'table' and device.name
        if valid_device_name(name) and not seen[name] then
            seen[name] = true
            if not device_ids[name] then
                next_device_id = next_device_id + 1
                device_ids[name] = next_device_id
                device_names[next_device_id] = name
            end
            local description = type(device.description) == 'string' and device.description:match('%S') and device.description or name
            local title = name == 'auto' and '自动选择' or description
            title = title:gsub('[%z\1-\31\127]', ' ')
            rows[#rows + 1] = {id=device_ids[name], title=title, device_name=name, detail_title=description}
            bases[title] = (bases[title] or 0) + 1
        end
    end
    -- Reserve all readable names before adding suffixes. This also prevents a
    -- generated suffix from colliding with another device's literal description.
    local ordered, used = {}, {}
    for _, row in ipairs(rows) do ordered[#ordered + 1] = row end
    table.sort(ordered, function(a, b) return a.id < b.id end)
    for _, row in ipairs(ordered) do
        local base = row.title
        if bases[base] > 1 and row.device_name ~= 'auto' then
            local count, title = 6
            while true do
                local suffix = name_suffix(row.device_name, count)
                title = base .. ' · ' .. suffix
                local collision = bases[title] or used[title]
                for _, other in ipairs(rows) do
                    if other ~= row and other.title == base and
                        name_suffix(other.device_name, count) == suffix then collision = true end
                end
                if not collision then break end
                if suffix == row.device_name then
                    title = title .. ' #' .. row.id
                    while bases[title] or used[title] do title = title .. ' #' .. row.id end
                    break
                end
                count = count + 1
            end
            row.title = title
        end
        used[row.title] = true
    end
    device_rows = rows
    return rows
end

local function chapter_list()
    local source = mp.get_property_native('chapter-list', {})
    local snapshot = {}
    for index, chapter in ipairs(type(source) == 'table' and source or {}) do
        snapshot[index] = {
            time=type(chapter) == 'table' and chapter.time or nil,
            title=type(chapter) == 'table' and type(chapter.title) == 'string' and chapter.title or '',
        }
    end
    return snapshot
end

local function same_chapters(left, right)
    if not left or #left ~= #right then return false end
    for index, chapter in ipairs(left) do
        local other = right[index]
        local same_time = chapter.time == other.time or
            (type(chapter.time) == 'number' and chapter.time ~= chapter.time and
                type(other.time) == 'number' and other.time ~= other.time)
        if not same_time or chapter.title ~= other.title then return false end
    end
    return true
end

local function valid_time(value)
    return type(value) == 'number' and value >= 0 and value < math.huge
end

local function chapter_tracks()
    local duration = mp.get_property_native('duration')
    local hours = valid_time(duration) and duration >= 3600
    for _, chapter in ipairs(chapter_snapshot or {}) do
        if valid_time(chapter.time) and chapter.time >= 3600 then hours = true end
    end
    local tracks = {}
    for index, chapter in ipairs(chapter_snapshot or {}) do
        if valid_time(chapter.time) then
            local seconds = math.floor(chapter.time)
            tracks[#tracks + 1] = {id=index, title=chapter.title,
                time_text=hours and string.format('%02.0f:%02d:%02d',
                    math.floor(seconds / 3600), math.floor(seconds / 60) % 60, seconds % 60) or
                    string.format('%02d:%02d', math.floor(seconds / 60), seconds % 60)}
        end
    end
    return tracks
end

local function edition_list()
    local list=mp.get_property_native('edition-list',{})
    local out={}
    for index,item in ipairs(type(list)=='table' and list or {}) do
        out[index]={edition_id=type(item)=='table' and item.id or nil,
            title=type(item)=='table' and type(item.title)=='string' and item.title or ''}
    end
    return out
end
local function same_editions(left,right)
    if not left or #left~=#right then return false end
    for index,item in ipairs(left) do
        if item.edition_id~=right[index].edition_id or item.title~=right[index].title then return false end
    end
    return true
end
local function edition_tracks()
    local out={}
    for index,item in ipairs(edition_snapshot or {}) do
        local number=type(item.edition_id)=='number' and item.edition_id>=0 and item.edition_id<math.huge and
            item.edition_id==math.floor(item.edition_id) and item.edition_id+1 or index
        out[#out+1]={id=index,title=item.title:match('%S') and item.title or '版本 '..number,number_text=tostring(number)}
    end
    return out
end
local function subtitle_slot_id(property)
    local current=mp.get_property_native(property)
    if current=='auto' then
        current=mp.get_property_native(property=='sid' and 'current-tracks/sub/id' or 'current-tracks/sub2/id')
    end
    local id=tonumber(current)
    return id and id>0 and id<math.huge and id==math.floor(id) and id or 0
end
local function current_id(kind)
    if kind=='all' then return 0 end
    if kinds[kind].other then return subtitle_slot_id(kinds[kind].property) end
    if kind=='edition' then
        local current=mp.get_property_native('current-edition')
        return type(current)=='number' and current>=0 and current==math.floor(current) and
            current<#(edition_snapshot or {}) and current+1 or 0
    end
    local current = mp.get_property_native(kinds[kind].property)
    if kind == 'device' then
        for _, row in ipairs(device_rows or {}) do if row.device_name == current then return row.id end end
        return 0
    end
    if kind ~= 'chapter' then return current end
    current = tonumber(current)
    return current and current >= 0 and current < math.huge and current == math.floor(current) and current + 1 or 0
end

-- UI identities are session-local and never shared across native track types.
local track_kinds={video='video',audio='audio',sub='primary'}
local function selected_track(kind)
    if kind=='primary' then return subtitle_slot_id('sid') end
    local current=mp.get_property_native(kinds[kind].property)
    if current=='auto' then current=mp.get_property_native('current-tracks/'..kinds[kind].type..'/id') end
    return tonumber(current) or 0
end
local function all_tracks()
    local source=mp.get_property_native('track-list',{})
    local rows,seen={},{}
    for _,type_name in ipairs({'video','audio','sub'}) do
        local kind=track_kinds[type_name]
        for _,track in ipairs(type(source)=='table' and source or {}) do
            local real_id=type(track)=='table' and track.id
            if type(track)=='table' and track.type==type_name and type(real_id)=='number' and
                real_id>0 and real_id<math.huge and real_id==math.floor(real_id) then
                local key=type_name..':'..real_id
                if not seen[key] then
                    seen[key]=true
                    if not track_ids[key] then
                        next_track_id=next_track_id+1
                        track_ids[key]=next_track_id
                        track_targets[next_track_id]={kind=kind,id=real_id}
                    end
                    local row={};for name,value in pairs(track) do row[name]=value end
                    row.id=track_ids[key];row.number_text=tostring(real_id)
                    row.display_kind=kind;row.current=real_id==selected_track(kind)
                    if kind=='primary' and real_id==subtitle_slot_id('secondary-sid') then
                        row.blocked_reason='该轨道已用于次字幕，不能同时用于主字幕。'
                        row.slot_label='已用于次字幕'
                    end
                    rows[#rows+1]=row
                end
            end
        end
    end
    return rows
end
local function invalidate_video_restore()
    local property='user-data/mpvnet/video-selection-revision'
    local revision=mp.get_property_native(property,0)
    if type(revision)~='number' or revision~=revision or revision<0 or revision>=math.huge then revision=0 end
    mp.set_property_native(property,revision+1)
end

local function tracks_for(kind)
    if kind=='all' then return all_tracks() end
    if kind == 'chapter' then return chapter_tracks() end
    if kind == 'device' then return output_devices() end
    if kind == 'edition' then return edition_tracks() end
    local tracks = {}
    local source = mp.get_property_native('track-list', {})
    for _, track in ipairs(type(source) == 'table' and source or {}) do
        if track.type == kinds[kind].type and
            (kind ~= 'subtitle' or track.title ~= 'Bilibili Danmaku') then
            -- Preserve native metadata for the renderer; never rewrite the track.
            if kinds[kind].other then
                local row={};for key,value in pairs(track) do row[key]=value end
                if tonumber(track.id)==subtitle_slot_id(kinds[kind].other) then
                    row.blocked_reason='该轨道已用于'..kinds[kind].other_label..'，不能同时用于'..kinds[kind].label..'。'
                    row.slot_label='已用于'..kinds[kind].other_label
                end
                tracks[#tracks+1]=row
            else tracks[#tracks + 1] = track end
        end
    end
    return tracks
end

local function selection_notice(kind,tracks,selected)
    if kind=='all' and mp.get_property_native('sub-visibility')==false then
        for _,track in ipairs(tracks) do
            if track.display_kind=='primary' then return '主字幕当前隐藏，选择轨道不会开启显示。' end
        end
    end
    if kind=='device' and #tracks>0 and selected==0 then return '已选设备不在列表中，可重新选择。' end
    if kind=='secondary' then
        for _,track in ipairs(tracks) do
            if tonumber(track.id)==selected and track.title=='Bilibili Danmaku' then
                return '次字幕槽正用于弹幕，改选可能影响弹幕。'
            end
        end
    end
    if kinds[kind].other and #tracks>0 then
        local property=kind=='primary' and 'sub-visibility' or 'secondary-sub-visibility'
        if mp.get_property_native(property)==false then return kinds[kind].label..'当前隐藏，选择轨道不会开启显示。' end
    end
    return ''
end

local function retire_session()
    -- Retire callbacks before close(), which may invoke the old callback inline.
    session_generation = session_generation + 1
    active_kind = nil
    chapter_snapshot = nil
    edition_snapshot = nil
    history_snapshot = nil
    refresh_watch_later = nil
    if retire_subtitle_lines then
        local retire = retire_subtitle_lines
        refresh_subtitle_lines, retire_subtitle_lines = nil, nil
        retire()
    end
    device_ids, device_names, device_rows, next_device_id = nil, nil, nil, nil
    track_ids, track_targets, next_track_id = nil, nil, nil
end

local function close_selector()
    retire_session()
    if selector then selector.close() end
end

local function refresh_selector()
    if active_kind and active_kind ~= 'history' and active_kind ~= 'watchlater' and active_kind ~= 'lines' and active_kind ~= 'bindings' and
        selector and selector.is_open() then
        local tracks = tracks_for(active_kind)
        local selected = current_id(active_kind)
        local notice = selection_notice(active_kind,tracks,selected)
        selector.update(tracks, selected, notice)
    end
end

local function load_history_data()
    if history_data then return true end
    local ok, module = pcall(dofile,
        mp.command_native({'expand-path', '~~/script-modules/history-data.lua'}))
    if not ok or type(module) ~= 'table' then return false end
    for _, method in ipairs({'options', 'parse', 'source', 'same_source', 'matches', 'run'}) do
        if type(module[method]) ~= 'function' then return false end
    end
    history_data = module
    return true
end

local function load_selector(kind)
    if selector then return true end
    local ok, module = pcall(dofile,
        mp.command_native({'expand-path', '~~/script-modules/track-selector.lua'}))
    if ok and type(module) == 'table' and type(module.open) == 'function' and
        type(module.update) == 'function' and type(module.close) == 'function' and
        type(module.is_open) == 'function' then
        selector = module
        return true
    end
    mp.osd_message('无法打开' .. kinds[kind].label .. '选择器，请检查配置包文件。', 3)
    return false
end

local function effective_bindings()
    if not bindings_data then
        local ok, module = pcall(dofile,
            mp.command_native({'expand-path', '~~/script-modules/bindings-data.lua'}))
        if not ok or type(module) ~= 'table' or type(module.effective) ~= 'function' or
            type(module.rows) ~= 'function' then return nil end
        bindings_data = module
    end
    local ok, source = pcall(mp.get_property_native, 'input-bindings')
    if ok then return bindings_data.effective(source) end
end

local function binding_catalog()
    if not binding_labels then
        -- Use the built-in action labels only. The live binding snapshot is the
        -- sole source for commands; no input or preference file is read here.
        local ok, labels = pcall(function()
            local model = dofile(mp.command_native({'expand-path', '~~/script-modules/user-shortcuts.lua'}))
            return model.catalog('').by_command
        end)
        binding_labels = ok and type(labels) == 'table' and labels or {}
    end
    return binding_labels
end

local function select_bindings()
    if not load_selector('bindings') then return end
    close_selector()
    active_kind = 'bindings'
    local session, media = session_generation, media_generation
    local function live()
        return session == session_generation and media == media_generation and
            active_kind == 'bindings' and selector.is_open()
    end
    -- Read outside the panel's exclusive input section. Reuse this snapshot
    -- until closing; our own temporary inputs must never trigger a refresh.
    local effective = effective_bindings()
    local rows, targets, state = {}, {}, {}
    if effective then
        rows, targets = bindings_data.rows(effective, binding_catalog())
        if #rows == 0 then
            state = {empty_title='没有可执行的快捷键', empty_hint='生效的快捷键会出现在这里。'}
        end
    else
        state = {empty_title='未能读取快捷键', empty_hint='请检查配置包文件，然后重试。', can_retry=true}
    end
    local opened, err = selector.open({kind='bindings', tracks=rows, current_id=0, state=state,
        submit=function(id)
            if not live() then return false, '选择已失效，请重新打开选择器。' end
            local target = targets[tonumber(id)]
            if not target then return false, '该快捷键已失效，请重新选择。' end

            -- Retire before restoring input and rechecking the command. The
            -- command itself can open a selector, change media, or quit.
            local retired = session_generation + 1
            local function still_retired()
                return retired == session_generation and media == media_generation and not selector.is_open()
            end
            close_selector()
            if not still_retired() then return false end
            local latest = effective_bindings()
            if not still_retired() then return false end
            if not latest then
                mp.osd_message('未能核对快捷键，请重新打开选择器。', 3)
                return false
            end
            if not latest[target.key] or latest[target.key].cmd ~= target.cmd then
                mp.osd_message('该快捷键已变化，请重新打开选择器。', 3)
                return false
            end
            -- Keep quoting, flags and multi-command sequences exactly as mpv
            -- supplied them. Do not include native errors in our OSD or logs.
            local ok, applied = pcall(mp.command, target.cmd)
            if not ok or applied ~= true then
                if still_retired() then mp.osd_message('未能执行该快捷键，请重试。', 3) end
                return false
            end
            return true
        end,
        retry=function() if live() then select_bindings() end end,
        close=function() if session == session_generation then retire_session() end end,
    })
    if not opened and session == session_generation then
        close_selector()
        mp.osd_message(err or '无法打开快捷键选择器，请重试。', 3)
    end
end

local history_loading = {empty_title='正在读取播放历史…', empty_hint=''}
local history_changed = '播放历史已变化，请重新选择。'

local function select_history()
    if not load_selector('history') then return end
    close_selector()
    active_kind = 'history'
    local session, media = session_generation, media_generation
    local phase, opts, next_id = nil, nil, 0
    local function live()
        return session == session_generation and media == media_generation and
            active_kind == 'history' and selector.is_open()
    end
    local function no_rows(title, hint, can_retry, notice)
        history_snapshot = nil
        selector.update({}, 0, notice or '', {empty_title=title, empty_hint=hint, can_retry=can_retry})
    end
    local function read(notice, first)
        if not live() or phase == 'reading' or phase == 'clearing' then return end
        phase = 'reading'
        if not first then selector.update({}, 0, '', history_loading) end
        local source
        if load_history_data() then
            if not opts then
                local ok, values = pcall(history_data.options)
                if ok and type(values) == 'table' then opts = values end
            end
            if opts then source = history_data.source() end
        end
        if not source then
            phase = 'ready'
            no_rows('未能读取播放历史', '请检查历史文件设置后重试。', true, notice)
            return
        end
        history_data.run('Read', source, nil, function(reply)
            if not live() then return end
            phase = 'ready'
            if not history_data.same_source(source, history_data.source()) then
                no_rows('播放历史文件位置已变化', '请重试读取。', true, notice)
            elseif reply.ok ~= true then
                local hint = reply.code == 'too_large' and '历史文件超过 2 MiB，未能载入。' or
                    reply.code == 'encoding' and '历史文件不是可读取的 UTF-8 文本。' or
                    '请检查历史文件是否可访问，然后重试。'
                no_rows('未能读取播放历史', hint, true, notice)
            elseif reply.missing == true and mp.get_property_native('save-watch-history') == false then
                no_rows('尚未启用播放历史', '启用播放历史记录后，新播放的媒体会出现在这里。', true, notice)
            elseif reply.missing == true or reply.content == '' then
                no_rows('没有播放历史', '播放过的媒体会出现在这里。', false, notice)
            else
                local previous = history_snapshot
                if not previous or not history_data.same_source(source, previous.source) or
                    previous.content ~= reply.content then
                    local rows, warning = history_data.parse(reply.content, opts)
                    local targets = {}
                    for _, row in ipairs(rows) do
                        next_id = next_id + 1
                        row.id = next_id
                        targets[next_id] = row.history_path
                    end
                    history_snapshot = {source=source, content=reply.content, hash=reply.hash,
                        rows=rows, targets=targets, warning=warning}
                end
                local snapshot = history_snapshot
                local warning = snapshot.warning
                if notice then warning = notice .. (warning == '' and '' or ' ' .. warning) end
                if #snapshot.rows == 0 then
                    no_rows('没有有效的播放历史', '历史文件没有可播放的记录。', true, warning)
                else
                    selector.update(snapshot.rows, 0, warning, {can_clear=true})
                end
            end
        end)
    end
    local opened, error = selector.open({kind='history', tracks={}, current_id=0, notice='', state=history_loading,
        submit=function(id)
            if not live() then return false, '选择已失效，请重新打开选择器。' end
            local snapshot = phase == 'ready' and history_snapshot
            local path = snapshot and snapshot.targets[tonumber(id)]
            if not path then return false, '这条记录已失效，请重新选择。' end
            local source = history_data.source()
            local matches = history_data.same_source(snapshot.source, source) and history_data.matches(source, snapshot.content)
            if not matches then
                local notice = matches == nil and '未能核对播放历史，请重试。' or history_changed
                read(notice)
                return false, notice
            end
            -- Match the built-in history's plain loadfile (replace) behavior.
            -- A media-open error after acceptance is still reported by mpv.
            local _, err = mp.command_native({'loadfile', path})
            if err then return false, '未能打开该记录，请重试。' end
            return true
        end,
        clear=function(done)
            if not live() then done(false, '操作已失效，请重新打开播放历史。'); return end
            local snapshot = phase == 'ready' and history_snapshot
            if not snapshot then done(false, '播放历史正在更新或没有可清空的记录。'); return end
            local source = history_data.source()
            if not history_data.same_source(snapshot.source, source) then
                local notice = '历史文件位置已变化，本次未清空。请核对后重试。'
                read(notice)
                done(false, notice)
                return
            end
            phase = 'clearing'
            history_data.run('Clear', source, snapshot.hash, function(reply)
                if not live() then return end
                phase = 'ready'
                if reply.ok == true then
                    history_snapshot = nil
                    read('播放历史已清空。')
                    done(true)
                elseif reply.code == 'conflict' or reply.code == 'too_large' then
                    local notice = '播放历史已变化，本次未清空。请核对后重试。'
                    read(notice)
                    done(false, notice)
                elseif reply.code == 'io' then
                    done(false, '未能清空播放历史，记录已保留。请检查文件是否被占用。')
                else
                    local notice = '未能确认清空结果，请查看重新读取的记录。'
                    read(notice)
                    done(false, notice)
                end
            end)
        end,
        retry=function() read() end,
        close=function() if session == session_generation then retire_session() end end,
    })
    if not opened then
        close_selector()
        mp.osd_message(error or '无法打开播放历史选择器，请重试。', 3)
    else
        read(nil, true)
    end
end

local function load_watch_later_data()
    if watch_later_data then return true end
    local ok, module = pcall(dofile,
        mp.command_native({'expand-path', '~~/script-modules/watch-later-data.lua'}))
    if not ok or type(module) ~= 'table' then return false end
    for _, method in ipairs({'parse', 'source', 'matches', 'run'}) do
        if type(module[method]) ~= 'function' then return false end
    end
    watch_later_data = module
    return true
end

local watch_later_loading = {empty_title='正在读取保存记录…', empty_hint=''}
local watch_later_changed = '保存记录已变化，请重新选择。'
local resume_disabled = '已关闭进度恢复，将按播放器当前设置打开。'

local function select_watch_later()
    if not load_selector('watchlater') then return end
    close_selector()
    active_kind = 'watchlater'
    local session, media = session_generation, media_generation
    local directory, reading, next_id = nil, false, 0
    local rows, targets, state, warning = {}, {}, watch_later_loading, ''
    local function live()
        return session == session_generation and media == media_generation and
            active_kind == 'watchlater' and selector.is_open()
    end
    local function notice()
        if mp.get_property_native('resume-playback') ~= false then return warning end
        return warning == '' and resume_disabled or warning .. ' ' .. resume_disabled
    end
    local function render()
        selector.update(rows, 0, notice(), state)
    end
    local function no_rows(title, hint, can_retry)
        state = {empty_title=title, empty_hint=hint, can_retry=can_retry}
    end
    local function read(reason, first)
        if not live() or reading then return end
        directory = load_watch_later_data() and watch_later_data.source() or nil
        rows, targets, state, warning = {}, {}, watch_later_loading, ''
        if not first then render() end
        warning = reason or ''
        if not directory then
            no_rows('未能读取保存记录', '请检查保存目录和配置包文件，然后重试。', true)
            render()
            return
        end
        reading = true
        watch_later_data.run(directory, function(reply)
            if not live() then return end
            reading = false
            if directory ~= watch_later_data.source() then
                read(watch_later_changed)
                return
            elseif reply.ok ~= true then
                local hint = reply.code == 'too_many' and '保存目录中的文件超过 2048 个，未能载入。' or
                    '请检查保存目录是否可访问，然后重试。'
                no_rows('未能读取保存记录', hint, true)
            elseif reply.missing == true then
                no_rows('没有可继续播放的记录', '保存进度后，播放器会创建保存目录。', false)
            else
                local records, status = watch_later_data.parse(reply)
                if status.notice ~= '' then
                    warning = warning == '' and status.notice or warning .. ' ' .. status.notice
                end
                for _, record in ipairs(records) do
                    next_id = next_id + 1
                    record.row.id = next_id
                    rows[#rows+1] = record.row
                    targets[next_id] = record
                end
                if #rows > 0 then
                    state = {}
                elseif status.unreadable then
                    no_rows('未能读取保存记录', '请检查保存记录是否可访问，然后重试。', true)
                elseif status.no_path then
                    no_rows('记录未包含媒体路径',
                        '启用 write-filename-in-watch-later-config 后重新保存进度。', false)
                else
                    no_rows('没有可继续播放的记录', '可通过“保存进度并退出”留存播放位置。', false)
                end
            end
            render()
        end)
    end
    local opened, error = selector.open({kind='watchlater', tracks=rows, current_id=0, notice=notice(), state=state,
        submit=function(id)
            if not live() then return false, '选择已失效，请重新打开选择器。' end
            local record = targets[tonumber(id)]
            if not record then return false, '这条记录已失效，请重新选择。' end
            local source = watch_later_data.source()
            if source ~= directory or not watch_later_data.matches(source, record) then
                read(watch_later_changed)
                return false, watch_later_changed
            end
            -- Leave the core in charge of resuming and consuming the record.
            local _, err = mp.command_native({'loadfile', record.row.history_path})
            if err then return false, '未能打开该记录，请重试。' end
            return true
        end,
        retry=function() read() end,
        close=function() if session == session_generation then retire_session() end end,
    })
    if not opened then
        close_selector()
        mp.osd_message(error or '无法打开稍后继续播放选择器，请重试。', 3)
        return
    end
    refresh_watch_later = function(property)
        if not live() then return end
        if property == 'resume-playback' then
            render()
        elseif not reading and watch_later_data and directory ~= watch_later_data.source() then
            read(watch_later_changed)
        end
    end
    read(nil, true)
end

local function load_subtitle_lines()
    if subtitle_lines then return true end
    local ok, module = pcall(dofile,
        mp.command_native({'expand-path', '~~/script-modules/subtitle-lines.lua'}))
    if not ok or type(module) ~= 'table' then return false end
    for _, method in ipairs({'source', 'same_source', 'run'}) do
        if type(module[method]) ~= 'function' then return false end
    end
    subtitle_lines = module
    return true
end

local lines_loading = {empty_title='正在读取字幕行…', empty_hint=''}
local lines_changed = '主字幕来源已变化，请重新选择。'
local lines_empty = {
    no_subtitle={empty_title='当前没有主字幕', empty_hint='选择主字幕轨后即可查找字幕行。'},
    bitmap={empty_title='当前主字幕为图形字幕', empty_hint='图形字幕不含可提取的文字。'},
    source={empty_title='无法读取当前主字幕', empty_hint='请检查媒体与字幕来源，然后重试。', can_retry=true},
    failed={empty_title='未能提取字幕行', empty_hint='请确认媒体与字幕来源可读取，然后重试。', can_retry=true},
    ffmpeg={empty_title='无法启动 FFmpeg', empty_hint='请检查 FFmpeg 路径，或将 FFmpeg 加入 PATH，然后重试。', can_retry=true},
    timeout={empty_title='读取字幕行超时', empty_hint='请检查媒体与字幕来源，然后重试。', can_retry=true},
    too_large={empty_title='字幕内容超过读取限制', empty_hint='最多读取 8 MiB、显示 10000 行字幕。'},
    empty={empty_title='没有可选择的字幕行', empty_hint='当前主字幕没有可提取的文字行。'},
    module={empty_title='无法读取字幕行', empty_hint='请检查配置包文件，然后重试。', can_retry=true},
}

local function subtitle_delay()
    local delay = mp.get_property_native('sub-delay')
    return type(delay) == 'number' and delay > -math.huge and delay < math.huge and delay or 0
end

local function select_subtitle_line()
    if not load_selector('lines') then return end
    close_selector()
    active_kind = 'lines'
    local session, media = session_generation, media_generation
    local rows, targets, current, next_id = {}, {}, 0, 0
    local snapshot, pending, notice = nil, nil, ''
    local function live()
        return session == session_generation and media == media_generation and
            active_kind == 'lines' and selector.is_open()
    end
    local function cancel_read()
        local job = pending
        pending = nil
        if job and job.cancel then job.cancel() end
    end
    local function marker()
        local position = mp.get_property_native('time-pos')
        if not valid_time(position) then return 0 end
        local time, left, right = position - subtitle_delay(), 1, #rows
        -- The last row at or before playback time is a reference, even in a gap.
        while left <= right do
            local middle = math.floor((left + right) / 2)
            if targets[rows[middle].id] <= time then left = middle + 1 else right = middle - 1 end
        end
        return right > 0 and rows[right].id or 0
    end
    local function update_marker()
        if not live() or #rows == 0 then return end
        local selected = marker()
        if current == selected then return end
        current = selected
        selector.update(rows, current, notice)
    end
    local function read(source, reason, first)
        if not live() then return end
        cancel_read()
        rows, targets, current, notice = {}, {}, 0, reason or ''
        snapshot = source or (load_subtitle_lines() and subtitle_lines.source() or nil)
        if not snapshot or snapshot.problem then
            selector.update(rows, current, notice, lines_empty[snapshot and snapshot.problem or 'module'])
            return
        end
        if not first then selector.update(rows, current, notice, lines_loading) end
        local job = {}
        pending = job
        job.cancel = subtitle_lines.run(snapshot, function(lines, problem)
            if not live() or pending ~= job then return end
            pending = nil
            local latest = subtitle_lines.source()
            if not subtitle_lines.same_source(snapshot, latest) then
                read(latest, lines_changed)
            elseif not lines or #lines == 0 then
                selector.update(rows, current, notice, lines_empty[problem or 'empty'])
            else
                local duration = mp.get_property_native('duration')
                local hours = (valid_time(duration) and duration >= 3600) or lines[#lines].time >= 3600
                for _, line in ipairs(lines) do
                    next_id = next_id + 1
                    local seconds = line.time
                    rows[#rows+1] = {id=next_id, title=line.title, time_text=hours and
                        string.format('%02.0f:%02d:%02d', math.floor(seconds/3600), math.floor(seconds/60)%60, seconds%60)
                        or string.format('%02d:%02d', math.floor(seconds/60), seconds%60)}
                    targets[next_id] = seconds
                end
                current = marker()
                selector.update(rows, current, notice, {reveal_id=current > 0 and current or nil})
            end
        end)
    end
    local opened, err = selector.open({kind='lines', tracks=rows, current_id=0, notice=notice, state=lines_loading,
        submit=function(id)
            if not live() then return false, '选择已失效，请重新打开选择器。' end
            local time = targets[tonumber(id)]
            if time == nil then return false, '该字幕行已失效，请重新选择。' end
            local latest = subtitle_lines.source()
            if not subtitle_lines.same_source(snapshot, latest) then
                read(latest, lines_changed)
                return false, lines_changed
            end
            local position = time + subtitle_delay()
            if mp.get_property_native('current-tracks/video/image') ~= false then position = position + 0.1 end
            -- A negative absolute mpv seek would count backwards from EOF.
            local _, seek_error = mp.command_native({'seek', math.max(0, position), 'absolute'})
            if seek_error then return false, '未能跳转到该字幕行，请重试。' end
            return true
        end,
        retry=function() if not pending then read() end end,
        close=function() if session == session_generation then retire_session() end end,
    })
    if not opened then
        close_selector()
        mp.osd_message(err or '无法打开字幕行选择器，请重试。', 3)
        return
    end
    retire_subtitle_lines = function()
        cancel_read()
        mp.unobserve_property(update_marker)
    end
    refresh_subtitle_lines = function()
        if not live() or not subtitle_lines then return end
        local latest = subtitle_lines.source()
        if not subtitle_lines.same_source(snapshot, latest) then read(latest, lines_changed) end
    end
    mp.observe_property('time-pos', 'native', update_marker)
    mp.observe_property('sub-delay', 'native', update_marker)
    read(nil, nil, true)
end

local function select_tracks(kind)
    if not load_selector(kind) then return end
    close_selector()
    active_kind = kind
    if kind=='all' then track_ids,track_targets,next_track_id={},{},0 end
    if kind == 'chapter' then chapter_snapshot = chapter_list() end
    if kind == 'edition' then edition_snapshot = edition_list() end
    if kind == 'device' then device_ids, device_names, device_rows, next_device_id = {}, {}, {}, 0 end
    local session, media = session_generation, media_generation
    local definition = kinds[kind]
    local tracks = tracks_for(kind)
    local selected = current_id(kind)
    local notice = selection_notice(kind,tracks,selected)
    local opened, error = selector.open({kind=kind, tracks=tracks,
        current_id=selected, notice=notice,
        submit=function(id)
            if session ~= session_generation or media ~= media_generation or
                active_kind ~= kind or not selector.is_open() then
                return false, '选择已失效，请重新打开选择器。'
            end
            if kind=='all' then
                local target=track_targets[tonumber(id)]
                if not target then return false,'该轨道已失效，请重新选择。' end
                local target_kind=target.kind
                local target_definition=kinds[target_kind]
                local present=false
                for _,track in ipairs(tracks_for(target_kind)) do
                    if track.id==target.id then present=true;break end
                end
                if not present then refresh_selector();return false,'该轨道已移除，请重新选择。' end
                if target_kind=='primary' and target.id==subtitle_slot_id('secondary-sid') then
                    refresh_selector();return false,'该轨道已用于次字幕，不能同时用于主字幕。'
                end
                local value=selected_track(target_kind)==target.id and 'no' or tostring(target.id)
                local ok=mp.set_property(target_definition.property,value)
                if not ok or selected_track(target_kind)~=(value=='no' and 0 or target.id) then
                    refresh_selector();return false,'未能应用'..target_definition.label..'，请重试。'
                end
                if target_kind=='video' then invalidate_video_restore() end
                return true
            end
            if kind=='subtitle' and tonumber(id) and tonumber(id)>0 and tonumber(id)==subtitle_slot_id('secondary-sid') then
                return false,'该轨道已用于次字幕，不能同时用于主字幕。'
            end
            if definition.other then
                local id=tonumber(id)
                if id and id>0 and id==subtitle_slot_id(definition.other) then
                    refresh_selector()
                    return false,'该轨道已用于'..definition.other_label..'，不能同时用于'..definition.label..'。'
                end
                local target
                if id==0 then target='no'
                else
                    for _,track in ipairs(tracks_for(kind)) do
                        if tonumber(track.id)==id then
                            target=id==subtitle_slot_id(definition.property) and 'no' or tostring(track.id)
                            break
                        end
                    end
                end
                if not target then refresh_selector();return false,'该字幕轨已移除，请重新选择。' end
                local ok=mp.set_property(definition.property,target)
                if not ok or subtitle_slot_id(definition.property)~=(target=='no' and 0 or tonumber(target)) then
                    refresh_selector();return false,'未能应用'..definition.label..'，请重试。'
                end
                return true
            end
            if kind=='edition' then
                local latest=edition_list()
                if not same_editions(edition_snapshot,latest) then
                    edition_snapshot=latest;refresh_selector()
                    return false,'版本列表已变化，请重新选择。'
                end
                local index=tonumber(id)
                if #latest<2 or not index or index~=math.floor(index) or index<1 or not latest[index] then
                    return false,'没有可切换的媒体版本。'
                end
                local ok=mp.set_property('edition',tostring(index-1))
                if not ok then return false,'未能切换媒体版本，请重试。' end
                return true
            end
            if kind == 'device' then
                local target = device_names[tonumber(id)]
                local present = false
                for _, device in ipairs(output_devices()) do
                    if device.device_name == target then present = true; break end
                end
                if not present then
                    refresh_selector()
                    return false, '该音频设备已移除，请重新选择。'
                end
                local ok = mp.set_property('audio-device', target)
                local actual = mp.get_property_native('audio-device')
                if not ok or actual ~= target then
                    refresh_selector()
                    return false, '未能应用音频设备，请重试。'
                end
                return true
            end
            if kind == 'chapter' then
                local latest = chapter_list()
                if not same_chapters(chapter_snapshot, latest) then
                    -- Never accept a replacement index merely because an observer
                    -- refreshed while an old row's mouse/key event was pending.
                    chapter_snapshot = latest
                    refresh_selector()
                    return false, '章节列表已变化，请重新选择。'
                end
                local index = tonumber(id)
                local chapter = index and chapter_snapshot[index]
                if not index or index < 1 or index ~= math.floor(index) or
                    not chapter or not valid_time(chapter.time) then
                    refresh_selector()
                    return false, '该章节已移除，请重新选择。'
                end
                local ok = mp.set_property('chapter', tostring(index - 1))
                if not ok then return false, '未能切换章节，请重试。' end
                return true
            end
            local target
            if tonumber(id) == 0 then target = 'no'
            else
                for _, track in ipairs(tracks_for(kind)) do
                    if tostring(track.id) == tostring(id) then
                        target = tostring(track.id) ==
                            tostring(mp.get_property_native(definition.property)) and 'no' or tostring(track.id)
                        break
                    end
                end
            end
            if not target then
                refresh_selector()
                return false, '该' .. definition.label .. '已移除，请重新选择。'
            end
            local ok = mp.set_property(definition.property, target)
            if not ok then return false, '未能切换' .. definition.label .. '，请重试。' end
            if kind == 'video' then
                -- Explicit selection retires audio-only's earlier restore record.
                -- A shared revision avoids a delayed message clearing a newer save.
                invalidate_video_restore()
            end
            return true
        end,
        close=function()
            if session == session_generation then retire_session() end
        end,
    })
    if not opened then
        close_selector()
        mp.osd_message(error or '无法打开' .. definition.label .. '选择器，请重试。', 3)
    end
end

mp.add_key_binding(nil, 'select-tracks', function() select_tracks('all') end)
mp.add_key_binding(nil, 'select-subtitle', function() select_tracks('subtitle') end)
mp.add_key_binding(nil, 'select-primary', function() select_tracks('primary') end)
mp.add_key_binding(nil, 'select-secondary', function() select_tracks('secondary') end)
mp.add_key_binding(nil, 'select-audio', function() select_tracks('audio') end)
mp.add_key_binding(nil, 'select-video', function() select_tracks('video') end)
mp.add_key_binding(nil, 'select-chapter', function() select_tracks('chapter') end)
mp.add_key_binding(nil, 'select-subtitle-line', select_subtitle_line)
mp.add_key_binding(nil, 'select-device', function() select_tracks('device') end)
mp.add_key_binding(nil, 'select-edition', function() select_tracks('edition') end)
mp.add_key_binding(nil, 'select-history', select_history)
mp.add_key_binding(nil, 'select-watch-later', select_watch_later)
mp.add_key_binding(nil, 'select-binding', select_bindings)
for _, property in ipairs({'current-watch-later-dir', 'working-directory', 'resume-playback'}) do
    mp.observe_property(property, 'native', function(name)
        if refresh_watch_later then refresh_watch_later(name or property) end
    end)
end
mp.observe_property('track-list', 'native', function()
    if active_kind == 'all' or active_kind == 'audio' or active_kind == 'subtitle' or active_kind == 'video' or active_kind=='primary' or active_kind=='secondary' then refresh_selector() end
    if refresh_subtitle_lines then refresh_subtitle_lines() end
end)
mp.observe_property('aid', 'native', function() if active_kind == 'all' or active_kind == 'audio' then refresh_selector() end end)
mp.observe_property('sid', 'native', function()
    if active_kind == 'all' or active_kind == 'subtitle' or active_kind=='primary' or active_kind=='secondary' then refresh_selector() end
    if refresh_subtitle_lines then refresh_subtitle_lines() end
end)
mp.observe_property('current-tracks/sub', 'native', function()
    if refresh_subtitle_lines then refresh_subtitle_lines() end
end)
for _,property in ipairs({'secondary-sid','sub-visibility','secondary-sub-visibility','current-tracks/sub/id','current-tracks/sub2/id'}) do
    mp.observe_property(property,'native',function() if active_kind=='all' or active_kind=='primary' or active_kind=='secondary' then refresh_selector() end end)
end
for _,property in ipairs({'current-tracks/video/id','current-tracks/audio/id'}) do
    mp.observe_property(property,'native',function() if active_kind=='all' then refresh_selector() end end)
end
mp.observe_property('vid', 'native', function() if active_kind == 'all' or active_kind == 'video' then refresh_selector() end end)
-- Refresh presentation/current markers without accepting a new index mapping.
-- A changed chapter list is acknowledged only by the rejected submit above.
for _, property in ipairs({'chapter', 'chapter-list', 'duration'}) do
    mp.observe_property(property, 'native', function() if active_kind == 'chapter' then refresh_selector() end end)
end
for _, property in ipairs({'audio-device', 'audio-device-list'}) do
    mp.observe_property(property, 'native', function() if active_kind == 'device' then refresh_selector() end end)
end
-- The displayed edition mapping stays a snapshot until a rejected submission
-- explicitly refreshes it, just like chapter indices during a pending click.
for _,property in ipairs({'current-edition','edition-list'}) do
    mp.observe_property(property,'native',function() if active_kind=='edition' then refresh_selector() end end)
end
local function reset_for_media()
    media_generation = media_generation + 1
    close_selector()
end
mp.register_event('start-file', reset_for_media)
mp.register_event('end-file', reset_for_media)
mp.register_event('shutdown', reset_for_media)
