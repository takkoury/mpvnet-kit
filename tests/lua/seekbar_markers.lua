-- mpv, font measurement and ASS emission are host doubles; all marker/preview
-- functions and the complete render_elements path are taken from ModernZ.
local state = {duration = 100, capture = {}, osc_visible = true, mouse_in_window = true,
    mouse_down_counter = 0, chapter_list = {}, local_popovers = {}, tick_last_time = 0}
local osc_param = {playresx = 1020, playresy = 720}
local osc_styles = {tooltip = "{\\fs14\\1c&HFFFFFF&}", tooltip_box = "", thumbnail = ""}
local elements, properties, observers, commands = {}, {}, {}, {}
local hover_effects, thumbfast = {}, {disabled = true, available = false}
local mouse_x, mouse_y, timers, footer_calls = -100, -100, 0, 0
local function eq(actual, expected, label)
    assert(actual == expected, (label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local function near(actual, expected, label)
    assert(math.abs(actual - expected) < 0.00001, (label or "value") .. ": expected " .. expected .. ", got " .. actual)
end
local function copy(value)
    local result = {}; for k, v in pairs(value) do result[k] = v end; return result
end
local mp = {
    get_property_number = function(name, default)
        if name == "osd-width" then return osc_param.playresx end
        return properties[name] or default
    end,
    commandv = function(...) commands[#commands + 1] = {...} end,
    observe_property = function(name, kind, callback) observers[name] = {kind = kind, callback = callback} end,
    get_time = function() return 1 end,
    add_timeout = function(_, callback)
        timers = timers + 1
        return {is_enabled = function(self) return self.enabled end,
            resume = function(self) self.enabled = true end, callback = callback}
    end,
}
local function get_virt_mouse_pos() return mouse_x, mouse_y end
local function get_virt_scale_factor() return 1, 1 end
local function estimate_text_width(text) return text and #text * 7 or 0 end
local function chapter_preview_text(text) return text, #text * 7 end
local function render_enhancement_footer() footer_calls = footer_calls + 1 end
local function osc_color_convert(color) return color:sub(6, 7) .. color:sub(4, 5) .. color:sub(2, 3) end

-- Record emitted geometry/styles without replacing any product drawing logic.
local function new_ass()
    local result = {ops = {}}
    function result:append(text) self.ops[#self.ops + 1] = {kind = "append", text = text} end
    function result:new_event() self.ops[#self.ops + 1] = {kind = "event"} end
    function result:merge(other) for _, op in ipairs(other.ops) do self.ops[#self.ops + 1] = op end end
    for _, name in ipairs({"pos", "an", "draw_start", "draw_stop", "rect_cw", "rect_ccw", "round_rect_cw", "move_to", "line_to"}) do
        result[name] = function(self, ...)
            self.ops[#self.ops + 1] = {kind = name, args = {...}}
        end
    end
    return result
end
local assdraw = {ass_new = new_ass}

-- SOURCE FUNCTIONS ARE INSERTED HERE

local blue, amber = "BB8712", "50B4E6"
local function inspect(ass)
    local result, events, event = {}, {}, {}
    for _, op in ipairs(ass.ops) do
        if op.kind == "event" then
            events[#events + 1] = event; event = {}
        else event[#event + 1] = op end
    end
    events[#events + 1] = event
    for event_id, ops in ipairs(events) do
        -- Position/alignment are event-wide: a later pos must affect earlier
        -- geometry too. The old call-by-call recorder missed this class of bug.
        local final_x, final_y, final_align
        for _, op in ipairs(ops) do
            if op.kind == "pos" then final_x, final_y = op.args[1], op.args[2] end
            if op.kind == "an" then final_align = op.args[1] end
        end
        local style, drawing, geometry_seen, split = {}, false, false, false
        for _, op in ipairs(ops) do
            if op.kind == "draw_start" then drawing, geometry_seen, split = true, false, false end
            if op.kind == "draw_stop" then drawing, geometry_seen = false, false end
            if op.kind == "append" then
                if drawing and geometry_seen then split = true end
                if op.text:find("\\rDefault", 1, true) then style = {} end
                local color = op.text:match("\\1c&H(%x+)&")
                local alpha = op.text:match("\\1a&H(%x+)&")
                local fs = op.text:match("\\fs([%d.]+)")
                if color then style.color = color:upper() end
                if alpha then style.alpha = tonumber(alpha, 16) end
                if fs then style.fs = tonumber(fs) end
            end
            if (op.kind == "append" and op.text:sub(1, 1) ~= "{") or op.args then
                local item = copy(style)
                item.x, item.y, item.align, item.event = final_x, final_y, final_align, event_id
                item.split_drawing = split
                item.kind, item.args = op.kind, op.args
                if op.kind == "append" then item.kind, item.text = "text", op.text end
                result[#result + 1] = item
                if drawing and op.kind ~= "pos" and op.kind ~= "an" then geometry_seen = true end
            end
        end
    end
    return result
end
local function matching(ass, kind, color)
    local result = {}
    for _, item in ipairs(inspect(ass)) do
        if item.kind == kind and (not color or item.color == color) then result[#result + 1] = item end
    end
    return result
end
local function fixture(width)
    state.duration, state.capture, state.animation = 100, {}, nil
    state.chapter_list, state.active_element, state.tick_timer = {}, nil, nil
    state.mouse_down_counter, state.tick_last_time = 0, 0
    user_opts.layout, user_opts.ab_loop_color, user_opts.clip_marker_color = "default", "#1287bb", "#E6B450"
    properties, commands, mouse_x, mouse_y = {}, {}, -100, -100
    local w = width or 1000
    local element = {name = "seekbar", type = "slider", enabled = true, state = {}, eventresponder = {},
        style_ass = new_ass(), static_ass = new_ass(), hitbox = {x1 = 10, y1 = 600, x2 = 10 + w, y2 = 618},
        layout = {geometry = {x = 10 + w / 2, y = 609, an = 5, w = w, h = 18}, alpha = {0, 255, 255, 255},
            slider = {gap = 7, radius = 0, tooltip_an = 2, tooltip_style = osc_styles.tooltip,
                adjust_tooltip = true, alpha = {0, 255, 255, 255}, handle_color = "#1287bb"}},
        slider = {min = {value = 0, ele_pos = 4.5, glob_pos = 14.5},
            max = {value = 100, ele_pos = w - 4.5, glob_pos = w + 5.5},
            posF = function() return 50 end, seekRangesF = function() return nil end,
            tooltipF = function(percent) return format_time(percent) end}}
    element.style_ass:new_event(); element.style_ass:pos(10 + w / 2, 609); element.style_ass:an(5)
    element.style_ass:append("{\\fs14\\1c&HBB8712&}")
    element.static_ass:draw_start()
    state.seekbar_element, elements = element, {element}
    return element
end
local function frame(element)
    elements = {element}
    local ass = new_ass(); render_elements(ass, true, false); return ass
end
local function hover(element, time, y)
    mouse_x = element.hitbox.x1 + seekbar_markers.project(element, time).x
    mouse_y = element.hitbox.y1 + y
end
local function text_contains(ass, text)
    for _, item in ipairs(matching(ass, "text")) do
        if item.text:find(text, 1, true) then return item end
    end
end

function unpaired_endpoints()
    local element = fixture()
    properties["ab-loop-a"], state.capture = 25, {a = 25}
    local ass = frame(element)
    eq(#matching(ass, "move_to", blue), 1, "one upper loop triangle")
    eq(#matching(ass, "rect_cw", amber), 1, "one lower capture square")
    eq(#matching(ass, "rect_cw", blue), 0, "A alone has no loop range")
    for _, invalid in ipairs({0, 20, -10, math.huge, 0/0}) do
        properties["ab-loop-b"] = invalid
        eq(#matching(frame(element), "rect_cw", blue), 0, "invalid B has no fill")
    end
end

function overlapping_ranges()
    local element = fixture()
    properties["ab-loop-a"], properties["ab-loop-b"] = 20, 80
    state.capture = {media_generation = 3, pending_clip = {start = 20, finish = 80, media_generation = 3}}
    local ass = frame(element)
    local loop = matching(ass, "rect_cw", blue)[1]
    local capture = matching(ass, "rect_cw", amber)[1]
    eq(loop.alpha, 140); eq(capture.alpha, 140)
    eq(loop.args[2], 7); eq(loop.args[4], 9)
    eq(capture.args[2], 9); eq(capture.args[4], 11)
    eq(loop.args[1], capture.args[1]); eq(loop.args[3], capture.args[3])
    eq(#matching(ass, "move_to", blue), 2, "two loop endpoint triangles")
    eq(#matching(ass, "rect_cw", amber), 3, "capture band and two endpoint squares")
end

function shared_projection()
    for _, width in ipairs({1, 8, 100, 1000}) do
        local element = fixture(width)
        properties["ab-loop-a"], properties["ab-loop-b"] = -10, 200
        state.capture = {media_generation = 1, pending_clip = {start = -10, finish = 200, media_generation = 1}}
        local groups = seekbar_markers.collect(element)
        eq(#groups, 2)
        eq(groups[1].a.time, 0); eq(groups[1].b.time, 100)
        eq(groups[1].a.x, groups[2].a.x); eq(groups[1].b.x, groups[2].b.x)
        for _, group in ipairs(groups) do
            assert(group.a.x >= 0 and group.b.x <= width, "projection stays in bar")
        end
        for _, op in ipairs(inspect(frame(element))) do
            if (op.kind == "move_to" or op.kind == "line_to" or op.kind == "rect_cw") and (op.color == blue or op.color == amber) then
                assert(op.args[1] >= 0 and op.args[1] <= width, "marker geometry stays in bar")
                if op.kind == "rect_cw" then assert(op.args[3] <= width) end
            end
        end
    end
    local element = fixture()
    state.duration = 1e300
    local point = seekbar_markers.project(element, 9e299)
    assert(point.x == point.x and point.x < math.huge, "large finite times do not overflow multiplication")
    properties["ab-loop-a"], properties["ab-loop-b"] = 2e300, 3e300
    eq(seekbar_markers.collect(element)[1].b, nil, "clipped equal endpoints have no range")
end

function invalid_values()
    local element = fixture()
    properties["ab-loop-a"], state.capture.a = 25, 25
    for _, value in ipairs({0, -1, math.huge, -math.huge, 0/0, "100", false}) do
        state.duration = value
        eq(#seekbar_markers.collect(element), 0, "invalid duration omits all markers")
    end
    state.duration = nil; eq(#seekbar_markers.collect(element), 0)
    state.duration = 100
    for _, value in ipairs({math.huge, -math.huge, 0/0, "25", false}) do
        properties["ab-loop-a"], state.capture.a = value, value
        eq(#seekbar_markers.collect(element), 0, "invalid endpoint is omitted")
    end
end

function capture_generation()
    local element = fixture()
    state.capture = {media_generation = 4, pending_clip = {start = 20, finish = 80, media_generation = 3}}
    eq(#seekbar_markers.collect(element), 0, "stale pending never appears on next media")
    state.capture.pending_clip.media_generation = 4
    eq(seekbar_markers.collect(element)[1].b.time, 80)
    state.capture.a, state.capture.pending_clip = 30, nil
    local group = seekbar_markers.collect(element)[1]
    eq(group.a.time, 30); eq(group.b, nil, "completion keeps separately set current A")
    state.capture = {}; eq(#seekbar_markers.collect(element), 0, "end-file clears markers")
    state.capture = {pending_clip = {start = 20, finish = 80}}
    eq(#seekbar_markers.collect(element), 0, "missing generation cannot match missing generation")
end

function crowded_labels()
    local element = fixture()
    properties["ab-loop-a"], properties["ab-loop-b"] = 20, 20.1
    local ass = frame(element)
    eq(#matching(ass, "move_to", blue), 2, "crowded endpoints retain shapes")
    eq(#matching(ass, "text"), 0, "crowded pair suppresses short labels")
    hover(element, 20, 3)
    local label = seekbar_markers.tooltip(element, seekbar_markers.collect(element))
    eq(label, "Loop A/B  0:20 - 0:20", "hover discloses nearby endpoints without repeating the type")
    element = fixture(60); properties["ab-loop-a"] = 20
    eq(#matching(frame(element), "text"), 0, "very narrow bars keep shapes without labels")
end

function typed_hover()
    local element = fixture()
    properties["ab-loop-a"], properties["ab-loop-b"] = 20, 80
    state.capture.a = 20
    hover(element, 20, 3)
    eq(seekbar_markers.tooltip(element, seekbar_markers.collect(element)), "Loop A  0:20")
    hover(element, 20, 15)
    eq(seekbar_markers.tooltip(element, seekbar_markers.collect(element)), "Capture A  0:20")
    hover(element, 80, 3)
    eq(seekbar_markers.tooltip(element, seekbar_markers.collect(element)), "Loop B  1:20")
    hover(element, 50, 3)
    eq(seekbar_markers.tooltip(element, seekbar_markers.collect(element)), nil)
end

function hover_preserves_preview()
    local element = fixture()
    properties["ab-loop-a"], state.chapter_list = 20, {{time = 0, title = "Opening"}}
    hover(element, 20, 3)
    local before, responders = get_slider_value(element), element.eventresponder
    local ass = frame(element)
    assert(text_contains(ass, "Loop A  0:20"), "real render path includes marker explanation")
    assert(text_contains(ass, "Opening"), "existing chapter row remains")
    assert(text_contains(ass, "0:20"), "existing time row remains")
    eq(get_slider_value(element), before, "hover does not change seek mapping")
    eq(element.eventresponder, responders); eq(next(responders), nil, "no marker mouse bindings")
    eq(#commands, 0, "hover emits no seek or mpv mutation")
    local marker = text_contains(ass, "Loop A")
    assert(marker.y < text_contains(ass, "Opening").y, "marker row stays above chapter")
    element.state.mbtnleft = true
    ass = frame(element)
    eq(text_contains(ass, "Loop A"), nil, "drag keeps its normal seek preview")
    assert(text_contains(ass, "Opening"))
    element.state.mbtnleft, state.active_element = false, 2
    eq(seekbar_markers.tooltip(element, seekbar_markers.collect(element)), nil, "other active input wins")
end

function fade_and_context()
    local element = fixture()
    state.capture.a, state.animation = 20, 128
    hover(element, 20, 15)
    local ass = frame(element)
    local square = matching(ass, "rect_cw", amber)[1]
    eq(square.alpha, 128, "capture endpoint follows OSC fade")
    local label = text_contains(ass, "Capture A")
    eq(label.alpha, 128, "hover label follows OSC fade")
    local handle = matching(ass, "round_rect_cw", blue)
    assert(#handle > 0, "handle restores original blue after amber marker")
    for _, op in ipairs(handle) do eq(op.alpha, 128); eq(op.fs, 14, "marker label font does not leak") end
    state.animation = 255
    ass = frame(element)
    eq(matching(ass, "rect_cw", amber)[1].alpha, 255)
    eq(text_contains(ass, "Capture A").alpha, 255)
end

function paused_observers()
    fixture(); state.pause, timers = true, 0
    for _, name in ipairs({"ab-loop-a", "ab-loop-b"}) do
        local observer = assert(observers[name], name .. " observer")
        eq(observer.kind, "number")
        state.tick_timer = nil
        observer.callback(name, 20)
        assert(state.tick_timer and state.tick_timer:is_enabled(), "paused marker change requests redraw")
    end
    eq(timers, 2)
end

function normal_seekbar_only()
    local element = fixture()
    properties["ab-loop-a"], state.capture.a = 20, 20
    for _, name in ipairs({"persistent_seekbar", "volumebar", "zoom_control"}) do
        element.name = name
        eq(#seekbar_markers.collect(element), 0, name .. " omits markers")
    end
    element.name = "seekbar"
    for _, layout in ipairs({"default", "compact", "mini", "seekbar"}) do
        user_opts.layout = layout
        local ass = frame(element)
        eq(#matching(ass, "move_to", blue), 1, layout .. " keeps loop marker")
        eq(#matching(ass, "rect_cw", amber), 1, layout .. " keeps capture marker")
    end
end

function isolated_drawing_events()
    local element = fixture()
    properties["ab-loop-a"], properties["ab-loop-b"] = 0, 100
    state.capture = {media_generation = 1, pending_clip = {start = 0, finish = 100, media_generation = 1}}
    local ass, shape_events, label_events = frame(element), {}, {}
    for _, item in ipairs(inspect(ass)) do
        if item.kind == "rect_cw" or item.kind == "move_to" or item.kind == "line_to" then
            if item.color == blue or item.color == amber then
                eq(item.align, 7, "marker drawing uses an independent top-left origin")
                eq(item.x, element.hitbox.x1); eq(item.y, element.hitbox.y1)
                eq(item.split_drawing, false, "no style tag splits static and visible drawing glyphs")
                shape_events[item.event] = true
                if item.kind == "rect_cw" and item.alpha == 140 then
                    near(item.x + item.args[1], element.hitbox.x1 + 4.5, "absolute range starts at A")
                    near(item.x + item.args[3], element.hitbox.x2 - 4.5, "absolute range stops at B")
                    assert(item.y + item.args[2] >= 607 and item.y + item.args[4] <= 611,
                        "range stays on track, never above transport controls")
                end
            end
        elseif item.kind == "text" and (item.text == "A" or item.text == "B") then
            label_events[item.event] = true
        end
    end
    for event in pairs(shape_events) do eq(label_events[event], nil, "label cannot move a drawing event") end
    -- Prove the inspector applies the final event origin retroactively.
    local moved = new_ass(); moved:new_event(); moved:pos(1, 2); moved:an(7)
    moved:draw_start(); moved:rect_cw(0, 0, 10, 10); moved:draw_stop(); moved:pos(30, 40)
    local rectangle = matching(moved, "rect_cw")[1]
    eq(rectangle.x, 30); eq(rectangle.y, 40)
end

function narrow_hover()
    for _, width in ipairs({60, 100, 150, 240, 500}) do
        local element = fixture(width - 20)
        osc_param.playresx = width
        properties["ab-loop-a"], properties["ab-loop-b"] = 20, 20.1
        hover(element, 20, 3)
        local label = seekbar_markers.tooltip(element, seekbar_markers.collect(element))
        if width < 170 then eq(label, nil, "omit auxiliary hover if the type and both times cannot fit") end
        if label then assert(estimate_text_width(label) + 30 <= width, "auxiliary hover fits canvas margins") end
        local ass = frame(element)
        assert(text_contains(ass, element.slider.tooltipF(get_slider_value(element))),
            "normal time preview remains in narrow windows")
        if label then
            local rendered = assert(text_contains(ass, "Loop A/B"))
            assert(rendered.x - estimate_text_width(rendered.text) / 2 - 5 >= 10,
                "fitted hover background respects left margin")
            assert(rendered.x + estimate_text_width(rendered.text) / 2 + 5 <= width - 10,
                "fitted hover background respects right margin")
        end
    end
    osc_param.playresx = 1020
end
