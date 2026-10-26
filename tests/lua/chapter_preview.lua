local osc_param = {playresx = 500, playresy = 720}
local osc_styles = {tooltip = "{\\fs14}", tooltip_box = "", thumbnail = ""}
local state = {duration = 600, chapter_list = {}, mouse_in_window = true}
local thumbfast = {disabled = true, available = true, width = 80, height = 45}
local hover_x = 0
local commands, escapes, measurements = {}, {}, {}

local function eq(actual, expected, label)
    assert(actual == expected, (label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local function character_end(text, position)
    local byte = text:byte(position)
    local size = byte < 128 and 1 or byte >= 240 and 4 or byte >= 224 and 3 or byte >= 194 and 2 or 0
    assert(size > 0 and position + size - 1 <= #text, "invalid UTF-8 character boundary")
    for index = position + 1, position + size - 1 do
        local continuation = text:byte(index)
        assert(continuation >= 128 and continuation < 192, "split UTF-8 character")
    end
    return position + size - 1
end

-- This host double marks escaped user data as opaque literal text. It deliberately
-- does not reimplement mpv's escape-ass byte encoding or libass font rendering.
local function escaped(value) return "\1" .. value .. "\2" end
local function visible_text(data)
    local result, position = {}, 1
    while position <= #data do
        local char = data:sub(position, position)
        if char == "\1" then
            local last = assert(data:find("\2", position + 1, true), "unfinished escaped value")
            result[#result + 1] = data:sub(position + 1, last - 1); position = last + 1
        elseif char == "{" then
            position = assert(data:find("}", position + 1, true), "unfinished ASS style") + 1
        else
            local last = character_end(data, position)
            result[#result + 1] = data:sub(position, last); position = last + 1
        end
    end
    return table.concat(result)
end
local function measure(data)
    local width, font_size, position = 0, 14, 1
    local function text_width(text)
        local amount, index = 0, 1
        while index <= #text do
            local last = character_end(text, index)
            local glyph = text:sub(index, last)
            amount = amount + (glyph == "…" and font_size / 2 or last > index and font_size or font_size / 2)
            index = last + 1
        end
        return amount
    end
    while position <= #data do
        local char = data:sub(position, position)
        if char == "\1" then
            local last = assert(data:find("\2", position + 1, true))
            width = width + text_width(data:sub(position + 1, last - 1)); position = last + 1
        elseif char == "{" then
            local last = assert(data:find("}", position + 1, true))
            local size = data:sub(position, last):match("\\fs([%d.]+)")
            if size then font_size = tonumber(size) end
            position = last + 1
        else
            local last = character_end(data, position)
            width = width + text_width(data:sub(position, last)); position = last + 1
        end
    end
    -- estimate_text_width removes libass side bearing based on the base style.
    return width + 14 * 0.08 * 2
end
local mp = {
    create_osd_overlay = function()
        return {update = function(self)
            measurements[#measurements + 1] = self.data
            return {x0 = 0, x1 = measure(self.data)}
        end}
    end,
    command_native = function(args)
        eq(args[1], "escape-ass", "only expected native operation")
        escapes[#escapes + 1] = args[2]
        return escaped(args[2])
    end,
    get_property_number = function(name) if name == "osd-width" then return osc_param.playresx end end,
    commandv = function(...) commands[#commands + 1] = {...} end,
}
local function get_virt_mouse_pos() return hover_x, 600 end
local function get_virt_scale_factor() return 1, 1 end
local function get_slider_value() return 50 end
local function ass_append_alpha() end
local function new_ass()
    local result = {events = {}}
    function result:new_event() self.current = {}; self.events[#self.events + 1] = self.current end
    function result:append(text) self.current.text = (self.current.text or "") .. text end
    function result:pos(x, y) self.current.x, self.current.y = x, y end
    function result:an(value) self.current.align = value end
    function result:draw_start() end
    function result:draw_stop() end
    function result:round_rect_cw(x1, y1, x2, y2) self.current.rect = {x1, y1, x2, y2} end
    return result
end

-- SOURCE FUNCTIONS ARE INSERTED HERE

local function frame(title, width, mouse, format, thumbnail)
    osc_param.playresx, hover_x = width, mouse
    user_opts.layout, user_opts.chapter_fmt = "default", format or "%s"
    state.chapter_list = title and {{time = 0, title = title}} or {}
    state.seekbar_element = {hitbox = {y1 = 600}}
    thumbfast.disabled = not thumbnail
    commands, escapes, measurements, text_width_cache = {}, {}, {}, {}
    local ass = new_ass()
    local element = {name = "seekbar", thumbnailable = true, hitbox = {y1 = 600},
        slider = {tooltipF = function() return "05:00" end}}
    local result = render_preview(element, {tooltip_an = 2, tooltip_style = osc_styles.tooltip,
        adjust_tooltip = true, alpha = {0, 0, 0, 0}}, {h = 18}, ass)
    local labels, boxes = {}, {}
    for _, event in ipairs(ass.events) do
        if event.align == 2 then labels[#labels + 1] = event end
        if event.rect and event.align == 7 and event.rect[1] == 0 then boxes[#boxes + 1] = event end
    end
    return result, labels, boxes
end

function plain_cjk_and_utf8()
    for _, title in ipairs({"01 Opening", "第一章 序章", "第1話 はじまり", "中文かな🔥"}) do
        local result, labels = frame(title, 900, 450)
        eq(visible_text(result.chapter), title, "plain chapter text")
        eq(#labels, 2, "chapter and time")
        assert(labels[1].y < labels[2].y, "chapter precedes time vertically")
    end
end
function metadata_uses_escape_ass()
    local title = "字幕{\\fs72}\\N 与 {花括号}"
    local result = frame(title, 1000, 500)
    assert(#escapes > 0, "chapter metadata must pass through escape-ass")
    eq(escapes[1], title, "escape raw metadata before adding the format")
    eq(result.chapter, escaped(title), "literal metadata is not active ASS")
    eq(visible_text(result.chapter), title, "backslashes and braces remain literal")
end
function long_text_at_both_edges()
    local title = string.rep("很长の章节🔥", 60)
    for _, mouse in ipairs({0, 200}) do
        local result, labels, boxes = frame(title, 200, mouse)
        assert(result.width <= 170, "chapter must fit available text width")
        assert(visible_text(result.chapter):sub(-#"…") == "…", "long chapter ends in ellipsis")
        eq(#labels, 2)
        for _, box in ipairs(boxes) do
            assert(box.x >= 10 and box.x + box.rect[3] <= 190, "tooltip box stays inside horizontal margins")
        end
    end
end
function controlled_format_keeps_style()
    text_width_cache, measurements = {}, {}
    estimate_text_width("12:34", osc_styles.tooltip)
    assert(measurements[1]:find("00:00", 1, true), "existing timer digit normalization remains the default")
    local format = "{\\fs24\\c&H1287BB&}[%s]{\\r}"
    local result = frame("中", 500, 250, format)
    eq(result.chapter, "{\\fs24\\c&H1287BB&}[" .. escaped("中") .. "]{\\r}", "controlled ASS is preserved")
    eq(visible_text(result.chapter), "[中]", "style bytes are not visible characters")
    eq(result.width, 48, "font size in chapter_fmt contributes to actual width")
    for _, data in ipairs(measurements) do assert(not data:find("\\fs00", 1, true), "format font size must not be digit-normalized") end
    local long = frame(string.rep("中文", 100), 200, 0, format)
    assert(long.width <= 170, "styled long chapter fits after formatting")
    assert(long.chapter:sub(-#"{\\r}") == "{\\r}", "format suffix is never truncated")
    local fixed_format = string.rep("PREFIX", 20) .. "%s"
    local omitted, labels = frame("中", 200, 0, fixed_format)
    eq(omitted.chapter, nil, "omit chapter if fixed format cannot fit")
    eq(#labels, 1, "no empty chapter row when fixed format cannot fit")
    eq(user_opts.chapter_fmt, fixed_format, "never rewrite the configured format")
end
function thumbnail_and_text_keep_independent_anchors()
    for _, mouse in ipairs({0, 500}) do
        local result, labels = frame("OP", 500, mouse, "%s", true)
        eq(#commands, 1); eq(commands[1][3], "thumb")
        local thumb_center = commands[1][5] + thumbfast.width / 2
        assert(result.x ~= thumb_center, "text keeps its own edge anchor")
        assert(commands[1][6] + thumbfast.height < labels[1].y, "thumbnail above chapter")
        assert(labels[1].y < labels[2].y and labels[2].y < 600, "chapter above time above seekbar")
    end
end
function very_narrow_canvas()
    for _, width in ipairs({1, 10, 30, 60}) do
        local result, _, boxes = frame(string.rep("非常长", 40), width, 0)
        assert(result.x >= 0 and result.x <= width, "narrow canvas uses a valid horizontal anchor")
        if width <= 30 then eq(result.chapter, nil, "omit chapter when even ellipsis cannot fit") end
        if result.chapter then
            local chapter_box = boxes[1]
            assert(chapter_box.x >= 0 and chapter_box.x + chapter_box.rect[3] <= width, "narrow chapter box fits")
        end
    end
end
function absent_or_disabled_chapter()
    for _, sample in ipairs({{false, "%s"}, {"", "%s"}, {"OP", "no"}}) do
        local result, labels = frame(sample[1] or nil, 500, 0, sample[2], true)
        eq(result.chapter, nil); eq(#labels, 1, "only time without chapter")
        eq(#escapes, 0, "no needless chapter escaping")
    end
end
