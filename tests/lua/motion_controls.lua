local properties = {['current-vo'] = 'gpu-next', ['current-tracks/video'] = {id = 1}}
local events, hooks, observers, script_messages = {}, {}, {}, {}
local writes, messages, log_errors = {}, {}, {}
local read_failure, write_override, file_loaded = nil, nil, false
local owned = {['video-sync'] = true, interpolation = true}
local host = {
    get_property = function(name) return properties[name] end,
    get_property_native = function(name)
        if name == read_failure then return nil, 'injected read failure' end
        return properties[name]
    end,
    set_property_native = function(name, value)
        local key = name:match('^file%-local%-options/(.+)$')
        if key then
            assert(file_loaded and owned[key], 'unexpected write: ' .. name)
            writes[#writes + 1] = {key, value}
            if write_override then
                local ok, err = write_override(key, value)
                if ok ~= nil then return ok, err end
            end
            properties['options/' .. key] = value
        else
            assert(name:match('^user%-data/'), 'unexpected write: ' .. name)
            properties[name] = value
        end
        return true
    end,
    command_native = function(args) assert(args[1] == 'expand-path'); return args[2] end,
    osd_message = function(text, duration) messages[#messages + 1] = {text, duration} end,
    register_event = function(name, callback)
        local previous = events[name]
        events[name] = function(...)
            if previous then previous(...) end
            callback(...)
        end
    end,
    add_hook = function(name, _, callback) hooks[name] = callback end,
    observe_property = function(name, _, callback) observers[name] = callback end,
    register_script_message = function(name, callback) script_messages[name] = callback end,
    del_property = function(name) properties[name] = nil end,
}
package.preload['mp'] = function() return host end
package.preload['mp.msg'] = function()
    return {error = function(detail) log_errors[#log_errors + 1] = detail end}
end
local settings_model = (function()
-- SETTINGS MODEL IS INSERTED HERE
end)()
local function dofile(path)
    if path == '~~/script-modules/feedback.lua' then return feedback_module end
    if path == '~~/script-modules/user-settings.lua' then return settings_model end
    error('unexpected dofile ' .. path)
end

-- COMPLETE SOURCE IS INSERTED HERE

local function eq(actual, expected, label)
    assert(actual == expected, (label or 'value') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
end
local function current() return properties['user-data/mpvnet/motion'] end
local function change(name, value)
    properties[name] = value
    observers[name](name, value)
end
local function prepare_file(sync, blend, video, renderer)
    file_loaded = false
    events['start-file']()
    properties['options/video-sync'] = sync
    properties['options/interpolation'] = blend
    properties['current-vo'] = renderer
    properties['current-tracks/video'] = video
    properties['display-sync-active'] = false
    hooks.on_preloaded()
end
local function finish_load()
    file_loaded = true
    events['file-loaded']()
end
local function load_video(sync, blend)
    prepare_file(sync or 'audio', blend == true, {id = 1}, 'gpu-next')
    finish_load()
end
local function select(name) script_messages['set-mode'](name) end
local function check_options(sync, blend)
    eq(properties['options/video-sync'], sync, 'actual video-sync')
    eq(properties['options/interpolation'], blend, 'actual interpolation')
end
local function check_message(text, duration)
    eq(messages[#messages][1], text)
    eq(messages[#messages][2], duration or 4, 'feedback duration')
end
local setting_id = 'motion.default-mode'
local function sync_settings(startup, saved)
    change('user-data/mpvnet/settings-values', {schema = 1,
        startup = startup, values = {[setting_id] = saved}})
    return properties['user-data/mpvnet/settings-runtime/' .. setting_id]
end

function only_two_options_and_per_media_restore()
    properties['options/hwdec'] = 'auto-safe'
    properties['options/tscale'] = 'oversample'
    properties['options/audio-delay'] = 0.2
    prepare_file('display-vdrop', true, {id = 1}, 'gpu-next')
    eq(current().ready, false); eq(current().applied, nil)
    select('BLEND'); check_message('运动模式尚未就绪'); eq(#writes, 0)
    finish_load()
    eq(current().ready, true); eq(current().applied, 'OFF'); eq(#writes, 0)
    check_options('display-vdrop', true)

    select('DISPLAY'); check_options('display-resample', false)
    eq(current().applied, 'DISPLAY'); eq(current().desired, 'DISPLAY')
    check_message('已选择显示同步', 2)
    select('BLEND'); check_options('display-resample', true)
    check_message('已选择显示同步与帧混合', 2)
    local feedback_count, write_count = #messages, #writes
    events['end-file']()
    eq(current().ready, false); eq(current().applied, nil)
    eq(current().desired, 'BLEND'); eq(#writes, write_count)

    load_video('desync', false)
    eq(current().applied, 'BLEND'); check_options('display-resample', true)
    eq(#messages, feedback_count, 'silent file transition')
    select('OFF'); check_options('desync', false)
    check_message('运动设置已还原', 2)
    eq(properties['options/hwdec'], 'auto-safe')
    eq(properties['options/tscale'], 'oversample')
    eq(properties['options/audio-delay'], 0.2)
    events.shutdown(); eq(current(), nil)
end

function startup_consumes_first_read_and_save_waits()
    local seed = {available = true, values = {[setting_id] = 'BLEND'}}
    prepare_file('audio', false, {id = 1}, 'gpu-next')
    local runtime = sync_settings(seed, 'DISPLAY')
    eq(runtime.effective, 'BLEND'); eq(runtime.saved, 'DISPLAY'); eq(runtime.status, 'pending-startup')
    eq(current().desired, 'BLEND'); eq(current().applied, nil); eq(#writes, 0)
    finish_load()
    eq(current().applied, 'BLEND'); check_options('display-resample', true)

    select('DISPLAY')
    local write_count = #writes
    runtime = sync_settings(seed, 'OFF')
    eq(runtime.effective, 'BLEND'); eq(runtime.saved, 'OFF'); eq(#writes, write_count)
    eq(current().desired, 'DISPLAY'); check_options('display-resample', false)
    load_video()
    eq(current().applied, 'DISPLAY'); check_options('display-resample', false)
end

function late_startup_respects_successful_manual_choice()
    load_video()
    select('OFF')
    local runtime = sync_settings({available = true, values = {[setting_id] = 'BLEND'}}, 'BLEND')
    eq(runtime.effective, 'BLEND'); eq(current().desired, 'OFF'); eq(current().applied, 'OFF')
    eq(#writes, 0)
    load_video(); check_options('audio', false)
end

function late_startup_recovers_from_unavailable_media()
    prepare_file('audio', false, nil, 'gpu-next'); finish_load()
    select('DISPLAY')
    check_message('当前没有可用的视频')
    eq(current().desired, 'OFF'); eq(#writes, 0)
    sync_settings({available = true, values = {[setting_id] = 'BLEND'}}, 'BLEND')
    eq(current().desired, 'BLEND'); eq(current().applied, 'OFF'); eq(#writes, 0)
    load_video()
    eq(current().applied, 'BLEND'); check_options('display-resample', true)
    eq(#messages, 1, 'automatic startup selection stays silent')
end

function unavailable_output_restores_and_recovers()
    load_video(); select('BLEND')
    change('current-vo', 'direct3d')
    eq(current().available.BLEND, false); eq(current().available.OFF, true)
    eq(current().error_reason, 'renderer_unsupported')
    eq(current().desired, 'BLEND'); eq(current().applied, 'OFF'); check_options('audio', false)
    select('DISPLAY'); check_message('当前显示方式不支持此运动模式')
    eq(current().desired, 'BLEND')
    change('current-vo', 'gpu')
    eq(current().applied, 'BLEND'); check_options('display-resample', true)

    change('current-tracks/video', {id = 2, image = true, albumart = true})
    eq(current().available.DISPLAY, false); eq(current().error_reason, 'no_video')
    eq(current().desired, 'BLEND'); eq(current().applied, 'OFF'); check_options('audio', false)
    change('current-tracks/video', nil)
    eq(current().available.BLEND, false)
    change('current-tracks/video', {id = 1})
    eq(current().applied, 'BLEND'); check_options('display-resample', true)
    eq(#messages, 2, 'output changes are silent')

    prepare_file('audio', false, nil, nil); finish_load()
    eq(current().available.OFF, true)
    select('OFF'); eq(current().desired, 'OFF'); check_message('运动设置已还原', 2)
end

function display_sync_status_comes_from_core()
    load_video('display-resample', true)
    change('display-sync-active', true)
    eq(current().display_sync_active, true); eq(current().applied, 'OFF')
    select('BLEND')
    local write_count = #writes
    change('display-sync-active', false)
    eq(current().display_sync_active, false); eq(current().applied, 'BLEND')
    check_options('display-resample', true)
    change('display-sync-active', nil)
    eq(current().display_sync_active, nil); eq(#writes, write_count)
end

function failed_write_and_readback_restore_previous_pair()
    load_video()
    write_override = function(key, value)
        if key == 'interpolation' and value then return false, 'injected setter failure' end
    end
    select('BLEND'); check_options('audio', false)
    eq(current().error_reason, 'write_failed'); eq(current().desired, 'OFF'); eq(current().applied, 'OFF')
    eq(#writes, 3); check_message('无法应用运动设置')

    write_override = function(key, value)
        if key == 'interpolation' and value then return true end -- Setter accepts but readback differs.
    end
    select('BLEND'); check_options('audio', false)
    eq(current().error_reason, 'write_failed'); eq(current().error_mode, 'BLEND')
    assert(current().error:find('readback differs', 1, true))
    write_override = nil
    select('BLEND'); check_options('display-resample', true)
    eq(current().error, nil); eq(current().desired, 'BLEND'); eq(current().applied, 'BLEND')
end

function failed_rollback_reports_unknown_and_can_recover()
    load_video()
    write_override = function(key, value)
        if key == 'interpolation' and value or key == 'video-sync' and value == 'audio' then
            return false, 'injected failure'
        end
    end
    select('BLEND'); check_options('display-resample', false)
    eq(current().error_reason, 'rollback_failed'); eq(current().desired, 'OFF'); eq(current().applied, nil)
    check_message('运动设置还原失败')
    write_override = nil
    select('OFF'); check_options('audio', false)
    eq(current().error, nil); eq(current().applied, 'OFF')

    select('BLEND')
    write_override = function(key)
        if key == 'video-sync' then return false, 'injected restore failure' end
    end
    change('current-tracks/video', nil)
    check_options('display-resample', false)
    eq(current().error_reason, 'rollback_failed'); eq(current().applied, nil); eq(current().desired, 'BLEND')
end

function failed_reads_never_claim_success()
    read_failure = 'options/video-sync'
    load_video()
    eq(current().available.OFF, false); eq(current().applied, nil)
    select('DISPLAY'); check_message('无法读取运动设置'); eq(#writes, 0)
    read_failure = nil
    load_video()
    eq(current().available.OFF, true)
    read_failure = 'options/interpolation'
    select('DISPLAY'); check_message('无法读取运动设置'); eq(#writes, 0)
    eq(current().desired, 'OFF'); eq(current().applied, 'OFF')
    eq(current().error_reason, 'read_failed'); eq(#log_errors, 2)
end

function automatic_write_retries_only_when_eligible_again()
    sync_settings({available = true, values = {[setting_id] = 'DISPLAY'}}, 'DISPLAY')
    write_override = function() return false, 'injected failure' end
    load_video()
    eq(current().applied, 'OFF'); eq(current().error_reason, 'write_failed'); eq(#writes, 1)
    change('current-tracks/video', {id = 2})
    eq(#writes, 1)
    change('current-vo', nil)
    write_override = nil
    change('current-vo', 'gpu')
    eq(current().applied, 'DISPLAY'); check_options('display-resample', false)
end

function external_option_change_clears_applied_without_writing()
    load_video(); select('BLEND')
    observers['options/video-sync']('options/video-sync', 'audio') -- Queued value is already stale.
    eq(current().applied, 'BLEND')
    local write_count = #writes
    change('options/interpolation', false)
    eq(current().desired, 'BLEND'); eq(current().applied, nil)
    eq(current().error_reason, 'options_changed')
    change('current-vo', 'direct3d'); change('current-vo', 'gpu')
    check_options('display-resample', false)
    eq(#writes, write_count); eq(#messages, 1)
    load_video()
    eq(current().applied, 'BLEND'); check_options('display-resample', true)
end

function external_option_change_survives_output_observer_arriving_first()
    load_video(); select('BLEND')
    local write_count = #writes
    properties['options/interpolation'] = false -- Option notification still queued.
    change('current-vo', 'direct3d')
    observers['options/interpolation']('options/interpolation', false)
    change('current-vo', 'gpu')
    eq(current().error_reason, 'options_changed'); eq(current().applied, nil)
    eq(current().desired, 'BLEND'); eq(#writes, write_count)
    check_options('display-resample', false)
end

function output_loss_does_not_restore_without_reading_current_options()
    load_video(); select('BLEND')
    local write_count = #writes
    read_failure = 'options/interpolation'
    change('current-vo', 'direct3d')
    eq(current().error_reason, 'read_failed'); eq(current().applied, nil)
    eq(current().desired, 'BLEND'); eq(#writes, write_count)
end
