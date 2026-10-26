-- Only mpv properties, drawing and font measurement are host doubles.
local state, elements, commands, properties = {}, {}, {}, {}
local icons = setmetatable({}, {__index = function(_, key) return key end})
local osc_styles = {tooltip = "{\\fs14}", tooltip_box = "{\\1c&H000000&}"}
local osc_param = {playresx = 1280, playresy = 720}
local bidi = {fsi = "", pdi = ""}
local drawn, measurements, measure_unavailable
local mp = {
    get_property_native = function(name, default) local value = properties[name]; if value == nil then return default end; return value end,
    get_property_bool = function(name, default) local value = properties[name]; if value == nil then return default end; return value end,
    get_property_number = function(name, default) return properties[name] or default end,
    command = function(value) commands[#commands + 1] = value end,
    commandv = function(...) commands[#commands + 1] = {...} end,
    command_native = function(value)
        assert(value[1] == "escape-ass")
        assert(#value == 2, "escape-ass requires exactly one text argument")
        return value[2]:gsub("\\", "\\\\"):gsub("{", "\\{")
    end,
}
local function set_popover(name) state.popover = name end
local function request_init() end
local function mouse_hit() return true end
local function mouse_hit_coords() return true end
local function get_virt_scale_factor() return 1 end
local function estimate_text_width(text)
    assert(type(text) == "string" and text ~= "", "absent/empty tooltip must not reach measurement")
    measurements = measurements + 1
    if measure_unavailable then return nil end
    return #text * 4
end
local function new_ass()
    local result = {ops = {}}
    function result:append(text) self.ops[#self.ops + 1] = {kind = "append", text = text} end
    function result:new_event() self.ops[#self.ops + 1] = {kind = "event"} end
    -- Current mp.assdraw emits these exact tags regardless of Lua arguments.
    function result:draw_start() self:append("{\\p4}") end
    function result:draw_stop() self:append("{\\p0}") end
    for _, name in ipairs({"pos", "an", "round_rect_cw"}) do
        result[name] = function(self, ...) self.ops[#self.ops + 1] = {kind = name, args = {...}} end
    end
    return result
end

-- SOURCE FUNCTIONS ARE INSERTED HERE

local function eq(actual, expected) assert(actual == expected, "expected " .. tostring(expected) .. ", got " .. tostring(actual)) end
local function has(text, part) assert(text:find(part, 1, true), "missing " .. part .. ": " .. text) end
local function lacks(text, part) assert(not text:find(part, 1, true), "unexpected " .. part .. ": " .. text) end
local function near(actual, expected) assert(math.abs(actual - expected) < 0.002, "expected " .. expected .. ", got " .. actual) end
local function events(ass)
    local result, event = {}, nil
    for _, op in ipairs(ass.ops) do
        if op.kind == "event" then event = {positions = 0}; result[#result + 1] = event
        elseif op.kind == "pos" then event.x, event.y = op.args[1], op.args[2]; event.positions = event.positions + 1
        elseif op.kind == "an" then event.align = op.args[1]
        elseif op.kind == "round_rect_cw" then event.box = op.args
        elseif op.kind == "append" then
            local pos = 1
            while pos <= #op.text do
                if op.text:sub(pos, pos) == "{" then
                    local close = assert(op.text:find("}", pos, true))
                    local tags = op.text:sub(pos, close)
                    local color = tags:match("\\1c&H(%x+)&")
                    local alpha = tags:match("\\1a&H(%x+)&")
                    local scale = tags:match("\\p(%d+)")
                    if color then event.color = color:upper() end
                    if alpha then event.alpha = tonumber(alpha, 16) end
                    if scale then
                        event.drawing = tonumber(scale) > 0
                        if event.drawing then event.drawing_scale = tonumber(scale) end
                    end
                    pos = close + 1
                else
                    local next_tag = op.text:find("{", pos, true) or #op.text + 1
                    local payload = op.text:sub(pos, next_tag - 1)
                    if event.drawing then event.path = (event.path or "") .. payload
                    else event.text = (event.text or "") .. payload end
                    pos = next_tag
                end
            end
        end
    end
    return result
end
local function bounds(event)
    local index, x1, y1, x2, y2 = 0, math.huge, math.huge, -math.huge, -math.huge
    event.path:gsub("%-?[%d.]+", function(value)
        index = index + 1; value = tonumber(value)
        if index % 2 == 1 then x1, x2 = math.min(x1, value), math.max(x2, value)
        else y1, y2 = math.min(y1, value), math.max(y2, value) end
    end)
    -- Raw ASS drawing coordinates shrink by 2^(p-1). Helper rectangle arguments
    -- are already logical units, but custom appended paths receive no scaling.
    local unit = 1 / 2 ^ (event.drawing_scale - 1)
    return {x1 = event.x + x1 * unit, y1 = event.y + y1 * unit,
        x2 = event.x + x2 * unit, y2 = event.y + y2 * unit}
end
local function hint(name)
    local value = elements[name].tooltipF
    if type(value) == "function" then return value() end
    return value
end
local function fixture()
    elements, commands, properties = {}, {}, {sid = 1, ["sub-visibility"] = true,
        ["track-list"] = {{id = 1, type = "sub", title = "ordinary"}}, ["osd-width"] = 1280}
    state = {sub_track_count = 1, audio_track_count = 1, volume = 60, speed = 1,
        duration = 360, mouse_down_counter = 0}
    measurements, measure_unavailable = 0, false
    osc_param.playresx, osc_param.playresy = 1280, 720
    build_controls()
end

function configured_hints_and_dispatch()
    fixture()
    eq(hint("sub_track"), "中键选择字幕 · 右键调整字幕")
    eq(hint("vol_ctrl"), "中键选择音轨 · 右键100%")
    eq(hint("screenshot"), "右键标记A/B · 中键输出目录")
    eq(hint("speed"), "右键恢复1× · 滚轮±0.25×")
    eq(hint("time_codes"), "右键复制时间")
    eq(elements.vol_ctrl.tooltipF(true), "中键选择音轨 · 右键100%")
    eq(elements.speed.tooltipF(true), "右键恢复1×")
    for _, entry in ipairs({
        {"sub_track", "mbtn_left_up", "script-binding subtitle_controls/toggle"},
        {"sub_track", "shift+mbtn_left_down", "script-binding subtitle_controls/select"},
        {"sub_track", "mbtn_right_up", "script-binding subtitle_controls/adjust-mode"},
        {"vol_ctrl", "mbtn_left_up", "no-osd cycle mute"},
        {"vol_ctrl", "shift+mbtn_left_down", "script-binding select/select-aid"},
        {"vol_ctrl", "mbtn_right_up", "no-osd set volume 100"},
    }) do
        elements[entry[1]].eventresponder[entry[2]]()
        eq(commands[#commands], entry[3])
    end
    for _, name in ipairs({"sub_track", "vol_ctrl", "screenshot", "title", "speed"}) do lacks(hint(name), "左键") end
    state.mute = true; state.volume = 60.5
    eq(hint("vol_ctrl"), "中键选择音轨 · 右键100%")
end

function title_and_custom_bindings()
    fixture(); eq(hint("title"), "右键定位文件")
    state.is_url = true; eq(hint("title"), "右键打开来源页")
    user_opts.title_mbtn_left_command = "show-text custom"
    user_opts.title_mbtn_right_command = "ignore"
    eq(hint("title"), nil)
    user_opts.screenshot_mbtn_right_command = "show-text custom"
    user_opts.screenshot_mbtn_mid_command = "ignore"
    eq(hint("screenshot"), nil)
    user_opts.vol_ctrl_mbtn_mid_command = "show-text custom"
    user_opts.vol_ctrl_mbtn_right_command = "ignore"
    user_opts.vol_ctrl_wheel_up_command = "add volume 10"
    eq(hint("vol_ctrl"), nil)
    user_opts.speed_mbtn_right_command = "show-text custom"
    user_opts.speed_wheel_down_command = "ignore"
    eq(hint("speed"), nil)
end

function subtitle_states()
    fixture(); properties["sub-visibility"] = false; build_controls()
    eq(hint("sub_track"), "中键选择字幕 · 右键调整字幕")
    properties["track-list"] = {{id = 1, type = "sub", title = "Bilibili Danmaku"}}
    state.sub_track_count = 0; build_controls()
    eq(elements.sub_track.enabled, false); eq(elements.sub_track.nothingavailable, "无字幕")
    user_opts.sub_track_mbtn_mid_command = "ignore"
    user_opts.sub_track_mbtn_right_command = "show-text custom"
    build_controls(); eq(hint("sub_track"), nil)
end

function popover_placement()
    fixture()
    for _, name in ipairs({"vol_ctrl", "screenshot", "speed"}) do
        local element = elements[name]
        element.hitbox = {x1 = 500, x2 = 524, y1 = 680, y2 = 704}
        state.seekbar_element = {hitbox = {y1 = 650}}
        local body = {y1 = 450, y2 = 628}
        state.popover = name
        state.local_popovers = {[name] = {anchor = element, body = body}}
        drawn = nil; render_hint(element)
        assert(drawn)
        local background = events(drawn.ass)[1]
        near(background.y + background.box[4], 445)
        assert(background.y >= 8)
        eq(body.y1, 450); eq(element.hitbox.y1, 680)
        body.y1 = 20; drawn = nil; render_hint(element); eq(drawn, nil)
        body.y1 = 450; osc_param.playresx = 100; drawn = nil; render_hint(element); eq(drawn, nil)
        osc_param.playresx = 1280
    end
    local element = elements.sub_track
    element.enabled = false; element.hitbox = {x1 = 500, x2 = 524, y1 = 680, y2 = 704}
    element.nothingavailable = "无字幕"; drawn = nil; state.popover = nil
    render_hint(element); eq(drawn, nil)
end

function title_placement()
    fixture()
    local title, subtitle, time, camera = elements.title, elements.sub_track, elements.time_codes, elements.screenshot
    local chapter = {name = "chapter_title", visible = true, hitbox = {x1 = 25, x2 = 300, y1 = 550, y2 = 566}}
    title.hitbox = {x1 = 25, x2 = 800, y1 = 600, y2 = 624}
    subtitle.hitbox = {x1 = 70, x2 = 94, y1 = 680, y2 = 704}
    time.hitbox = {x1 = 180, x2 = 340, y1 = 680, y2 = 696}
    camera.hitbox = {x1 = 900, x2 = 924, y1 = 680, y2 = 704}
    state.seekbar_element = {hitbox = {y1 = 650}}
    -- Match prepare_elements: rendering no longer has name-keyed entries.
    elements = {title, subtitle, time, camera}
    eq(elements.title, nil)
    local function bottom(element, expected)
        drawn = nil; render_hint(element); assert(drawn, element.name .. " missing at " .. expected)
        local background = events(drawn.ass)[1]
        near(background.y + background.box[4], expected)
        assert(background.y >= 8)
    end
    for _, element in ipairs({title, subtitle, time}) do bottom(element, 592) end
    elements[#elements + 1] = chapter
    for _, element in ipairs({title, subtitle, time}) do bottom(element, 542) end
    -- Occupancy is an explicit dependency: missing it must never capture an
    -- earlier lexical/global elements table (the real source declares it later).
    local unoccupied = button_tooltip.layout("右键复制时间", osc_styles.tooltip, 260, 645)
    near(unoccupied.y2, 648)
    local occupied = button_tooltip.layout("右键复制时间", osc_styles.tooltip, 260, 645, 10, elements)
    near(occupied.y2, 542)
    chapter.visible = false
    bottom(time, 592)
    title.visible = false
    bottom(time, 648)
    chapter.visible = true
    for _, hitbox in ipairs({{}, {x1 = 25, x2 = 25, y1 = 20, y2 = 36},
        {x1 = 25, x2 = 100, y1 = 36, y2 = 20}, {x1 = 25, x2 = 100, y1 = "20", y2 = 36}}) do
        chapter.hitbox = hitbox
        bottom(time, 648)
    end
    chapter.hitbox = nil
    bottom(time, 648)
    title.visible = true
    user_opts.tooltip_font_size = 10
    title.hitbox.y1, title.hitbox.y2 = 36, 60
    bottom(time, 28) -- background top is exactly the existing 8-unit canvas margin
    title.hitbox.y1 = 35.9
    drawn = nil; render_hint(time); eq(drawn, nil)
    user_opts.tooltip_font_size = 14
    title.hitbox.y1, title.hitbox.y2 = 600, 624
    state.popover = "test"
    state.local_popovers = {test = {anchor = camera, body = {y1 = 450, y2 = 628}}}
    bottom(camera, 445) -- the existing functional panel still wins when it is higher
    title.hitbox.y1, title.hitbox.y2 = 430, 454
    bottom(camera, 422)
    eq(state.seekbar_element.hitbox.y1, 650)
    eq(subtitle.hitbox.y1, 680); eq(time.hitbox.y1, 680)
    eq(state.local_popovers.test.body.y1, 450)
end

function mouse_prefixes()
    fixture()
    local entries = button_tooltip.entries("中键选择字幕 · 右键调整字幕 · 滚轮±0.25× · 左键测试")
    eq(#entries, 4)
    for index, expected in ipairs({{"middle", "选择字幕"}, {"right", "调整字幕"}, {"wheel", "±0.25×"}, {"left", "测试"}}) do
        eq(entries[index].mouse, expected[1]); eq(entries[index].text, expected[2])
    end
    entries = button_tooltip.entries("自定义说明 · 右键 · 前缀右键不替换")
    eq(#entries, 3)
    for _, entry in ipairs(entries) do eq(entry.mouse, nil) end
    eq(entries[1].text, "自定义说明"); eq(entries[2].text, "右键"); eq(entries[3].text, "前缀右键不替换")
    eq(#button_tooltip.entries(nil), 0); eq(#button_tooltip.entries(""), 0)
    local layout = button_tooltip.layout("未知{样式}", osc_styles.tooltip, 100, 100)
    eq(layout.entries[1].text, "未知\\{样式}")
end

function mouse_layout()
    fixture()
    for _, fs in ipairs({10, 14, 22}) do
        user_opts.tooltip_font_size = fs
        for _, label in ipairs({hint("vol_ctrl"), hint("speed"), hint("screenshot"), hint("time_codes"), "未知说明"}) do
            for _, tx in ipairs({-500, 10, 640, 1270, 2000}) do
                local layout = button_tooltip.layout(label, osc_styles.tooltip, tx, 442, 10)
                assert(layout); assert(layout.x1 >= 10 and layout.x2 <= 1270)
                assert(layout.y1 >= 8 and layout.y2 <= 712)
                for _, entry in ipairs(layout.entries) do
                    local x = layout.text_x + entry.offset
                    if entry.mouse then x = x + entry.icon_width + layout.icon_gap end
                    assert(x >= layout.x1 and x + entry.width <= layout.x2)
                end
                if layout.entries[1].mouse then near(layout.height, fs * 1.4 + 6) end
            end
        end
    end
    user_opts.tooltip_font_size = 14
    local layout = button_tooltip.layout("中键选择字幕 · 右键调整字幕", osc_styles.tooltip, 10, 442)
    local expected_width = 2 * (19.6 + 3.92 + #"选择字幕" * 4) + #" · " * 4 + 10
    near(layout.width, expected_width)
    local wheel_layout = button_tooltip.layout("滚轮±0.25× · 右键恢复1×", osc_styles.tooltip, 640, 442)
    near(wheel_layout.entries[1].icon_width, 19.6 * 28 / 24)
    near(wheel_layout.entries[2].offset, 19.6 * 28 / 24 + 3.92 + #"±0.25×" * 4 + #" · " * 4)
    local ass = new_ass()
    button_tooltip.render(ass, wheel_layout, osc_styles.tooltip, {0, 255, 255, 255}, 0)
    local output = events(ass)
    -- The outward arrow edge must retain the full text gap after rendering,
    -- including when another mouse action follows in the same tooltip.
    near(output[5].x - bounds(output[4]).x2, wheel_layout.icon_gap)
    assert(output[6].x + wheel_layout.separator_w <= output[7].x)
    eq(button_tooltip.layout("中键选择字幕", osc_styles.tooltip, 20, 20), nil)
    eq(button_tooltip.layout("中键选择字幕", osc_styles.tooltip, 20, 719), nil)
    osc_param.playresx = 30
    eq(button_tooltip.layout("中键选择字幕", osc_styles.tooltip, 20, 100), nil)
    osc_param.playresx = 1280; measure_unavailable = true
    eq(button_tooltip.layout("中键选择字幕", osc_styles.tooltip, 20, 100), nil)
    local before = measurements
    eq(button_tooltip.layout(nil, osc_styles.tooltip, 20, 100), nil)
    eq(button_tooltip.layout("", osc_styles.tooltip, 20, 100), nil)
    eq(measurements, before)
end

function mouse_shapes()
    fixture()
    for _, size in ipairs({14, 19.6, 24, 39.2}) do
        local scale = size / 24
        for _, kind in ipairs({"left", "middle", "right", "wheel"}) do
            local ass = new_ass()
            button_tooltip.mouse(ass, kind, 100, 200, size, {0, 255, 255, 255})
            local shapes = events(ass)
            eq(#shapes, (kind == "middle" or kind == "right") and 2 or 3)
            for _, shape in ipairs(shapes) do
                eq(shape.positions, 1); eq(shape.align, 7); eq(shape.text, nil)
                eq(shape.drawing_scale, 1)
                local frame = bounds(shape)
                local width = kind == "wheel" and size * 28 / 24 or size
                assert(frame.x1 >= 100 and frame.x2 <= 100 + width + 0.002)
                assert(frame.y1 >= 200 and frame.y2 <= 200 + size + 0.002)
            end
            local outline = bounds(shapes[1])
            near(outline.x1, 100 + 4 * scale); near(outline.x2, 100 + 20 * scale)
            near(outline.y1, 200 + scale); near(outline.y2, 200 + 23 * scale)
            if kind == "right" or kind == "left" then
                local highlight = bounds(shapes[2]); eq(shapes[2].color, "BB8712")
                if kind == "right" then
                    near(highlight.x1, 100 + 12 * scale - 1)
                    eq(#shapes, 2) -- no later grey wheel may repaint the blue centre
                else near(highlight.x2, 100 + 12 * scale + 1) end
            else
                local wheel = bounds(shapes[2]); eq(shapes[2].color, "BB8712")
                near(wheel.x1, 100 + 9.5 * scale); near(wheel.x2, 100 + 14.5 * scale)
                near(wheel.y1, 200 + 2.9 * scale); near(wheel.y2, 200 + 10.9 * scale)
                near((wheel.x1 + wheel.x2) / 2, 100 + 12 * scale)
                near((wheel.y1 + wheel.y2) / 2, 200 + 6.9 * scale)
                if kind == "wheel" then
                    local arrows = bounds(shapes[3]); eq(shapes[3].color, "DADADA")
                    near(arrows.x1, 100 + 22 * scale); near(arrows.x2, 100 + 28 * scale)
                    near(arrows.y1, 200 + 2 * scale); near(arrows.y2, 200 + 22 * scale)
                    assert(arrows.x1 > outline.x2)
                    local _, contours = shapes[3].path:gsub("m ", "m "); eq(contours, 2)
                end
            end
        end
    end
end

function mouse_events_and_alpha()
    fixture()
    local element = elements.speed
    element.hitbox = {x1 = 500, x2 = 542, y1 = 680, y2 = 704}
    element.layout = {alpha = {32, 255, 0, 255}}
    state.seekbar_element = {hitbox = {y1 = 650}}
    for _, animation in ipairs({0, 128, 255}) do
        state.animation = animation
        local output = events(render_hint(element))
        local text_count, shape_count = 0, 0
        for index, event in ipairs(output) do
            eq(event.positions, 1)
            local expected = index == 1 and mult_alpha(mult_alpha(77, 32), animation) or mult_alpha(32, animation)
            eq(event.alpha, tonumber(string.format("%X", expected), 16))
            if event.path then
                shape_count = shape_count + 1; eq(event.text, nil); eq(event.align, 7)
            elseif event.text then
                text_count = text_count + 1; eq(event.align, 4)
                lacks(event.text, "右键"); lacks(event.text, "滚轮")
            end
        end
        eq(shape_count, 5); eq(text_count, 3)
    end
    local layout = button_tooltip.layout("右键复制时间", osc_styles.tooltip, 100, 100)
    local ass = new_ass(); state.animation = 255
    button_tooltip.render(ass, layout, osc_styles.tooltip, {0, 255, 255, 255}, 0)
    eq(events(ass)[2].alpha, 0) -- explicit topbar animation override must win
end

function nil_and_empty_rendering()
    fixture()
    local element = elements.vol_ctrl
    -- Deliberately leave hitbox absent: a suppressed hint must exit before
    -- geometry, font measurement or ASS rendering is touched.
    for _, callback in ipairs({function() return nil end, function() return "" end}) do
        element.tooltipF = callback
        drawn = nil; render_hint(element); eq(drawn, nil); eq(measurements, 0)
    end
    element.tooltipF = ""; render_hint(element); eq(drawn, nil); eq(measurements, 0)
    element.tooltipF = nil; render_hint(element); eq(drawn, nil); eq(measurements, 0)
    element.tooltipF = function() error("disabled control must not request its tooltip") end
    element.enabled = false; render_hint(element); eq(drawn, nil); eq(measurements, 0)
    element = elements.sub_track; element.enabled = false
    element.nothingavailable = "无字幕"; render_hint(element); eq(drawn, nil); eq(measurements, 0)
end

function simple_buttons()
    fixture()
    for _, name in ipairs({"play_pause", "info", "ontop", "fullscreen"}) do
        eq(elements[name].tooltipF, nil)
        drawn = nil; render_hint(elements[name]); eq(drawn, nil)
    end
    eq(measurements, 0)
end
