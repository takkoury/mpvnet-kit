local tag = 'mpvnet-night-audio'
local properties = {af = {}, ['audio-params'] = nil, ['audio-out-params'] = nil}
local events, hooks, observers, messages, calls, timers = {}, {}, {}, {}, {}, {}
local read_failure, add_failure, remove_failure, read_fail_after_add = false, nil, false, false
local function copy(v)
    if type(v) ~= 'table' then return v end
    local out = {}; for k, value in pairs(v) do out[k] = copy(value) end; return out
end
local function original_filter(label)
    return {label = label or 'user-volume', name = 'volume', enabled = true, params = {volume = '0.8'}}
end
local host = {
    get_property_native = function(name)
        if name == 'af' and read_failure then return nil, 'injected read failure' end
        return copy(properties[name])
    end,
    set_property_native = function(name, value)
        assert(name:match('^user%-data/'), 'must not replace a complete option: ' .. name)
        properties[name] = copy(value); return true
    end,
    command_native = function(args) assert(args[1] == 'expand-path'); return args[2] end,
    commandv = function(command, operation, argument)
        assert(command == 'af', 'unexpected command')
        calls[#calls + 1] = {operation, argument}
        if operation == 'add' then
            if add_failure == 'before' then return false, 'injected add failure' end
            local prefix = '@' .. tag .. ':lavfi=['
            assert(argument:sub(1, #prefix) == prefix, argument)
            for _, f in ipairs(properties.af) do assert(f.label ~= tag, 'must not replace a foreign label') end
            properties.af[#properties.af + 1] = {label = tag, name = 'lavfi', enabled = true,
                params = {graph = argument:match('lavfi=%[(.*)%]$')}}
            if read_fail_after_add then read_failure = true end
            if add_failure == 'after' then return false, 'injected partial failure' end
            return true
        end
        assert(operation == 'remove' and argument == '@' .. tag)
        if remove_failure then return false, 'injected remove failure' end
        for i = #properties.af, 1, -1 do if properties.af[i].label == tag then table.remove(properties.af, i) end end
        return true
    end,
    osd_message = function(text, duration) messages[#messages + 1] = {text, duration} end,
    register_script_message = function(name, callback) messages[name] = callback end,
    register_event = function(name, callback)
        events[name] = events[name] or {}; table.insert(events[name], callback)
    end,
    add_hook = function(name, _, callback) hooks[name] = hooks[name] or {}; table.insert(hooks[name], callback) end,
    observe_property = function(name, _, callback) observers[name] = callback end,
    unobserve_property = function(callback)
        for key, value in pairs(observers) do if value == callback then observers[key] = nil end end
    end,
    add_periodic_timer = function(_, callback)
        local timer = {callback = callback, active = true, kill = function(self) self.active = false end}
        timers[#timers+1] = timer; return timer
    end,
    del_property = function(name) properties[name] = nil end,
}
package.preload['mp'] = function() return host end
package.preload['mp.msg'] = function() return {error = function() end} end
local settings_model = (function()
-- SETTINGS MODEL IS INSERTED HERE
end)()
local function dofile(path)
    if path == '~~/script-modules/feedback.lua' then return feedback_module end
    if path == '~~/script-modules/user-settings.lua' then return settings_model end
    error(path)
end

-- COMPLETE SOURCE IS INSERTED HERE

local function eq(a,b,message) assert(a==b,(message or 'value')..': '..tostring(a)..' ~= '..tostring(b)) end
local function state() return properties['user-data/mpvnet/audio'] end
local function event(name) for _, fn in ipairs(events[name] or {}) do fn() end end
local function hook(name) for _, fn in ipairs(hooks[name] or {}) do fn() end end
local function select(mode) messages['set-mode'](mode) end
local function notice() return messages[#messages] and messages[#messages][1] end
local function audio(channels, format)
    properties['current-tracks/audio'] = channels and {id=1} or nil
    properties['audio-params'] = channels and {['channel-count']=channels,format=format or 's32'} or nil
    properties['audio-out-params'] = channels and {['channel-count']=channels,format=format or 'float'} or nil
end
local function load(channels, format)
    hook('on_before_start_file');hook('on_load');audio(channels,format);event('file-loaded')
end
local function unload() hook('on_unload');event('end-file') end
local function changed() observers.af('af',copy(properties.af)) end
local function own_count()
    local n=0;for _,f in ipairs(properties.af) do if f.label==tag then n=n+1 end end;return n
end
local function sync(seed, saved)
    properties['user-data/mpvnet/settings-values']={schema=1,startup=seed,values={['audio.default-mode']=saved}}
    observers['user-data/mpvnet/settings-values']('user-data/mpvnet/settings-values',properties['user-data/mpvnet/settings-values'])
    return properties['user-data/mpvnet/settings-runtime/audio.default-mode']
end
function only_owned_filter_changes()
    properties.af={original_filter()};load(2)
    eq(#calls,0);eq(state().applied,'OFF');select('NIGHT')
    eq(own_count(),1);eq(state().applied,'NIGHT');eq(state().desired,'NIGHT')
    assert(properties.af[2].params.graph:find('mix=0.5',1,true))
    select('NIGHT');eq(own_count(),1);eq(#calls,1)
    properties.af[#properties.af+1]=original_filter('user-added-later');changed()
    select('OFF');eq(own_count(),0);eq(#properties.af,2)
    eq(properties.af[1].label,'user-volume');eq(properties.af[2].label,'user-added-later')
    eq(state().applied,'OFF');eq(state().desired,'OFF')
end
function eligibility_and_transients()
    properties.af={original_filter()};load(2);select('NIGHT');local count=#calls
    properties['audio-out-params']=nil;event('audio-reconfig');eq(#calls,count);eq(own_count(),1)
    audio(2);event('audio-reconfig');eq(#calls,count);eq(state().applied,'NIGHT')
    audio(6);event('audio-reconfig');eq(state().applied,'OFF');eq(own_count(),0);eq(state().desired,'NIGHT')
    eq(state().available.NIGHT,false);select('NIGHT');eq(state().desired,'NIGHT');eq(own_count(),0)
    audio(2);event('audio-reconfig');eq(state().applied,'NIGHT');eq(own_count(),1)
    audio(2,'spdif-ac3');event('audio-reconfig');eq(own_count(),0);eq(state().unavailable_reasons.NIGHT,'passthrough')
    audio(nil);event('audio-reconfig');eq(state().applied,nil);eq(state().available.NIGHT,false)
    audio(2);event('audio-reconfig');eq(state().applied,'NIGHT');eq(#properties.af,2)
end
function media_lifecycle()
    properties.af={original_filter()};load(2);select('NIGHT')
    properties.af[#properties.af+1]=original_filter('external');unload()
    eq(own_count(),0);eq(#properties.af,2);eq(state().applied,nil);eq(state().desired,'NIGHT')
    load(6);eq(own_count(),0);load(2);eq(own_count(),1)
    unload();eq(#properties.af,2);event('shutdown');eq(state(),nil)
end
function startup_snapshot()
    local seed={available=true,values={['audio.default-mode']='NIGHT'}}
    local runtime=sync(seed,'OFF');eq(runtime.effective,'NIGHT');load(2);eq(state().applied,'NIGHT')
    local count=#calls;runtime=sync(seed,'OFF');eq(#calls,count);eq(state().desired,'NIGHT')
    eq(runtime.saved,'OFF');eq(runtime.effective,'NIGHT')
    select('OFF');load(2);eq(state().applied,'OFF');eq(own_count(),0)
end
function late_startup()
    load(2);select('OFF');sync({available=true,values={['audio.default-mode']='NIGHT'}},'NIGHT')
    eq(state().desired,'OFF');eq(own_count(),0)
end
function foreign_label()
    properties.af={original_filter(tag)};load(2);local before=copy(properties.af)
    select('NIGHT');eq(#calls,0);eq(state().available.NIGHT,false)
    select('OFF');eq(#calls,0);unload();eq(#calls,0)
    eq(properties.af[1].params.volume,before[1].params.volume)
end
function external_changes()
    load(2);select('NIGHT');properties.af[1].enabled=false;changed();local count=#calls
    event('audio-reconfig');eq(#calls,count);eq(state().applied,nil);eq(properties.af[1].enabled,false)
    select('OFF');eq(#calls,count);eq(state().error_reason,'label_conflict')
    properties.af={};changed();event('audio-reconfig');eq(#calls,count);eq(own_count(),0)
    select('NIGHT');eq(own_count(),1);eq(state().applied,'NIGHT')
    properties.af={};event('audio-reconfig');eq(own_count(),0);changed();event('audio-reconfig');eq(own_count(),0)
    load(2);eq(own_count(),0);select('NIGHT');eq(own_count(),1)
end
function failed_add()
    properties.af={original_filter()};load(2);add_failure='before';select('NIGHT')
    eq(state().desired,'OFF');eq(own_count(),0);eq(#properties.af,1)
    add_failure='after';select('NIGHT');eq(own_count(),0);eq(#properties.af,1);eq(state().desired,'OFF')
    add_failure=nil;select('NIGHT');eq(own_count(),1)
end
function failed_remove()
    properties.af={original_filter()};load(2);select('NIGHT');remove_failure=true;select('OFF')
    eq(state().desired,'OFF');eq(own_count(),1);eq(state().error_reason,'restore_failed')
    remove_failure=false;select('OFF');eq(own_count(),0);eq(#properties.af,1);eq(state().applied,'OFF')
end
function readback_recovery()
    properties.af={original_filter()};load(2);read_fail_after_add=true;select('NIGHT')
    eq(state().applied,nil);read_failure=false;read_fail_after_add=false;changed()
    select('OFF');eq(own_count(),0);eq(#properties.af,1);eq(state().applied,'OFF')
end
function gapless_format_arrives_after_file_loaded()
    sync({available=true,values={['audio.default-mode']='NIGHT'}},'NIGHT')
    hook('on_load');audio(2);properties['audio-params']=nil;event('file-loaded')
    eq(own_count(),0);eq(state().applied,nil)
    audio(2);event('playback-restart');eq(own_count(),1);eq(state().applied,'NIGHT')
end
function synchronous_unload_precedes_next_profile_backup()
    properties.af={original_filter()};load(2);select('NIGHT')
    hook('on_unload');eq(own_count(),0)
    local next_backup=copy(properties.af)
    properties.af={original_filter('per-file-profile')}
    hook('on_load');event('end-file');audio(6);event('file-loaded');eq(own_count(),0)
    hook('on_unload');properties.af=next_backup
    load(2);eq(own_count(),1);select('OFF');eq(own_count(),0)
    eq(properties.af[1].label,'user-volume')
end
function switch_track_waits_for_the_new_decoder_format()
    load(2);select('NIGHT')
    properties['current-tracks/audio']={id=2,['demux-channel-count']=6}
    properties['audio-params']=nil
    observers['current-tracks/audio']()
    eq(own_count(),0);eq(state().available.NIGHT,false)
    properties['audio-params']={['channel-count']=2,format='float'}
    event('audio-reconfig');eq(own_count(),0,'source remains multichannel despite decoder downmix')
    properties['current-tracks/audio']={id=3,['demux-channel-count']=2}
    properties['audio-params']=nil;observers['current-tracks/audio']();eq(own_count(),0)
    properties['audio-params']={['channel-count']=2,format='float'}
    for _, timer in ipairs(timers) do if timer.active then timer.callback() end end
    eq(own_count(),1);eq(observers['time-pos'],nil)
    for _, timer in ipairs(timers) do eq(timer.active,false) end
end
function restored_managed_label_does_not_override_startup_default()
    properties.af={original_filter()};load(2);select('NIGHT')
    local saved=copy(properties.af)
    select('OFF');unload()
    hook('on_before_start_file')
    properties.af=copy(saved) -- core loads watch-later between these hooks
    hook('on_load');audio(2);event('file-loaded')
    eq(own_count(),0);eq(#properties.af,1);eq(state().desired,'OFF')
    properties.af=copy(saved) -- identical user entry that predates the next file is not reclaimed
    load(2);eq(own_count(),1);eq(state().applied,nil)
end
