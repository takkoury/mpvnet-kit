-- Host, font metrics and source button construction are explicit doubles.
-- Default geometry, menus, preparation, footer and input dispatch are real Lua.
local elements, close_popover, cancel_seekbar_drag = {}, nil, function() end
local state = {}
local osc_param = {playresx = 1280, playresy = 720, areas = {}, video_margins = {}}
local osc_styles = {time = "{\\fs16}", speed = "{\\fs14}", title = "{\\fs24}",
    chapter_title = "{\\fs18}", tooltip = "{\\fs14}", volumebar_fg = "", element_hover = "", control_1 = "",
    control_2 = "", control_3 = "", cache = "", osc_fade_bg = "", seekbar_bg = "", seekbar_fg = ""}
local icons, seekbar_height_style = {menu = "more"}, {height = 4, radius = 2}
local commands, command_strings, bindings, areas, observers = {}, {}, {}, {}, {}
local properties, mouse_x, mouse_y, init_count = {}, -10, -10, 0
local thumbfast = {available = false}
local UNICODE_MINUS = "−"
local function request_tick() end
local function request_init() init_count = init_count + 1 end
local function get_virt_mouse_pos() return mouse_x, mouse_y end
local function set_virt_mouse_area(x1, y1, x2, y2, name) areas[name] = {x1, y1, x2, y2} end
local function window_controls_enabled() return false end
local function show_osc() end
local function show_wc() end
local function hide_osc() end
local function hide_wc() end
local function estimate_text_width(text, style)
    local fs = tonumber((style or ""):match("\\fs(%d+)")) or 14
    return #text * fs * 0.45
end
local function osc_color_convert(color) return color:sub(6, 7) .. color:sub(4, 5) .. color:sub(2, 3) end
local function observe_cached(name, callback) observers[name] = callback end
local mp = {
    get_time = function() return 1 end,
    get_property_number = function(name, default) return properties[name] or default end,
    set_property_bool = function(name, value) properties[name] = value end,
    command = function(value) command_strings[#command_strings + 1] = value end,
    commandv = function(...) commands[#commands + 1] = {...} end,
    add_forced_key_binding = function(_, name, callback) bindings[name] = callback end,
    remove_key_binding = function(name) bindings[name] = nil end,
}
local assdraw = {ass_new = function()
    return setmetatable({ops = {}}, {__index = function(_, name)
        return function(self, ...) self.ops[#self.ops + 1] = {name = name, args = {...}} end
    end})
end}

-- SOURCE FUNCTIONS ARE INSERTED HERE

local function eq(a, b, label)
    assert(a == b, (label or "value") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
end
local function near(a, b, label) assert(math.abs(a - b) < 0.001, label or "near") end
local function has(text, part) assert(text:find(part, 1, true), "missing " .. part .. ": " .. text) end
local function empty_commands() commands, command_strings = {}, {} end
local function by_name(name)
    for _, e in ipairs(elements) do if e.name == name then return e end end
    error("missing element: " .. name)
end
local function fixture(width, height, options)
    options = options or {}
    elements, commands, command_strings, bindings, areas, properties = {}, {}, {}, {}, {}, {}
    state = {osc_visible = true, mouse_in_window = true, popover_hover_ready = true,
        duration = options.duration or 360, playlist_count = 3, chapter_list = {}, chapter = -1,
        sub_track_count = options.no_tracks and 0 or 1, audio_track_count = options.no_tracks and 0 or 1,
        capture = {}, speed = 1, volume = 60, mouse_down_counter = 0,
        tick_timer = {kill = function() end, resume = function() end},
        enhancement = {available = {OFF = true, QUALITY = true, SMOOTH = true}, applied = "OFF",
            unavailable_reasons = {ANIME_LIGHT = "hdr_source", ANIME_STRONG = "hdr_source"}}}
    osc_param = {playresx = width, playresy = height, areas = {}, video_margins = {}}
    mouse_x, mouse_y, init_count = -10, -10, 0
    for _, name in ipairs({"info", "sub_track", "vol_ctrl", "enhancement", "speed", "screenshot", "ontop", "playlist", "download", "cache_info",
        "playlist_prev", "playlist_next", "chapter_prev", "chapter_next", "jump_backward", "jump_forward", "play_pause", "title", "chapter_title", "time_codes"}) do
        local e = new_element(name, "button")
        e.content = name
        bind_buttons(name)
    end
    elements.speed.content = function() return "× " .. string.format("%g", state.speed) end
    elements.time_codes.content = function() return options.time_text or "0:00 / 6:00" end
    elements.vol_ctrl.enabled, elements.sub_track.enabled = not options.no_tracks, not options.no_tracks
    elements.vol_ctrl.nothingavailable, elements.sub_track.nothingavailable = "无音轨", "无字幕"
    for _, pair in ipairs({{"jump_backward", -10}, {"jump_forward", 10}}) do
        local amount = pair[2]
        elements[pair[1]].eventresponder = {mbtn_left_down = function()
            mp.commandv("script-message-to", "playback_feedback", "seek", amount, "relative+exact")
        end}
    end
    build_volume_source()
    new_element("seekbar", "slider")
    new_element("persistent_seekbar", "slider")
    layouts.default()
    setup_local_popovers()
    prepare_elements()
    return state.responsive
end
local function move(element)
    local box = element.hitbox
    mouse_x, mouse_y = (box.x1 + box.x2) / 2, (box.y1 + box.y2) / 2
    process_event("mouse_move")
end
local function click(element, source)
    move(element)
    local area = areas[source == "shift+mbtn_left" and "input_mid" or "input"]
    assert(area and mouse_x >= area[1] and mouse_x <= area[3] and mouse_y >= area[2] and mouse_y <= area[4]
        and area[3] > area[1] and area[4] > area[2], "real mpv section must accept the click")
    process_event(source or "mbtn_left", "down")
    process_event(source or "mbtn_left", "up")
end

local function open(page)
    state.responsive.open(page or "root")
    return state.local_popovers.more
end
local function entry_row(label)
    local popup = state.local_popovers.more
    for index, entry in ipairs(popup.entries) do
        if entry.label == label or entry.name == label or entry.preset == label then
            responsive_osc.scroll(index - 1 - state.more_scroll)
            for _, row in ipairs(popup.rows) do
                if row.more_entry and row.more_entry.label == entry.label then return row end
            end
        end
    end
    error("missing entry: " .. label)
end
local function boxes_overlap(a, b)
    return a.x1 < b.x2 and b.x1 < a.x2 and a.y1 < b.y2 and b.y1 < a.y2
end
local function check_geometry(r)
    local found = {}
    for _, name in ipairs(r.direct) do
        local e = r.sources[name]
        assert(e.layout and e.visible, "direct control has layout: " .. name)
        local b = e.hitbox
        assert(b.x1 >= 0 and b.x2 <= osc_param.playresx and b.y1 >= 0 and b.y2 <= osc_param.playresy, "direct bounds: " .. name)
        found[name] = true
    end
    for i, name in ipairs(r.direct) do for j = i + 1, #r.direct do
        assert(not boxes_overlap(r.sources[name].hitbox, r.sources[r.direct[j]].hitbox), "overlap: " .. name .. "/" .. r.direct[j])
    end end
    for _, item in ipairs(r.overflow) do
        assert(not found[item.name], "duplicate reachability: " .. item.name)
        assert(item.reason == "width" or item.reason == "height", "explicit overflow reason")
        found[item.name] = true
    end
    for _, name in ipairs({"info", "sub_track", "vol_ctrl", "enhancement", "speed", "screenshot", "ontop", "playlist",
        "playlist_prev", "playlist_next", "jump_backward", "jump_forward", "play_pause"}) do
        assert(found[name], "unreachable control: " .. name)
    end
    local zone = osc_param.areas.input[1]
    near(zone.y1, osc_param.playresy - r.bar_height, "input follows bar height")
    near(osc_param.video_margins.b, r.bar_height / osc_param.playresy, "subtitle margin follows bar height")
    near(by_name("osc_fade_bg").layout.geometry.h, r.bar_height, "background follows bar height")
end

function geometry_matrix()
    for _, size in ipairs({{1280,720}, {405,720}, {260,720}, {180,320}, {640,160}, {320,200}, {120,110}}) do
        check_geometry(fixture(size[1], size[2]))
    end
    eq(fixture(1280,720).mode, "single")
    eq(fixture(405,720).mode, "two")
    eq(fixture(640,160).mode, "compact")
end

function actual_width()
    local r = fixture(900,720)
    eq(r.mode, "single")
    r = fixture(900,720,{time_text = string.rep("8", 60)})
    eq(r.mode, "two", "actual measured text changes layout")
    check_geometry(r)
end

function priority()
    local r = fixture(320,720)
    for _, name in ipairs({"vol_ctrl", "sub_track", "screenshot", "playlist"}) do assert(r.sources[name].visible, "priority: " .. name) end
    r = fixture(260,720)
    assert(not r.sources.playlist_prev.visible and not r.sources.playlist_next.visible, "previous and next fold first")
    assert(r.sources.jump_backward.visible and r.sources.jump_forward.visible, "jumps still fit")
    r = fixture(180,320)
    assert(not r.sources.jump_backward.visible and not r.sources.jump_forward.visible, "jumps fold next")
    assert(r.sources.play_pause.visible and r.sources.more.visible, "play and more remain")
end

function click_lifecycle()
    local r = fixture(260,720)
    move(r.sources.more); eq(state.popover, nil, "more is click-only")
    click(r.sources.more); eq(state.popover, "more")
    local popup = state.local_popovers.more
    eq(#popup.entries, #r.overflow, "root only contains folded controls")
    mouse_x, mouse_y = 20, 20; process_event("mouse_move"); eq(state.popover, "more", "moving outside does not close")
    process_event("mbtn_left", "down"); process_event("mbtn_left", "up")
    eq(state.popover, nil); eq(#commands + #command_strings, 0, "outside click consumed")
    click(r.sources.more); click(r.sources.more); eq(state.popover, nil, "anchor toggles")
    open(); empty_commands(); click(r.sources.screenshot)
    eq(state.popover, nil, "clicking another tool outside More dismisses")
    eq(#commands + #command_strings, 0, "direct tool outside popup is consumed")
    open(); assert(bindings["local-speed-popup-escape"])
    bindings["local-speed-popup-escape"](); eq(state.popover, nil)
    eq(bindings["local-speed-popup-escape"], nil, "local Escape removed")
end

function scroll_and_back()
    fixture(320,200)
    local popup = open()
    local back_y = popup.header.hitbox.y1
    for _, row in ipairs(popup.rows) do near(row.layout.geometry.h, 32, "fixed row height") end
    move(popup.rows[1]); process_event("wheel_down", "press")
    eq(state.more_scroll, 1, "one wheel event scrolls once")
    near(popup.header.hitbox.y1, back_y, "fixed header during scroll")
    click(entry_row("screenshot")); eq(state.more_page, "screenshot")
    move(popup.rows[1]); process_event("wheel_down", "press")
    click(popup.header); eq(state.more_page, "root"); eq(state.more_scroll, 0)
    assert(popup.body.x1 >= 0 and popup.body.y1 >= 0 and popup.body.x2 <= 320 and popup.body.y2 <= 200)
    eq(areas.input_wheel[1], popup.body.x1, "scroll capture follows popup")
end

function showhide_regions()
    fixture(320,200)
    local original = osc_param.areas.showhide
    -- showhide_wc is enabled after showhide, so it owns mouse_move wherever
    -- their rectangles overlap. An ownership change emits section mouse_leave.
    local top = {{x1 = 0, y1 = 0, x2 = 320, y2 = 90}}
    osc_param.areas.showhide_wc = top
    set_virt_mouse_area(0, 100, 320, 200, "showhide")
    set_virt_mouse_area(0, 0, 320, 90, "showhide_wc")
    local function owner(x, y)
        for _, name in ipairs({"showhide_wc", "showhide"}) do
            local b = areas[name]
            if b and b[3] > b[1] and b[4] > b[2] and x >= b[1] and x <= b[3] and y >= b[2] and y <= b[4] then return name end
        end
    end
    local anchor = state.responsive.sources.more.layout.geometry
    local before = owner(anchor.x, anchor.y)
    eq(before, "showhide", "bottom anchor starts in original showhide section")
    local popup = open()
    local region = areas.showhide
    eq(region[1], 0); eq(region[2], 0); eq(region[3], 320); eq(region[4], 200)
    eq(areas.showhide_wc[3], 0); eq(areas.showhide_wc[4], 0)
    eq(owner(anchor.x, anchor.y), before, "opening More must not transfer mouse ownership")
    local row = popup.rows[1].hitbox
    eq(owner((row.x1 + row.x2) / 2, (row.y1 + row.y2) / 2), before, "upper menu keeps the same section owner")
    move(popup.rows[1]); process_event("wheel_down", "press")
    eq(state.popover, "more"); eq(state.more_scroll, 1)
    bindings["local-speed-popup-escape"]()
    eq(osc_param.areas.showhide, original, "restore original activation region")
    eq(osc_param.areas.showhide_wc, top, "restore original top activation region")
    eq(areas.showhide[2], 100); eq(areas.showhide_wc[4], 90)
end

function capture_actions()
    fixture(320,200); open("screenshot")
    local popup = state.local_popovers.more
    eq(#popup.entries, 7, "PNG, A/B, three formats, directory and latest clip")
    click(entry_row("GIF")); eq(commands[1][3], "set-default-format"); eq(commands[1][4], "gif")
    open("screenshot"); click(entry_row("Set clip A")); eq(command_strings[1], "script-binding capture_controls/clip-point")
    state.capture.a = 10; open("screenshot"); click(entry_row("Set B / export clip"))
    eq(command_strings[2], "script-binding capture_controls/clip-point")
    open("screenshot"); click(entry_row("Screenshot PNG")); eq(command_strings[3], "script-binding capture_controls/screenshot")
    open("screenshot"); click(entry_row("Capture folder")); eq(command_strings[4], "script-binding capture_controls/open-folder")
    open(); click(entry_row("screenshot"), "shift+mbtn_left"); eq(command_strings[5], "script-binding capture_controls/open-folder")
    click(entry_row("screenshot"), "mbtn_right"); eq(command_strings[6], "script-binding capture_controls/clip-point")
    open("screenshot"); click(entry_row("Copy latest clip")); eq(commands[2][2], "capture_controls/copy-latest")
end

function other_actions()
    fixture(320,200); open("vol_ctrl")
    click(entry_row("Mute / unmute")); eq(command_strings[1], "no-osd cycle mute")
    click(entry_row("Volume 100%")); eq(command_strings[2], "no-osd set volume 100")
    click(entry_row("Volume +5")); eq(command_strings[3], "no-osd add volume 5")
    click(entry_row("Volume −5")); eq(command_strings[4], "no-osd add volume -5")
    click(entry_row("Audio tracks")); eq(command_strings[5], "script-binding select/select-aid")
    open("sub_track"); click(entry_row("Toggle subtitles")); eq(command_strings[6], "script-binding subtitle_controls/toggle")
    click(entry_row("Select subtitles")); eq(command_strings[7], "script-binding subtitle_controls/select")
    open("sub_track"); click(entry_row("Adjust subtitles")); eq(command_strings[8], "script-binding subtitle_controls/adjust-mode")
    open("speed"); click(entry_row("× 1.25")); eq(commands[1][4], 1.25)
    click(entry_row("Speed +0.25")); eq(command_strings[9], "script-message-to playback_feedback add-speed 0.25")
    empty_commands(); click(state.local_popovers.more.rows[1], "mbtn_right")
    eq(#commands, 1, "speed page right reset exactly once"); eq(commands[1][4], 1); eq(commands[1][5], "quiet")
end

function simple_action()
    fixture(320,200); open(); click(entry_row("info"))
    eq(#command_strings, 1); eq(command_strings[1], "script-binding playback_feedback/media-info"); eq(state.popover, nil)
    fixture(180,320); open(); click(entry_row("jump_backward"))
    eq(#commands, 1); eq(commands[1][4], -10, "folded down-only transport action works")
end

function no_tracks()
    local r = fixture(1280,720,{no_tracks = true})
    assert(r.sources.vol_ctrl.visible and not r.sources.vol_ctrl.enabled)
    assert(r.sources.sub_track.visible and not r.sources.sub_track.enabled)
    fixture(320,200,{no_tracks = true}); open()
    local row = entry_row("sub_track"); assert(not row.enabled); eq(row.tooltipF(), nil)
    click(row); eq(state.more_page, "root"); eq(#commands + #command_strings, 0)
    row = entry_row("vol_ctrl"); click(row); eq(state.more_page, "root")
end

function more_tooltips()
    fixture(320, 200)
    state.responsive.sources.vol_ctrl.tooltipF = function(omit_wheel)
        eq(omit_wheel, true, "root wheel scrolls instead of invoking volume")
        return "中键选择音轨 · 右键100%"
    end
    open(); eq(entry_row("vol_ctrl").tooltipF(), "中键选择音轨 · 右键100%")
    eq(entry_row("info").tooltipF(), nil, "simple root entry already has its name")
    open("vol_ctrl"); eq(entry_row("Volume 100%").tooltipF(), nil)
    eq(entry_row("Audio tracks").tooltipF(), nil)
    open("sub_track"); eq(entry_row("Select subtitles").tooltipF(), nil)
    eq(entry_row("Adjust subtitles").tooltipF(), nil)
    open("screenshot"); eq(entry_row("Screenshot PNG").tooltipF(), nil)
    state.capture.a = 2; open("screenshot")
    eq(entry_row("Set B / export clip").tooltipF(), nil)
    open()
    state.responsive.sources.vol_ctrl.tooltipF = function() return nil end
    eq(entry_row("vol_ctrl").tooltipF(), nil, "nil result must not fall back to the function object")
    state.responsive.sources.vol_ctrl.enabled = false
    state.responsive.sources.vol_ctrl.tooltipF = function() error("disabled source hint must not run") end
    eq(entry_row("vol_ctrl").tooltipF(), nil, "entry and source enabled state must both agree")
end

function enhancement_page()
    fixture(260,720); local popup = open("enhancement")
    local row = entry_row("ANIME_LIGHT"); move(row)
    assert(popup.footer, "same panel footer explains disabled preset")
    eq(row.tooltipF(), nil, "no enhancement tooltip bubble")
    assert(not row.content():find("SDR only", 1, true), "reason is outside fixed option row")
    eq(popup.footer.lines[1], "SDR only")
    local y = row.hitbox.y1
    click(row); eq(#commands, 0, "disabled preset inert")
    move(entry_row("QUALITY")); eq(popup.footer, nil); near(row.hitbox.y1, y, "footer preserves row geometry")
    click(entry_row("QUALITY")); eq(commands[1][4], "QUALITY")
    state.enhancement.applied = "QUALITY"; update_popover()
    has(entry_row("QUALITY").content(), "BB8712")
    local ass = assdraw.ass_new(); move(entry_row("ANIME_STRONG")); render_enhancement_footer(ass)
    assert(#ass.ops > 0, "existing renderer emits overflow footer")
    local anchor = state.responsive.sources.more
    mouse_x, mouse_y = anchor.layout.geometry.x, anchor.layout.geometry.y
    process_event("mbtn_left", "down"); process_event("mbtn_left", "up")
    eq(state.popover, nil, "More toggle stays reachable under enhancement footer")
end

function resize_lifecycle()
    fixture(320,200); open("screenshot"); request_init_resize()
    eq(state.popover, nil); eq(state.more_page, nil); eq(state.more_scroll, 0); eq(init_count, 1)
    local r = fixture(640,160); check_geometry(r)
    local popup = open(); move(popup.rows[1]); refresh_input_area()
    eq(areas.input_wheel[2], popup.body.y1, "resized wheel area")
end

function long_time()
    local r = fixture(405,720,{duration = 360000, time_text = "100:00:00.000 / 100:00:00.000"})
    check_geometry(r)
    assert(r.title_width < 405 / 2, "title yields to measured time")
    local time = r.sources.time_codes.hitbox
    assert(time.x1 >= 25 and time.x2 <= 380)
    if r.sources.title.visible then assert(not boxes_overlap(time, r.sources.title.hitbox)) end
    check_geometry(fixture(120,110,{duration = 360000, time_text = string.rep("8", 50)}))
end

function speed_width_growth()
    fixture(1280,720); state.speed = 123456; observers.speed()
    eq(init_count, 1, "wide speed label forces actual width recomputation")
    fixture(320,200); state.speed = 123456; observers.speed()
    eq(init_count, 0, "hidden speed does not disrupt the open page")
end

function volume_popup_drag()
    fixture(1280,720)
    move(state.responsive.sources.vol_ctrl)
    local slider
    for _, element in ipairs(elements) do
        if element.name == "popover_volume" then slider = element end
    end
    assert(slider and state.popover == "volume")
    local g = slider.layout.geometry
    eq(g.w, 60); eq(g.h, 186)
    local previous_type = user_opts.volume_control_type
    user_opts.volume_control_type = "linear"
    for _, maximum in ipairs({100,130}) do
        slider.volume_max = maximum
        empty_commands()
        -- The widened hit area accepts input well away from the thin rail.
        mouse_x, mouse_y = g.x + 8, g.y + 36
        process_event("mouse_move"); process_event("mbtn_left", "down")
        eq(commands[#commands][4], maximum, "rail top reaches configured maximum")
        mouse_x, mouse_y = g.x + g.w - 8, g.y + 103
        process_event("mouse_move")
        eq(commands[#commands][4], maximum / 2, "rail midpoint maps to half volume")
        mouse_y = g.y + g.h - 16
        process_event("mouse_move")
        eq(commands[#commands][4], 0, "rail bottom reaches zero")
        mouse_y = g.y + g.h - 9
        process_event("mouse_move"); process_event("mbtn_left", "up")
        eq(commands[#commands][4], 0, "bottom padding clamps to zero")
    end
    empty_commands()
    mouse_x, mouse_y = g.x + g.w / 2, g.y + 16
    process_event("mouse_move"); process_event("mbtn_left", "down"); process_event("mbtn_left", "up")
    eq(#commands, 0, "clicking the value label does not adjust volume")
    user_opts.volume_control_type = previous_type
end

function volume_slider()
    fixture(320,200)
    local popup = open("vol_ctrl")
    local slider = popup.volume
    assert(slider.more_entry and slider.more_entry.kind == "volume", "arbitrary slider is the first volume row")
    local function target(percent)
        mouse_x = slider.slider.min.glob_pos + (slider.slider.max.glob_pos - slider.slider.min.glob_pos) * percent / 100
        mouse_y = slider.layout.geometry.y
    end
    target(37); process_event("mouse_move"); process_event("mbtn_left", "down")
    target(63); process_event("mouse_move"); process_event("mbtn_left", "up")
    assert(#commands >= 2, "real source volume callbacks handle click and drag")
    eq(commands[1][3], "volume"); assert(math.abs(commands[1][4] - 37) <= 1, "arbitrary 37 percent")
    assert(math.abs(commands[#commands][4] - 63) <= 1, "drag reaches arbitrary 63 percent")
    empty_commands(); local scroll = state.more_scroll
    target(50); process_event("mouse_move"); process_event("wheel_up", "press")
    eq(command_strings[1], "no-osd add volume 5"); eq(state.more_scroll, scroll, "slider wheel changes volume without scrolling")
    click(popup.header); eq(state.more_page, "root")
    click(entry_row("vol_ctrl")); eq(state.more_page, "vol_ctrl")
    assert(popup.volume.eventresponder.mbtn_left_down, "return and reentry preserve slider callbacks")
end
