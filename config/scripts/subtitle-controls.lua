-- Primary subtitle controls; the Bilibili plugin keeps ownership of its secondary track.
local mp = require("mp")
local input = require("mp.input")
local adjusting = false
local saved_adjustment
local position
-- User-confirmed steps; no settings file is written by these actions.
local delay_step, position_step, scale_step = 0.1, 1, 0.05

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
    mp.osd_message("NO SUBTITLE", 1)
end

local function select_subtitle()
    local tracks, items = ordinary_tracks(), {}
    local sid = mp.get_property_native("sid")
    local selected
    for i, track in ipairs(tracks) do
        local current = tostring(track.id) == tostring(sid)
        items[i] = (current and "●" or "○") .. " " .. (track.title or track.lang or "Subtitle")
            .. " (" .. tostring(track.id) .. (track.codec and " / " .. track.codec or "") .. ")"
        if current then selected = i end
    end
    if #tracks == 0 then return end
    input.select({
        prompt = "Select a subtitle:", items = items, default_item = selected,
        submit = function(index)
            local choice = tracks[index]
            if not choice then return end
            for _, current in ipairs(ordinary_tracks()) do
                if current.id == choice.id then
                    mp.set_property("sid", tostring(current.id) == tostring(mp.get_property_native("sid"))
                        and "no" or tostring(current.id))
                    return
                end
            end
        end,
    })
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
    for _, name in ipairs({"adjust-up", "adjust-down", "adjust-larger", "adjust-smaller"}) do
        mp.remove_key_binding(name)
    end
end

local function show_adjustment()
    mp.osd_message(string.format("SUB ADJUST: POS %.0f%% / SIZE ×%.2f", position,
        mp.get_property_number("sub-scale", 1)), 1)
end

local function adjust_position(amount)
    if not adjusting then return end
    set_position(position + amount)
    show_adjustment()
end

local function adjust_scale(amount)
    if not adjusting then return end
    -- Native ASS danmaku with secondary-sub-ass-override=no does not apply sub-scale.
    mp.set_property_number("sub-scale", math.max(0.05, math.min(100,
        mp.get_property_number("sub-scale", 1) + amount)))
    show_adjustment()
end

local function toggle_adjustment()
    if adjusting then
        exit_mode()
        mp.osd_message("SUB ADJUST: OFF", 1)
        return
    end
    if not primary_track() then no_subtitle(); return end
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
    adjusting = true
    mp.add_forced_key_binding("UP", "adjust-up", function() adjust_position(-position_step) end, {repeatable = true})
    mp.add_forced_key_binding("DOWN", "adjust-down", function() adjust_position(position_step) end, {repeatable = true})
    mp.add_forced_key_binding("WHEEL_UP", "adjust-larger", function() adjust_scale(scale_step) end, {repeatable = true})
    mp.add_forced_key_binding("WHEEL_DOWN", "adjust-smaller", function() adjust_scale(-scale_step) end, {repeatable = true})
    mp.osd_message("SUB ADJUST: ON", 1)
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

local function delay(amount)
    local value = amount and mp.get_property_number("sub-delay", 0) + amount or 0
    if math.abs(value) < 0.00001 then value = 0 end
    mp.set_property_number("sub-delay", value)
    mp.osd_message(string.format("SUB DELAY: %+.1f SEC", value), 1)
end

mp.add_key_binding(nil, "toggle", function()
    local visible = not mp.get_property_bool("sub-visibility", true)
    mp.set_property_bool("sub-visibility", visible)
    mp.osd_message(visible and "SUB ON" or "SUB OFF", 1)
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
mp.add_key_binding(nil, "copy", function()
    local text = primary_track() and mp.get_property("sub-text")
    if not text or not text:match("%S") then no_subtitle(); return end
    -- Use the native API's write result; never read or clear the clipboard first.
    local ok, err = mp.set_property("clipboard/text", text)
    mp.osd_message(ok and "SUB COPIED" or "SUB COPY FAILED", 1)
    if not ok then mp.msg.warn("Subtitle clipboard write failed: " .. tostring(err)) end
end)
mp.register_event("start-file", reset_for_file)
mp.register_event("end-file", reset_for_file)
mp.register_event("shutdown", reset_for_file)
