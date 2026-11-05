-- One selector session owns track, chapter and output-device submissions.
-- mpv normalizes this filename to the script name track_selection.
local mp = require('mp')
local selector
local media_generation, session_generation = 0, 0
local active_kind
local chapter_snapshot
local edition_snapshot
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
    edition = {property='edition', label='媒体版本'},
    device = {property='audio-device', label='音频设备'},
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

local function close_selector()
    -- Retire callbacks before close(), which may invoke the old callback inline.
    session_generation = session_generation + 1
    active_kind = nil
    chapter_snapshot = nil
    edition_snapshot = nil
    device_ids, device_names, device_rows, next_device_id = nil, nil, nil, nil
    track_ids, track_targets, next_track_id = nil, nil, nil
    if selector then selector.close() end
end

local function refresh_selector()
    if active_kind and selector and selector.is_open() then
        local tracks = tracks_for(active_kind)
        local selected = current_id(active_kind)
        local notice = selection_notice(active_kind,tracks,selected)
        selector.update(tracks, selected, notice)
    end
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
            if session == session_generation then
                session_generation = session_generation + 1
                active_kind = nil
                chapter_snapshot = nil
                edition_snapshot = nil
                device_ids, device_names, device_rows, next_device_id = nil, nil, nil, nil
                track_ids, track_targets, next_track_id = nil, nil, nil
            end
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
mp.add_key_binding(nil, 'select-device', function() select_tracks('device') end)
mp.add_key_binding(nil, 'select-edition', function() select_tracks('edition') end)
mp.observe_property('track-list', 'native', function()
    if active_kind == 'all' or active_kind == 'audio' or active_kind == 'subtitle' or active_kind == 'video' or active_kind=='primary' or active_kind=='secondary' then refresh_selector() end
end)
mp.observe_property('aid', 'native', function() if active_kind == 'all' or active_kind == 'audio' then refresh_selector() end end)
mp.observe_property('sid', 'native', function() if active_kind == 'all' or active_kind == 'subtitle' or active_kind=='primary' or active_kind=='secondary' then refresh_selector() end end)
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
