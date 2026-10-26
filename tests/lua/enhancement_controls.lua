local properties = {['current-vo'] = 'gpu-next', ['video-params'] = {gamma = 'bt.1886', sigpeak = 1}, vid = 1}
local original = {scale = 'bilinear', dscale = 0, cscale = 0, ['scale-antiring'] = 0,
    deband = false, ['deband-iterations'] = 2, ['deband-threshold'] = 48,
    ['deband-range'] = 12, ['deband-grain'] = 3, ['glsl-shaders'] = {'baseline.glsl'}}
local events, hooks, observers, script_messages = {}, {}, {}, {}
local writes, messages, failures, missing_shaders = {}, {}, {}, {}
local read_failure, verified = nil, true
local function copy(value)
    if type(value) ~= 'table' then return value end
    local result = {}; for key, entry in pairs(value) do result[key] = copy(entry) end; return result
end
for key, value in pairs(original) do properties['options/' .. key] = copy(value) end
local host = {
    get_property = function(name) return properties[name] end,
    get_property_native = function(name)
        if name == read_failure then return nil, 'injected read failure' end
        return copy(properties[name])
    end,
    set_property_native = function(name, value)
        if name:find('file-local-options/', 1, true) == 1 then
            writes[#writes + 1] = {name, copy(value)}
            if (failures[name] or 0) > 0 then failures[name] = failures[name] - 1; return false, 'injected write failure' end
            local key = name:sub(#'file-local-options/' + 1)
            properties['options/' .. key] = copy(value)
        else properties[name] = copy(value) end
        return true
    end,
    command_native = function(args) assert(args[1] == 'expand-path'); return args[2] end,
    osd_message = function(text, duration) messages[#messages + 1] = {text, duration} end,
    register_event = function(name, callback) events[name] = callback end,
    add_hook = function(name, _, callback) hooks[name] = callback end,
    observe_property = function(name, _, callback) observers[name] = callback end,
    register_script_message = function(name, callback) script_messages[name] = callback end,
    enable_messages = function() end,
    del_property = function(name) properties[name] = nil end,
}
package.preload['mp'] = function() return host end
package.preload['mp.utils'] = function() return {file_info = function(path)
    if not missing_shaders[path:match('[^/]+$')] then return {is_file = true} end
end} end
package.preload['mp.options'] = function() return {read_options = function(value) value.anime_verified = verified end} end
package.preload['mp.msg'] = function() return {error = function() end} end

-- COMPLETE SOURCE IS INSERTED HERE

local function eq(actual, expected, label)
    assert(actual == expected, (label or 'value') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
end
local function current() return properties['user-data/mpvnet/enhancement'] end
local function load_file(params, vo, new_baseline)
    events['start-file']()
    for key, value in pairs(new_baseline or original) do properties['options/' .. key] = copy(value) end
    properties['video-params'], properties['current-vo'] = params or {gamma = 'bt.1886'}, vo or 'gpu-next'
    hooks.on_preloaded(); events['file-loaded']()
end
local function select(name) script_messages['set-preset'](name) end
local function change(name, value) properties[name] = value; observers[name](name, value) end
local function reason(name) return current().unavailable_reasons[name] end
local function check_message(text)
    eq(messages[#messages][1], 'ENHANCEMENT: ' .. text); eq(messages[#messages][2], 1, 'one-second plain-text OSD')
end

function initialization_and_no_video_reasons()
    eq(reason('QUALITY'), 'initializing'); eq(#messages, 0)
    properties['idle-active'] = true; change('current-vo', '')
    eq(reason('QUALITY'), 'no_video')
    properties['idle-active'] = false; load_file(nil, 'direct3d')
    eq(current().available.OFF, true); eq(reason('QUALITY'), 'renderer_unsupported')
    properties.vid = false; change('current-vo', '')
    eq(reason('QUALITY'), 'no_video')
end

function sdr_settings_and_explicit_feedback()
    load_file()
    for name in pairs(labels) do eq(current().available[name], true, name .. ' SDR availability') end
    select('QUALITY')
    eq(current().desired, 'QUALITY'); eq(current().applied, 'QUALITY'); eq(current().applied_scope, 'options')
    eq(properties['options/scale'], 'ewa_lanczos'); eq(properties['options/deband'], false)
    eq(properties['options/deband-grain'], 3, 'preserve baseline when disabled')
    check_message('SCALING SETTINGS APPLIED')
    select('SMOOTH'); eq(properties['options/deband'], true); eq(properties['options/deband-threshold'], 32)
    select('OFF'); eq(current().desired, 'OFF'); eq(properties['options/scale'], original.scale)
    eq(properties['options/dscale'], '', 'native scaler inherit uses registered setter name')
    eq(properties['options/glsl-shaders'][1], 'baseline.glsl')
end

function hdr_and_unknown_metadata()
    for _, params in ipairs({{gamma = 'pq'}, {gamma = 'hlg'}, {gamma = 'st2084'}, {gamma = 'bt.1886', sigpeak = 2}}) do
        load_file(params); eq(reason('ANIME_LIGHT'), 'hdr_source'); eq(current().available.QUALITY, true)
        local count = #writes; select('ANIME_LIGHT'); eq(#writes, count)
        eq(current().desired, 'OFF'); eq(current().applied, 'OFF'); check_message('HDR SOURCE')
    end
    for _, params in ipairs({{}, {gamma = 'auto'}}) do
        load_file(params); eq(reason('ANIME_LIGHT'), 'metadata_unknown')
        select('ANIME_LIGHT'); check_message('SOURCE METADATA UNKNOWN')
    end
    properties['video-params'] = nil; observers['video-params']()
    eq(reason('ANIME_LIGHT'), 'no_video')
end

function validation_and_shader_gates()
    opts.anime_verified = false; load_file(); eq(reason('ANIME_LIGHT'), 'anime_unverified')
    select('ANIME_LIGHT'); check_message('ANIME VALIDATION NOT ENABLED')
    opts.anime_verified = true; missing_shaders['Anime4K_Restore_CNN_VL.glsl'] = true
    change('video-params', {gamma = 'bt.1886'})
    eq(current().available.ANIME_LIGHT, true); eq(reason('ANIME_STRONG'), 'shader_missing')
    select('ANIME_STRONG'); check_message('SHADER MISSING')
end

function failed_write_restores_previous_settings()
    load_file(); select('QUALITY')
    failures['file-local-options/deband'] = 1
    select('SMOOTH')
    eq(current().desired, 'QUALITY'); eq(current().applied, 'QUALITY')
    eq(current().error_reason, 'settings_failed'); eq(current().error_preset, 'SMOOTH')
    eq(properties['options/deband'], false); eq(properties['options/scale'], 'ewa_lanczos')
    check_message('SETTINGS FAILED')
    select('SMOOTH'); eq(current().error_reason, nil); eq(current().desired, 'SMOOTH')
end

function snapshot_and_rollback_failures()
    load_file(); read_failure = 'options/scale'; select('QUALITY')
    eq(current().error_reason, 'settings_failed'); eq(current().desired, 'OFF'); eq(#writes, 0)
    read_failure = nil; failures['file-local-options/deband'] = 2; select('SMOOTH')
    eq(current().error_reason, 'rollback_failed'); eq(current().applied, nil); eq(current().desired, 'OFF')
    check_message('ROLLBACK FAILED')
    read_failure = 'options/scale'; load_file(); eq(current().ready, false)
    eq(reason('OFF'), 'settings_failed'); eq(current().applied, nil)
end

function cross_media_keeps_choice_and_rechecks_gates()
    load_file(); select('ANIME_LIGHT'); local count = #messages
    local next_baseline = copy(original); next_baseline.scale = 'spline36'
    load_file({gamma = 'pq'}, nil, next_baseline)
    eq(current().desired, 'ANIME_LIGHT'); eq(current().applied, 'OFF'); eq(reason('ANIME_LIGHT'), 'hdr_source')
    eq(properties['options/scale'], 'spline36'); eq(#messages, count, 'media transition is silent')
    change('video-params', {gamma = 'bt.1886'})
    eq(current().desired, 'ANIME_LIGHT'); eq(current().applied, 'ANIME_LIGHT'); eq(#messages, count)
    select('OFF'); eq(properties['options/scale'], 'spline36', 'restore current media baseline')
    events['end-file'](); eq(current().ready, false); eq(current().applied, nil)
end

function renderer_loss_and_recovery_are_silent()
    load_file(); select('QUALITY'); local count = #messages
    change('current-vo', 'direct3d')
    eq(current().desired, 'QUALITY'); eq(current().applied, 'OFF'); eq(current().error_reason, 'renderer_unsupported')
    eq(#messages, count)
    change('current-vo', 'gpu'); eq(current().applied, 'QUALITY'); eq(current().error_reason, nil)
    eq(#messages, count)
    select('ANIME_LIGHT'); count = #messages
    change('video-params', {gamma = 'pq'})
    eq(current().error_reason, 'hdr_source'); eq(current().applied, 'OFF'); eq(#messages, count)
end

function renderer_error_and_lifecycle()
    load_file(); select('ANIME_LIGHT')
    events['log-message']({level = 'error', prefix = 'vo/gpu-next', text = 'shader compile failed'})
    eq(current().desired, 'OFF'); eq(current().applied, 'OFF'); eq(current().error_reason, 'renderer_error')
    check_message('RENDERER ERROR')
    local count, write_count = #messages, #writes
    events['end-file'](); eq(#messages, count); eq(#writes, write_count)
    events['start-file'](); eq(current().error_reason, nil)
    events.shutdown(); eq(current(), nil); eq(#messages, count)
end
