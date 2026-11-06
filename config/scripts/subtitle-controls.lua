-- Primary subtitle controls; the Bilibili plugin keeps ownership of its secondary track.
local mp = require("mp")
local adjusting = false
local saved_adjustment
local position
local settings_owner
local position_owner
-- User-confirmed steps; no settings file is written by these actions.
local delay_step, position_step, scale_step = 0.1, 1, 0.05

local function show(text, duration)
    if mp.get_property_native('user-data/mpvnet/feedback/ready') == true then
        mp.commandv('script-message-to', 'feedback_osd', 'show', text, tostring(duration))
    else
        mp.osd_message(text, duration)
    end
end

local function status(text)
    mp.set_property_native('user-data/mpvnet/feedback/subtitle', text or '')
    -- An explicit adjustment replaces the preceding short message immediately;
    -- when it expires, the same value remains in the persistent status layer.
    if text then show(text, 1.5) end
end

local function ordinary_tracks()
    local tracks = {}
    for _, track in ipairs(mp.get_property_native("track-list", {})) do
        if track.type == "sub" and track.title ~= "Bilibili Danmaku" then
            tracks[#tracks + 1] = track
        end
    end
    return tracks
end

local function primary_track()
    local sid = mp.get_property_native("sid")
    for _, track in ipairs(ordinary_tracks()) do
        if tostring(track.id) == tostring(sid) then return track end
    end
end

local function no_subtitle()
    show("无可用字幕", 4)
end

local function select_subtitle()
    mp.commandv('script-binding', 'track_selection/select-subtitle')
end

local function cycle_subtitle(direction)
    local tracks = ordinary_tracks()
    if #tracks == 0 then return end
    local current = 0
    for i, track in ipairs(tracks) do
        if tostring(track.id) == tostring(mp.get_property_native("sid")) then current = i; break end
    end
    local next_index = (current + direction) % (#tracks + 1)
    mp.set_property("sid", next_index == 0 and "no" or tostring(tracks[next_index].id))
end

local function set_position(value)
    position = math.max(0, math.min(100, value))
    -- Keep OSC auto-raising suspended until this media's temporary changes are restored.
    mp.commandv("script-message-to", "modernz", "subtitle-adjust-position", position)
    mp.set_property_number("sub-pos", position)
end

local function exit_mode()
    adjusting = false
    status()
    for _, name in ipairs({"adjust-up", "adjust-down", "adjust-larger", "adjust-smaller"}) do
        mp.remove_key_binding(name)
    end
end

local function show_adjustment()
    local text = string.format("字幕位置 %.0f%%\n字号 ×%.2f", position,
        mp.get_property_number("sub-scale", 1))
    if adjusting then status(text) else show(text, 1.5) end
end

local function prepare_adjustment()
    if not primary_track() then no_subtitle(); return false end
    if not saved_adjustment then
        saved_adjustment = {
            pos = mp.get_property_number("user-data/mpvnet/subtitle-base-pos",
                mp.get_property_number("sub-pos", 100)),
            scale = mp.get_property_number("sub-scale", 1),
        }
        set_position(saved_adjustment.pos)
    else
        -- An external adjustment while the mode is off becomes the new working position.
        position = mp.get_property_number("sub-pos", position)
    end
    return true
end

local function adjust_position(amount, single)
    if not adjusting and not single then return end
    if position_owner then position_owner.invalidate() end
    set_position(position + amount)
    show_adjustment()
end

local function adjust_scale(amount, single)
    if not adjusting and not single then return end
    if settings_owner then settings_owner.invalidate() end
    -- Native ASS danmaku with secondary-sub-ass-override=no does not apply sub-scale.
    mp.set_property_number("sub-scale", math.max(0.05, math.min(100,
        mp.get_property_number("sub-scale", 1) + amount)))
    show_adjustment()
end

local function adjust_once(action, amount)
    if prepare_adjustment() then action(amount, true) end
end

local function toggle_adjustment()
    if adjusting then
        exit_mode()
        show("已退出字幕调整", 1.5)
        return
    end
    if not prepare_adjustment() then return end
    adjusting = true
    mp.add_forced_key_binding("UP", "adjust-up", function() adjust_position(-position_step) end, {repeatable = true})
    mp.add_forced_key_binding("DOWN", "adjust-down", function() adjust_position(position_step) end, {repeatable = true})
    mp.add_forced_key_binding("WHEEL_UP", "adjust-larger", function() adjust_scale(scale_step) end, {repeatable = true})
    mp.add_forced_key_binding("WHEEL_DOWN", "adjust-smaller", function() adjust_scale(-scale_step) end, {repeatable = true})
    status("已进入字幕调整")
end

local function reset_for_file()
    exit_mode()
    if saved_adjustment then
        mp.commandv("script-message-to", "modernz", "subtitle-adjust-reset", saved_adjustment.pos)
        mp.set_property_number("sub-pos", saved_adjustment.pos)
        mp.set_property_number("sub-scale", saved_adjustment.scale)
    end
    saved_adjustment, position = nil, nil
end

local function reset_adjustment()
    if settings_owner then settings_owner.invalidate() end
    if position_owner then position_owner.invalidate() end
    local had_adjustment = saved_adjustment ~= nil
    reset_for_file()
    show(had_adjustment and "字幕位置、字号已还原" or "无可还原的字幕调整", had_adjustment and 2 or 4)
end

local function delay(amount)
    local value = amount and mp.get_property_number("sub-delay", 0) + amount or 0
    if math.abs(value) < 0.00001 then value = 0 end
    mp.set_property_number("sub-delay", value)
    show(string.format("字幕延迟 %+.1f 秒", value), 1.5)
end

mp.add_key_binding(nil, "toggle", function()
    local visible = not mp.get_property_bool("sub-visibility", true)
    mp.set_property_bool("sub-visibility", visible)
    show(visible and "字幕已开启" or "字幕已关闭", 1.5)
end)
mp.add_key_binding(nil, "select", select_subtitle)
mp.add_key_binding(nil, "cycle-next", function() cycle_subtitle(1) end)
mp.add_key_binding(nil, "cycle-prev", function() cycle_subtitle(-1) end)
mp.add_key_binding(nil, "seek-prev", function() mp.commandv("no-osd", "sub-seek", -1, "primary") end, {repeatable = true})
mp.add_key_binding(nil, "seek-next", function() mp.commandv("no-osd", "sub-seek", 1, "primary") end, {repeatable = true})
mp.add_key_binding(nil, "delay-down", function() delay(-delay_step) end, {repeatable = true})
mp.add_key_binding(nil, "delay-up", function() delay(delay_step) end, {repeatable = true})
mp.add_key_binding(nil, "delay-reset", function() delay() end)
mp.add_key_binding(nil, "adjust-mode", toggle_adjustment)
mp.add_key_binding(nil, "reset-adjustment", reset_adjustment)
mp.add_key_binding(nil, "position-up", function() adjust_once(adjust_position, -position_step) end)
mp.add_key_binding(nil, "position-down", function() adjust_once(adjust_position, position_step) end)
mp.add_key_binding(nil, "size-up", function() adjust_once(adjust_scale, scale_step) end)
mp.add_key_binding(nil, "size-down", function() adjust_once(adjust_scale, -scale_step) end)
mp.add_key_binding(nil, "copy", function()
    local text = primary_track() and mp.get_property("sub-text")
    if not text or not text:match("%S") then no_subtitle(); return end
    -- Use the native API's write result; never read or clear the clipboard first.
    local ok, err = mp.set_property("clipboard/text", text)
    show(ok and "字幕已复制" or "字幕复制失败", ok and 2 or 4)
    if not ok then mp.msg.warn("Subtitle clipboard write failed: " .. tostring(err)) end
end)
mp.register_event("start-file", reset_for_file)
mp.register_event("end-file", reset_for_file)
mp.register_event("shutdown", reset_for_file)

-- Persistent appearance and temporary per-media adjustment share this feature's
-- ownership. A successful save becomes the new temporary-adjustment baseline,
-- so leaving the media cannot restore the previous saved preference over it.
local settings_model = dofile(mp.command_native({'expand-path', '~~/script-modules/user-settings.lua'}))
settings_owner = settings_model.owner(mp, {
    id='sub-scale', property='sub-scale', default_source='播放器启动配置',
    read=function() return mp.get_property_number('sub-scale',1) end,
    write=function(value) return mp.set_property_number('sub-scale',value) end,
    committed=function(value) if saved_adjustment then saved_adjustment.scale=value end end,
})

settings_model.owner(mp,{
    id='sub-font',property='sub-font',default_source='播放器启动配置',
    read=function() return mp.get_property('sub-font','sans-serif') end,
    write=function(value) return mp.set_property('sub-font',value) end,
})
position_owner=settings_model.owner(mp,{
    id='sub-pos',property='user-data/mpvnet/subtitle-base-pos',default_source='播放器启动配置',
    -- OSC avoidance is temporary geometry, not a manual preference change.
    read=function() return mp.get_property_number('user-data/mpvnet/subtitle-base-pos',mp.get_property_number('sub-pos',100)) end,
    write=function(value,reason)
        local ok=mp.set_property_number('sub-pos',value)
        if not ok then return false end
        mp.set_property_number('user-data/mpvnet/subtitle-base-pos',value)
        if saved_adjustment then position=value end
        mp.commandv('script-message-to','modernz',
            (reason=='preview' or saved_adjustment) and 'subtitle-adjust-position' or 'subtitle-adjust-reset',value)
        return true
    end,
    committed=function(value) if saved_adjustment then saved_adjustment.pos=value end end,
})
