-- One selector session owns audio, primary-subtitle and chapter submissions.
-- mpv normalizes this filename to the script name track_selection.
local mp = require('mp')
local selector
local media_generation, session_generation = 0, 0
local active_kind
local chapter_snapshot
local kinds = {
    audio = {property='aid', type='audio', label='音轨'},
    subtitle = {property='sid', type='sub', label='字幕'},
    chapter = {property='chapter', label='章节'},
}

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

local function current_id(kind)
    local current = mp.get_property_native(kinds[kind].property)
    if kind ~= 'chapter' then return current end
    current = tonumber(current)
    return current and current >= 0 and current < math.huge and current == math.floor(current) and current + 1 or 0
end

local function tracks_for(kind)
    if kind == 'chapter' then return chapter_tracks() end
    local tracks = {}
    local source = mp.get_property_native('track-list', {})
    for _, track in ipairs(type(source) == 'table' and source or {}) do
        if track.type == kinds[kind].type and
            (kind ~= 'subtitle' or track.title ~= 'Bilibili Danmaku') then
            -- Preserve native metadata for the renderer; never rewrite the track.
            tracks[#tracks + 1] = track
        end
    end
    return tracks
end

local function close_selector()
    -- Retire callbacks before close(), which may invoke the old callback inline.
    session_generation = session_generation + 1
    active_kind = nil
    chapter_snapshot = nil
    if selector then selector.close() end
end

local function refresh_selector()
    if active_kind and selector and selector.is_open() then
        selector.update(tracks_for(active_kind), current_id(active_kind))
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
    if kind == 'chapter' then chapter_snapshot = chapter_list() end
    local session, media = session_generation, media_generation
    local definition = kinds[kind]
    local opened, error = selector.open({kind=kind, tracks=tracks_for(kind),
        current_id=current_id(kind),
        submit=function(id)
            if session ~= session_generation or media ~= media_generation or
                active_kind ~= kind or not selector.is_open() then
                return false, '选择已失效，请重新打开选择器。'
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
            return true
        end,
        close=function()
            if session == session_generation then
                session_generation = session_generation + 1
                active_kind = nil
                chapter_snapshot = nil
            end
        end,
    })
    if not opened then
        close_selector()
        mp.osd_message(error or '无法打开' .. definition.label .. '选择器，请重试。', 3)
    end
end

mp.add_key_binding(nil, 'select-subtitle', function() select_tracks('subtitle') end)
mp.add_key_binding(nil, 'select-audio', function() select_tracks('audio') end)
mp.add_key_binding(nil, 'select-chapter', function() select_tracks('chapter') end)
mp.observe_property('track-list', 'native', function() if active_kind ~= 'chapter' then refresh_selector() end end)
mp.observe_property('aid', 'native', function() if active_kind == 'audio' then refresh_selector() end end)
mp.observe_property('sid', 'native', function() if active_kind == 'subtitle' then refresh_selector() end end)
-- Refresh presentation/current markers without accepting a new index mapping.
-- A changed chapter list is acknowledged only by the rejected submit above.
for _, property in ipairs({'chapter', 'chapter-list', 'duration'}) do
    mp.observe_property(property, 'native', function() if active_kind == 'chapter' then refresh_selector() end end)
end
local function reset_for_media()
    media_generation = media_generation + 1
    close_selector()
end
mp.register_event('start-file', reset_for_media)
mp.register_event('end-file', reset_for_media)
mp.register_event('shutdown', reset_for_media)
