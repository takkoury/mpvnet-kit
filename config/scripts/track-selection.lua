-- One selector session owns both audio and primary-subtitle panel submissions.
-- mpv normalizes this filename to the script name track_selection.
local mp = require('mp')
local selector
local media_generation, session_generation = 0, 0
local active_kind
local kinds = {
    audio = {property='aid', type='audio', label='音轨'},
    subtitle = {property='sid', type='sub', label='字幕'},
}

local function tracks_for(kind)
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
    if selector then selector.close() end
end

local function refresh_selector()
    if active_kind and selector and selector.is_open() then
        selector.update(tracks_for(active_kind),
            mp.get_property_native(kinds[active_kind].property))
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
    local session, media = session_generation, media_generation
    local definition = kinds[kind]
    local opened, error = selector.open({kind=kind, tracks=tracks_for(kind),
        current_id=mp.get_property_native(definition.property),
        submit=function(id)
            if session ~= session_generation or media ~= media_generation or
                active_kind ~= kind or not selector.is_open() then
                return false, '选择已失效，请重新打开选择器。'
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
mp.observe_property('track-list', 'native', refresh_selector)
mp.observe_property('aid', 'native', function() if active_kind == 'audio' then refresh_selector() end end)
mp.observe_property('sid', 'native', function() if active_kind == 'subtitle' then refresh_selector() end end)
local function reset_for_media()
    media_generation = media_generation + 1
    close_selector()
end
mp.register_event('start-file', reset_for_media)
mp.register_event('end-file', reset_for_media)
mp.register_event('shutdown', reset_for_media)
