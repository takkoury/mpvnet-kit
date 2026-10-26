-- Only mpv host, rendering, and geometry are doubled; logic comes from source.
local entries, current_position = {}, 0
local properties = {speed = 1, ["loop-playlist"] = "no"}
local commands, command_strings, messages, areas, bindings = {}, {}, {}, {}, {}
local mouse_x, mouse_y = 0, 0
local elements, close_popover = {}, nil
local state = {osc_visible = true, mouse_in_window = true, popover_hover_ready = true, chapter_list = {}}
local osc_param = {playresx = 1280, playresy = 720, areas = {input = {{x1 = 0, y1 = 650, x2 = 1280, y2 = 720}}}}
local osc_styles = {tooltip = ""}
local icons = {previous = "previous", next = "next"}
local mp = {
    get_property = function(name, default) return properties[name] or default end,
    get_property_native = function(name) if name == "playlist" then return entries end end,
    get_property_number = function(name, default)
        if name == "playlist-pos" then return current_position end
        return properties[name] or default
    end,
    get_time = function() return 1 end,
    osd_message = function(text) messages[#messages + 1] = text end,
    commandv = function(...)
        local args = {...}; commands[#commands + 1] = args
        if args[2] == "add" and args[3] == "speed" then properties.speed = properties.speed + args[4] end
        if args[2] == "set" and args[3] == "speed" then properties.speed = args[4] end
        return true
    end,
    add_forced_key_binding = function(_, name, callback) bindings[name] = callback end,
    remove_key_binding = function(name) bindings[name] = nil end,
}
local function request_tick() end
local function get_virt_mouse_pos() return mouse_x, mouse_y end
local function set_virt_mouse_area(x1, y1, x2, y2, name) areas[name] = {x1, y1, x2, y2} end
local function window_controls_enabled() return false end
local function show_osc() end
local function show_wc() end
local function hide_osc() end
local function hide_wc() end
local assdraw = {ass_new = function()
    return setmetatable({}, {__index = function() return function() end end})
end}

-- SOURCE FUNCTIONS ARE INSERTED HERE

local function eq(actual, expected, label)
    assert(actual == expected, (label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local function same_area(name, expected)
    assert(areas[name], "missing area: " .. name)
    for i = 1, 4 do eq(areas[name][i], expected[i], name .. " coordinate " .. i) end
end
local function clear_commands() commands, command_strings, messages = {}, {}, {} end
mp.command = function(command)
    command_strings[#command_strings + 1] = command
    if command == "script-binding playlist_controls/previous" then step(-1)
    elseif command == "script-binding playlist_controls/next" then step(1)
    else
        local amount = command:match("^script%-message%-to playback_feedback add%-speed (.+)$")
        if amount then add_speed(amount) end
    end
end
local function layout(element, x, y, width, height, layer)
    element.layout = {geometry = {x = x, y = y, an = 5, w = width, h = height},
        layer = layer or 50, alpha = {0, 255, 255, 255}, style = ""}
end
local function by_name(name)
    for _, element in ipairs(elements) do if element.name == name then return element end end
    error("missing element: " .. name)
end
local function move_to(x, y)
    mouse_x, mouse_y = x, y
    process_event("mouse_move")
end
local function send_mouse(source, phase)
    local name = source:match("^wheel_") and "input_wheel" or source == "shift+mbtn_left" and "input_mid" or "input"
    local area = areas[name]
    -- mpv delivers each mouse binding only inside its section's nonempty area.
    if not area or area[3] <= area[1] or area[4] <= area[2]
        or mouse_x < area[1] or mouse_x > area[3] or mouse_y < area[2] or mouse_y > area[4] then return false end
    process_event(source, phase)
    return true
end
local function popup_fixture()
    elements = {}
    state.active_element, state.popover = nil, nil
    state.osc_visible, state.mouse_in_window, state.popover_hover_ready = true, true, true
    local speed = new_element("speed", "button")
    bind_buttons("speed"); layout(speed, 250, 690, 42, 24, 50)
    local screenshot = new_element("screenshot", "button")
    bind_buttons("screenshot"); layout(screenshot, 450, 690, 24, 24, 51)
    local enhancement = new_element("enhancement", "button")
    layout(enhancement, 650, 690, 24, 24, 52)
    local volume = new_element("vol_ctrl", "button")
    bind_buttons("vol_ctrl"); layout(volume, 850, 690, 24, 24, 53)
    prepare_elements()
    state.local_popovers = {}
    for name, anchor in pairs({speed = speed, copy_clip = screenshot, enhancement = enhancement, volume = volume}) do
        local box = anchor.hitbox
        state.local_popovers[name] = {anchor = anchor,
            body = {x1 = box.x1 - 10, y1 = box.y1 - 192, x2 = box.x2 + 10, y2 = box.y1},
            region = {x1 = box.x1 - 10, y1 = box.y1 - 192, x2 = box.x2 + 10, y2 = box.y2}}
    end
    clear_commands()
    return speed, screenshot, enhancement, volume
end

function queue_boundaries()
    for _, sample in ipairs({{1, 0, 0, 0}, {3, 0, 0, 1}, {3, 1, 0, 2}, {3, 2, 1, 2}, {0, -1}}) do
        local count, position = sample[1], sample[2]
        entries = {}; for i = 1, count do entries[i] = {id = i} end
        current_position, elements = position, {}
        state.active_element, state.popover, state.local_popovers = nil, nil, {}
        build_queue_buttons()
        layout(elements.playlist_prev, 100, 690, 30, 24, 50)
        layout(elements.playlist_next, 160, 690, 30, 24, 51)
        prepare_elements()
        for _, action in ipairs({{"playlist_prev", sample[3], 100}, {"playlist_next", sample[4], 160}}) do
            local element = by_name(action[1])
            eq(element.enabled, count > 0, action[1] .. " count=" .. count .. " position=" .. position)
            clear_commands(); move_to(action[3], 690)
            send_mouse("mbtn_left", "down"); send_mouse("mbtn_left", "up")
            if count == 0 then
                eq(#commands, 0, "empty queue sends no command")
            else
                eq(#command_strings, 1, "one configured button command")
                eq(#commands, 1, "one real playlist step")
                eq(commands[1][1], "no-osd"); eq(commands[1][2], "playlist-play-index")
                eq(commands[1][3], action[2], "queue target")
                eq(element.eventresponder.mbtn_right_up, nil, "right button stays unbound")
                eq(element.eventresponder["shift+mbtn_left_down"], nil, "middle stays unbound")
            end
            eq(properties["loop-playlist"], "no", "button does not enable queue looping")
        end
    end
    -- An upstream force-active option or loop setting must not enable an empty queue.
    entries, elements = {}, {}
    properties["loop-playlist"] = "inf"
    user_opts.buttons_always_active = "playlist_prev,playlist_next"
    build_queue_buttons()
    eq(elements.playlist_prev.enabled, false, "empty previous ignores force-active")
    eq(elements.playlist_next.enabled, false, "empty next ignores loop setting")
end

function speed_anchor_wheel()
    popup_fixture(); properties.speed = 1
    move_to(250, 690)
    eq(state.popover, "speed", "hover opens speed")
    same_area("input_wheel", {229, 678, 271, 702})
    assert(send_mouse("wheel_up", "press"), "speed anchor must receive wheel up")
    eq(properties.speed, 1.25, "configured wheel up reaches real add_speed")
    assert(send_mouse("wheel_down", "press"), "speed anchor must receive wheel down")
    eq(properties.speed, 1, "configured wheel down reaches real add_speed")
    eq(#commands, 2, "exactly two speed commands")
    eq(messages[1], "SPEED: ×1.25"); eq(messages[2], "SPEED: ×1.0")
end

function popup_body_does_not_route_wheel()
    popup_fixture()
    local background_actions = 0
    local background = new_element("background", "button")
    background.eventresponder.wheel_up_press = function() background_actions = background_actions + 1 end
    background.eventresponder.wheel_down_press = background.eventresponder.wheel_up_press
    layout(background, 250, 570, 100, 216, 20)
    prepare_elements()
    move_to(250, 690); move_to(250, 570)
    eq(state.popover, "speed", "moving into popup keeps it open")
    eq(send_mouse("wheel_up", "press"), false, "popup body does not capture wheel up")
    eq(send_mouse("wheel_down", "press"), false, "popup body does not capture wheel down")
    -- Even a direct dispatch must not run a control underneath the popup body.
    process_event("wheel_up", "press"); process_event("wheel_down", "press")
    eq(background_actions, 0, "popup body masks underlying controls")
    eq(#commands, 0, "popup body changes no playback property")
    eq(#command_strings, 0, "popup body sends no action")
end

function close_and_move_away()
    popup_fixture()
    move_to(250, 690)
    assert(bindings["local-speed-popup-escape"], "speed popup installs Escape")
    bindings["local-speed-popup-escape"]()
    refresh_input_area()
    eq(state.popover, nil, "Escape closes popup")
    eq(bindings["local-speed-popup-escape"], nil, "Escape binding removed")
    same_area("input_wheel", {229, 678, 271, 702})
    send_mouse("wheel_up", "press")
    eq(#commands, 1, "closed anchor keeps its normal wheel binding")
    clear_commands()
    move_to(250, 690); move_to(100, 100)
    eq(state.popover, nil, "moving away closes popup")
    same_area("input_wheel", {0, 0, 0, 0})
    eq(send_mouse("wheel_up", "press"), false, "outside wheel does not reach anchor")
    move_to(250, 690)
    mouse_x, mouse_y = 100, 100
    send_mouse("mbtn_left", "down"); send_mouse("mbtn_left", "up")
    eq(state.popover, nil, "outside click closes popup")
    eq(#command_strings, 0, "dismissal does not activate background")
end

function other_popovers_and_middle_button()
    popup_fixture()
    move_to(450, 690)
    eq(state.popover, "copy_clip")
    same_area("input_wheel", {0, 0, 0, 0})
    same_area("input_mid", {438, 678, 462, 702})
    send_mouse("shift+mbtn_left", "down"); send_mouse("shift+mbtn_left", "up")
    eq(#command_strings, 1, "one screenshot middle action")
    eq(command_strings[1], "script-binding capture_controls/open-folder", "real configured middle route")
    clear_commands(); move_to(450, 570)
    eq(send_mouse("shift+mbtn_left", "down"), false, "popup body has no middle binding")
    move_to(650, 690)
    eq(state.popover, "enhancement")
    same_area("input_wheel", {0, 0, 0, 0}); same_area("input_mid", {0, 0, 0, 0})
    move_to(850, 690)
    eq(state.popover, "volume", "volume remains outside click-menu routing branch")
    same_area("input_wheel", {838, 678, 862, 702})
    send_mouse("wheel_up", "press")
    eq(command_strings[1], "no-osd add volume 5", "volume anchor keeps configured wheel route")
end

function hidden_and_active_drag()
    popup_fixture(); move_to(250, 690)
    state.active_element = 1
    state.osc_visible = false
    refresh_input_area()
    for _, name in ipairs({"input", "input_wheel", "input_mid"}) do same_area(name, {0, 0, 0, 0}) end
    state.osc_visible = true
    local held = elements[state.active_element]
    mouse_x, mouse_y = 100, 100
    refresh_input_area()
    local box = held.hitbox
    for _, name in ipairs({"input", "input_wheel", "input_mid"}) do
        same_area(name, {box.x1, box.y1, box.x2, box.y2})
    end
    eq(state.active_element, 1, "refresh does not cancel active drag")
end

function anchor_without_wheel_action()
    local speed = popup_fixture()
    speed.eventresponder.wheel_up_press, speed.eventresponder.wheel_down_press = nil, nil
    move_to(250, 690)
    eq(state.popover, "speed")
    same_area("input_wheel", {0, 0, 0, 0})
    same_area("input_mid", {0, 0, 0, 0})
    eq(send_mouse("wheel_up", "press"), false, "no artificial wheel handler")
    state.local_popovers.speed = nil
    refresh_input_area()
    same_area("input_wheel", {0, 0, 0, 0})
end
