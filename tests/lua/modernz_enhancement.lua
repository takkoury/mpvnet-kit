local user_opts = {layout = 'default', tooltip_font_size = 14, tooltip_hints = true,
    thumbnail_box_color = '#111111', seek_handle_size = 0, minmousemove = 0}
local osc_param = {playresx = 1280, playresy = 720, areas = {input = {}}}
local osc_styles = {tooltip = '{\\fs14}', tooltip_box = '', time = '', element_hover = ''}
local state = {enhancement = {}, mouse_in_window = true, osc_visible = true, popover_hover_ready = true}
local elements, observers, commands, areas, bindings, close_popover = {}, {}, {}, {}, {}, nil
local mouse_x, mouse_y, ticks = 0, 0, 0
local function get_virt_mouse_pos() return mouse_x, mouse_y end
local function estimate_text_width(text) return #text * 7 end
local function request_tick() ticks = ticks + 1 end
local function set_virt_mouse_area(x1, y1, x2, y2, name) areas[name] = {x1, y1, x2, y2} end
local function window_controls_enabled() return false end
local function show_osc() end
local mp = {
    commandv = function(...) commands[#commands + 1] = {...} end,
    observe_property = function(name, _, callback) observers[name] = callback end,
    get_time = function() return 1 end,
    add_forced_key_binding = function(_, name, callback) bindings[name] = callback end,
    remove_key_binding = function(name) bindings[name] = nil end,
}
local assdraw = {ass_new = function()
    return setmetatable({text = {}, positions = {}, alignments = {}, rectangles = {}, shapes = {}}, {__index = function(_, key)
        if key == 'pos' then return function(self, x, y) self.positions[#self.positions+1] = {x,y} end end
        if key == 'an' then return function(self, value) self.alignments[#self.alignments+1] = value end end
        if key == 'append' then return function(self, text) self.text[#self.text + 1] = text end end
        if key == 'rect_cw' then return function(self, ...) self.rectangles[#self.rectangles+1] = {...} end end
        if key == 'round_rect_cw' then return function(self, ...) self.shapes[#self.shapes+1] = {...} end end
        return function() end
    end})
end}

-- SOURCE FUNCTIONS ARE INSERTED HERE

local function eq(actual, expected, label)
    assert(actual == expected, (label or 'value') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
end
local function has(text, needle) assert(text:find(needle, 1, true), 'missing: ' .. needle .. '\n' .. text) end
local function fixture(value, bottom_space)
    elements = {}; state.enhancement = value
    state.active_element, state.popover, state.animation = nil, nil, nil
    state.mouse_in_window, state.osc_visible, state.popover_hover_ready = true, true, true
    local anchor = new_element('enhancement', 'button')
    anchor.eventresponder.mbtn_left_up = function() mp.commandv('anchor-click') end
    anchor.layout = {geometry = {x = osc_param.playresx - 24, y = osc_param.playresy - (bottom_space or 40) + 12,
        an = 5, w = 24, h = 24}, layer = 50, alpha = {0, 255, 255, 255}, style = ''}
    setup_local_popovers(); prepare_elements(); state.popover = 'enhancement'
    local popup = state.local_popovers.enhancement
    mouse_x, mouse_y = anchor.layout.geometry.x, anchor.layout.geometry.y
    if popup then popup.update() end
    return anchor, popup
end
local function hover_row(popup, number)
    local row = popup.enhancement_rows[number].element
    mouse_x, mouse_y = (row.hitbox.x1 + row.hitbox.x2) / 2, (row.hitbox.y1 + row.hitbox.y2) / 2
    process_event('mouse_move')
    return row
end
local function render_footer()
    local ass = assdraw.ass_new(); render_enhancement_footer(ass)
    return ass, table.concat(ass.text, '\n')
end
local function same_box(actual, expected)
    for _, coordinate in ipairs({'x1', 'y1', 'x2', 'y2'}) do eq(actual[coordinate], expected[coordinate], coordinate) end
end
local function copy_box(box) return {x1 = box.x1, y1 = box.y1, x2 = box.x2, y2 = box.y2} end

function normal_panel_has_only_five_options()
    local _, popup = fixture({desired = 'ANIME_LIGHT', applied = 'OFF', ready = true,
        available = {OFF = true}, unavailable_reasons = {ANIME_LIGHT = 'hdr_source'}})
    eq(#popup.enhancement_rows, 5); eq(popup.footer, nil)
    eq(popup.body.x2 - popup.body.x1, 104); eq(popup.body.y2 - popup.body.y1, 160)
    local ass = render_footer(); eq(#ass.text, 0, 'normal panel has no status disclosure')
    has(popup.enhancement_rows[1].element.content(), 'bb8712')
    for _, row in ipairs(popup.enhancement_rows) do
        local text = row.element.content()
        assert(not text:find('Current:', 1, true)); assert(not text:find('Selected:', 1, true))
    end
end

function disabled_row_hover_explains_gate_without_click()
    local _, popup = fixture({desired = 'QUALITY', applied = 'QUALITY', ready = true,
        available = {OFF = true, QUALITY = true}, unavailable_reasons = {ANIME_LIGHT = 'hdr_source'}})
    local row = hover_row(popup, 4)
    eq(row.enabled, false)
    process_event('mbtn_left', 'down'); process_event('mbtn_left', 'up')
    eq(#commands, 0, 'disabled click is guarded')
    local ass, text = render_footer(); has(text, 'SDR only')
    assert(not text:find('Current:', 1, true)); assert(not text:find('Selected:', 1, true))
    eq(#ass.rectangles, 1, 'footer draws a divider'); eq(#ass.shapes, 0, 'footer has no separate background')
    eq(ass.positions[2][1], popup.body.x1 + (popup.body.x2 - popup.body.x1) / 2)
    eq(ass.positions[2][2], popup.rows_body.y2 + 6); eq(ass.alignments[2], 8)
    has(text, '\\bord0\\shad0')
    hover_row(popup, 2); eq(popup.footer, nil)
    process_event('mbtn_left', 'down'); process_event('mbtn_left', 'up')
    eq(#commands, 1); eq(commands[1][4], 'QUALITY')
    has(row.content(), '888888'); has(popup.enhancement_rows[2].element.content(), 'bb8712')
end

function footer_keeps_rows_and_hover_stable()
    local _, popup = fixture({desired = 'QUALITY', applied = 'QUALITY', ready = true,
        available = {OFF = true, QUALITY = true}, unavailable_reasons = {ANIME_LIGHT = 'hdr_source', ANIME_STRONG = 'anime_unverified'}})
    local boxes = {}; for i, row in ipairs(popup.enhancement_rows) do boxes[i] = copy_box(row.element.hitbox) end
    hover_row(popup, 4)
    local first = copy_box(popup.body)
    for i = 1, 3 do process_event('mouse_move'); same_box(popup.body, first) end
    mouse_x, mouse_y = (popup.body.x1 + popup.body.x2) / 2, popup.footer.y + 12
    process_event('mouse_move'); eq(state.popover, 'enhancement'); same_box(popup.body, first)
    has(select(2, render_footer()), 'SDR only')
    hover_row(popup, 5); has(select(2, render_footer()), 'Validation required')
    hover_row(popup, 2); eq(popup.footer, nil)
    for i, row in ipairs(popup.enhancement_rows) do same_box(row.element.hitbox, boxes[i]) end
    same_box(popup.body, popup.rows_body)
end

function background_and_input_share_footer_bounds()
    local anchor, popup = fixture({ready = true, available = {OFF = true},
        unavailable_reasons = {ANIME_LIGHT = 'shader_missing'}})
    local underneath = new_element('underneath', 'button')
    underneath.eventresponder.mbtn_left_down = function() mp.commandv('underneath-click') end
    underneath.eventresponder.wheel_up_press = function() mp.commandv('underneath-wheel') end
    underneath.layout = {geometry = {x = anchor.layout.geometry.x, y = anchor.layout.geometry.y,
        an = 5, w = 200, h = 24}, layer = 51, alpha = {0, 255, 255, 255}, style = ''}
    prepare_elements(); hover_row(popup, 4)
    local body, bg = popup.body, popup.background
    same_box(bg.hitbox, body)
    eq(bg.layout.geometry.w, body.x2 - body.x1); eq(bg.layout.geometry.h, body.y2 - body.y1)
    eq(bg.style_ass.positions[1][1], body.x1); eq(bg.style_ass.positions[1][2], body.y1)
    -- The prepared rounded shape includes the expanded height, not the old 160px cache.
    eq(bg.static_ass.shapes[1][4], body.y2 - body.y1, 'cached background includes footer')
    assert(bg.static_ass.shapes[1][4] > 160)
    mouse_x, mouse_y = anchor.layout.geometry.x, anchor.layout.geometry.y
    process_event('mouse_move')
    eq(mouse_hit(anchor), false, 'covered anchor cannot respond'); eq(mouse_hit(underneath), false)
    process_event('mbtn_left', 'down'); process_event('mbtn_left', 'up'); process_event('wheel_up', 'press')
    eq(#commands, 0, 'footer captures clicks without triggering controls underneath')
    eq(state.popover, 'enhancement'); eq(areas.input_wheel[3], 0)
    assert(popup.region.x1 <= body.x1 and popup.region.x2 >= body.x2 and popup.region.y2 >= body.y2)
end

function long_reason_wraps_and_narrow_canvas_stays_inside()
    for _, size in ipairs({{1280, 720}, {320, 300}, {180, 360}, {96, 500}}) do
        osc_param.playresx, osc_param.playresy = size[1], size[2]
        local _, popup = fixture({ready = true, available = {}, unavailable_reasons = {ANIME_STRONG = 'anime_unverified'}}, 120)
        hover_row(popup, 5)
        local geometry = assert(popup.footer)
        assert(popup.body.x1 >= 8 and popup.body.x2 <= size[1] - 8)
        assert(popup.body.y1 >= 8 and popup.body.y2 <= size[2] - 8)
        for _, line in ipairs(geometry.lines) do assert(estimate_text_width(line) <= geometry.width - 20) end
        has(table.concat(geometry.lines, ''):gsub(' ', ''), 'Validationrequired')
        if size[1] == 96 then assert(#geometry.lines > 1, 'narrow footer wraps') end
        same_box(popup.background.hitbox, popup.body)
    end
end

function short_canvas_does_not_move_rows_to_fit_footer()
    osc_param.playresx, osc_param.playresy = 180, 220
    local _, popup = fixture({ready = true, available = {}, unavailable_reasons = {ANIME_STRONG = 'anime_unverified'}}, 20)
    local box = copy_box(popup.enhancement_rows[5].element.hitbox)
    hover_row(popup, 5); eq(popup.footer, nil, 'insufficient footer space safely omitted')
    same_box(popup.enhancement_rows[5].element.hitbox, box); same_box(popup.body, popup.rows_body)
    osc_param.playresx, osc_param.playresy = 30, 30
    local _, missing_popup = fixture({ready = false, available = {}})
    eq(missing_popup, nil, 'impossible panel is omitted')
end

function legacy_fields_and_failure_reason()
    local _, popup = fixture({desired = 'SMOOTH', applied = 'QUALITY', available = {QUALITY = true}})
    eq(popup.footer, nil, 'unavailable desired state does not add a normal disclosure')
    hover_row(popup, 3); has(select(2, render_footer()), 'Unavailable')
    state.enhancement = {ready = false}; popup.update(); has(select(2, render_footer()), 'Initializing')
    state.enhancement = {desired = 'QUALITY', available = {QUALITY = true}, error_reason = 'rollback_failed',
        error_preset = 'SMOOTH', error = '{untrusted raw host error}'}
    popup.update(); local _, text = render_footer(); has(text, 'Rollback failed')
    assert(not text:find('untrusted', 1, true), 'raw error is not rendered as ASS')
    hover_row(popup, 2); has(select(2, render_footer()), 'Rollback failed')
    state.enhancement = {available = {QUALITY = true}, error = '{raw error}'}
    popup.update(); has(select(2, render_footer()), 'Settings failed')
end

function status_observer_is_silent_and_updates_rows()
    local _, popup = fixture({ready = false, available = {}})
    observers['user-data/mpvnet/enhancement']('', {desired = 'QUALITY', applied = 'QUALITY',
        available = {QUALITY = true}, error_reason = 'settings_failed', error_preset = 'QUALITY'})
    eq(popup.enhancement_rows[2].element.enabled, true); eq(#commands, 0); eq(ticks, 1)
    has(select(2, render_footer()), 'Settings failed')
    observers['user-data/mpvnet/enhancement']('', nil)
    eq(popup.enhancement_rows[2].element.enabled, false); eq(#commands, 0); eq(ticks, 2); eq(popup.footer, nil)
end

function footer_respects_close_hide_other_panel_and_fade()
    local _, popup = fixture({ready = true, available = {OFF = true}, error_reason = 'settings_failed'})
    state.animation = 255
    has(select(2, render_footer()), '\\1a&HFF&', 'footer uses existing OSC alpha')
    state.osc_visible = false; popup.update(); eq(popup.footer, nil); eq(#render_footer().text, 0)
    state.osc_visible = true; popup.update(); assert(popup.footer)
    state.popover = 'speed'; popup.update(); eq(popup.footer, nil); eq(#render_footer().text, 0)
    state.popover = 'enhancement'; user_opts.tooltip_hints = false; popup.update(); eq(popup.footer, nil)
    user_opts.tooltip_hints = true; popup.update(); assert(popup.footer)
    close_popover(); popup.update(); eq(popup.footer, nil); same_box(popup.body, popup.rows_body)
    eq(#render_footer().text, 0)
end
