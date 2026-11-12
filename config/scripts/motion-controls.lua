-- Instance selection, with a fresh pair of file-local options for each media item.
local mp = require('mp')
local msg = require('mp.msg')
local feedback = dofile(mp.command_native({'expand-path', '~~/script-modules/feedback.lua'})).new(mp)
local settings = dofile(mp.command_native({'expand-path', '~~/script-modules/user-settings.lua'}))

local property = 'user-data/mpvnet/motion'
local field = settings.field('motion.default-mode')
local labels = {}
for _, choice in ipairs(field.choices) do labels[choice.value] = choice.label end
local keys = {'video-sync', 'interpolation'}
local option_types = {['video-sync'] = 'string', interpolation = 'boolean'}
local modes = {
    DISPLAY = {['video-sync'] = 'display-resample', interpolation = false},
    BLEND = {['video-sync'] = 'display-resample', interpolation = true},
}
local reason_text = {
    initializing = '运动模式尚未就绪', no_video = '当前没有可用的视频',
    renderer_unsupported = '当前显示方式不支持此运动模式',
    read_failed = '无法读取运动设置', write_failed = '无法应用运动设置',
    rollback_failed = '运动设置还原失败', unavailable = '此运动模式不可用',
    options_changed = '运动设置已被其他操作修改',
}

local startup_mode, manually_selected = field.default, false
local desired, applied, baseline = startup_mode, nil, nil
local ready, last_error, error_reason, error_mode = false, nil, nil, nil
local motion_was_available = false

local function snapshot()
    local result = {}
    for _, key in ipairs(keys) do
        local value, err = mp.get_property_native('options/' .. key)
        if type(value) ~= option_types[key] then return nil, key .. ': ' .. tostring(err or 'unexpected value') end
        result[key] = value
    end
    return result
end

local function availability()
    local track = mp.get_property_native('current-tracks/video')
    local no_video = type(track) ~= 'table' or track.image == true or track.albumart == true
    local base_reason, motion_reason
    if not ready then
        base_reason = error_reason == 'read_failed' and 'read_failed' or 'initializing'
        motion_reason = base_reason
    elseif no_video then
        motion_reason = 'no_video'
    else
        local vo = mp.get_property('current-vo')
        if vo ~= 'gpu' and vo ~= 'gpu-next' then motion_reason = 'renderer_unsupported' end
    end
    return {OFF = ready, DISPLAY = motion_reason == nil, BLEND = motion_reason == nil},
        {OFF = base_reason, DISPLAY = motion_reason, BLEND = motion_reason}
end

local function publish()
    local available, reasons = availability()
    mp.set_property_native(property, {
        desired = desired, applied = applied, ready = ready, available = available,
        unavailable_reasons = reasons, error = last_error, error_reason = error_reason, error_mode = error_mode,
        display_sync_active = mp.get_property_native('display-sync-active'),
    })
end

-- Setter success alone does not prove the option pair took effect. When
-- restoring, try both properties even if one setter reports an error.
local function write_group(values, current, restoring)
    local write_error
    for _, key in ipairs(keys) do
        if not current or current[key] ~= values[key] then
            local ok, err = mp.set_property_native('file-local-options/' .. key, values[key])
            if not ok then
                write_error = write_error or (key .. ': ' .. tostring(err))
                if not restoring then break end
            end
        end
    end
    local actual, read_error = snapshot()
    if not actual then return false, write_error or read_error end
    for _, key in ipairs(keys) do
        if actual[key] ~= values[key] then return false, write_error or (key .. ': readback differs'), actual end
    end
    if write_error and not restoring then return false, write_error, actual end
    return true
end

local function fail(name, reason, detail, quiet)
    last_error, error_reason, error_mode = detail or reason_text[reason], reason, name
    if detail then msg.error(detail) end
    publish()
    if not quiet then feedback.show(reason_text[reason], 'error') end
    return false
end

local function apply(name, quiet)
    local available, reasons = availability()
    if not available[name] then return fail(name, reasons[name] or 'unavailable', nil, quiet) end
    local previous, err = snapshot()
    if not previous then return fail(name, 'read_failed', err, quiet) end
    local ok, actual
    ok, err, actual = write_group(modes[name] or baseline, previous)
    if not ok then
        local restored, restore_error = write_group(previous, actual, true)
        if restored then return fail(name, 'write_failed', err, quiet) end
        applied = nil
        return fail(name, 'rollback_failed', err .. '; rollback: ' .. restore_error, quiet)
    end
    applied, last_error, error_reason, error_mode = name, nil, nil, nil
    if not quiet then desired, manually_selected = name, true end
    publish()
    if not quiet then feedback.show(name == 'OFF' and '运动设置已还原' or ('已选择' .. labels[name]), 'success') end
    return true
end

local function refresh_availability(reconcile)
    local available, reasons = availability()
    local became_available = available.DISPLAY and not motion_was_available
    motion_was_available = available.DISPLAY
    if ready and desired ~= 'OFF' and not available[desired] then
        if applied and applied ~= 'OFF' then
            -- The active mode lost its video output. Try to restore the
            -- baseline without reinstalling an unsupported mode on failure.
            local restored, err = write_group(baseline, snapshot(), true)
            applied = restored and 'OFF' or nil
            if not restored then return fail(desired, 'rollback_failed', err, true) end
        end
        if applied == 'OFF' then return fail(desired, reasons[desired], nil, true) end
    elseif ready and desired ~= 'OFF' and applied == 'OFF' and (reconcile or became_available) then
        return apply(desired, true)
    end
    publish()
end

local function on_output_change()
    refresh_availability(false)
end

local function on_option_change()
    local expected = modes[applied]
    if not expected then return end
    -- Observer callbacks run after the current Lua transaction. Read both
    -- current values instead of using a possibly older notification value.
    local actual = snapshot()
    if not actual then return end
    for _, key in ipairs(keys) do
        if actual[key] ~= expected[key] then
            local previous = applied
            applied = nil
            fail(previous, 'options_changed', nil, true)
            return
        end
    end
end

mp.register_script_message('set-mode', function(name)
    name = tostring(name or ''):upper()
    if not labels[name] then return feedback.show(reason_text.unavailable, 'error') end
    apply(name, false)
end)

mp.register_event('start-file', function()
    baseline, applied, ready = nil, nil, false
    motion_was_available = false
    last_error, error_reason, error_mode = nil, nil, nil
    publish()
end)
mp.add_hook('on_preloaded', 100, function()
    baseline, last_error = snapshot()
    if not baseline then return fail(desired, 'read_failed', last_error, true) end
    publish()
end)
mp.register_event('file-loaded', function()
    ready = baseline ~= nil
    applied = ready and 'OFF' or nil
    refresh_availability(true)
end)
mp.observe_property('current-tracks/video', 'native', on_output_change)
mp.observe_property('current-vo', 'string', on_output_change)
mp.observe_property('display-sync-active', 'bool', publish)
for _, key in ipairs(keys) do mp.observe_property('options/' .. key, 'native', on_option_change) end
mp.register_event('end-file', function()
    -- mpv resets file-local options itself, including on stop or load error.
    baseline, applied, ready = nil, nil, false
    publish()
end)
mp.register_event('shutdown', function() mp.del_property(property) end)
publish()

settings.owner(mp, {
    id = field.id, initialize_on_ready = true, default_source = '套件默认继承原始运动设置',
    read = function() return startup_mode end,
    write = function(value)
        startup_mode = value
        if not manually_selected then
            desired = value
            refresh_availability(true)
        end
        return true
    end,
})
