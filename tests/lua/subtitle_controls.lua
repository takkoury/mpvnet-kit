-- Execute the full source; these doubles supply the mpv/input host only.
local bindings, binding_keys, forced, events = {}, {}, {}, {}
local messages, commands, writes = {}, {}, {}
local properties = {
    ['track-list'] = {{type='sub', id=1, title='Primary'},
        {type='sub', id=2, title='Bilibili Danmaku'}},
    sid=1, ['secondary-sid']=2, ['sub-delay']=0.7, ['sub-visibility']=true,
    ['sub-pos']=80, ['sub-scale']=1.25,
    ['user-data/mpvnet/subtitle-base-pos']=94,
}
local function get(name, default)
    if properties[name] ~= nil then return properties[name] end
    return default
end
local function set(name, value)
    writes[#writes+1]={name,value};properties[name]=value;return true
end
local mp = {
    get_property=get, get_property_native=get, get_property_number=get, get_property_bool=get,
    set_property=set, set_property_number=set, set_property_bool=set,
    osd_message=function(text, duration) messages[#messages+1]={text,duration} end,
    commandv=function(...) commands[#commands+1]={...} end,
    add_key_binding=function(key, name, fn) bindings[name]=fn;binding_keys[name]=key end,
    add_forced_key_binding=function(key, name, fn) forced[name]={key=key,fn=fn} end,
    remove_key_binding=function(name) forced[name]=nil end,
    register_event=function(name, fn) events[name]=fn end,
    msg={warn=function() end},
}
package.loaded['mp']=mp
package.loaded['mp.input']={select=function() error('unexpected subtitle selection') end}

-- COMPLETE SOURCE IS INSERTED HERE

local function eq(actual, expected)
    assert(actual==expected,'expected '..tostring(expected)..', got '..tostring(actual))
end
local function clear_output() messages,commands,writes={},{},{} end
local function unchanged_unrelated()
    eq(properties['sub-delay'],0.7);eq(properties['secondary-sid'],2)
    eq(properties['sub-visibility'],true)
    for _, write in ipairs(writes) do
        assert(write[1]=='sub-pos' or write[1]=='sub-scale','unexpected property write '..write[1])
    end
    for _, command in ipairs(commands) do
        eq(command[1],'script-message-to');eq(command[2],'modernz')
        assert(command[3]=='subtitle-adjust-position' or command[3]=='subtitle-adjust-reset')
    end
end
local function mode_on()
    eq(forced['adjust-up'].key,'UP');eq(forced['adjust-down'].key,'DOWN')
    eq(forced['adjust-larger'].key,'WHEEL_UP');eq(forced['adjust-smaller'].key,'WHEEL_DOWN')
end
local function mode_off() eq(next(forced),nil) end
local function move_and_scale()
    forced['adjust-up'].fn();forced['adjust-larger'].fn()
    eq(properties['sub-pos'],93);eq(properties['sub-scale'],1.3)
end
local function assert_reset(pos, scale)
    eq(properties['sub-pos'],pos);eq(properties['sub-scale'],scale);mode_off()
    eq(#commands,1);eq(#commands[1],4)
    eq(commands[1][1],'script-message-to');eq(commands[1][2],'modernz')
    eq(commands[1][3],'subtitle-adjust-reset');eq(commands[1][4],pos)
    eq(#writes,2);eq(writes[1][1],'sub-pos');eq(writes[2][1],'sub-scale')
    eq(#messages,1);eq(messages[1][1],'SUB ADJUST: RESET');eq(messages[1][2],1)
    unchanged_unrelated()
end
function repeated_entry_keeps_first_baseline()
    bindings['adjust-mode']();move_and_scale();bindings['adjust-mode']();mode_off()
    -- Off-mode changes affect working position, but cannot replace the first baseline.
    properties['sub-pos']=70;properties['sub-scale']=1.6
    properties['user-data/mpvnet/subtitle-base-pos']=70
    bindings['adjust-mode']();mode_on();forced['adjust-down'].fn()
    eq(properties['sub-pos'],71)
    clear_output();bindings['reset-adjustment']();assert_reset(94,1.25);eq(properties.sid,1)
end
function reset_inside_adjustment()
    eq(binding_keys['reset-adjustment'],nil)
    assert(bindings['reset-adjustment'],'reset script binding must be registered')
    bindings['adjust-mode']();mode_on();move_and_scale()
    local stale_key=forced['adjust-up'].fn
    clear_output();bindings['reset-adjustment']();assert_reset(94,1.25);eq(properties.sid,1)
    clear_output();stale_key();eq(#writes,0);eq(#commands,0);eq(#messages,0)
end
function reset_outside_adjustment_without_primary_track()
    bindings['adjust-mode']();move_and_scale();bindings['adjust-mode']()
    properties.sid='no';properties['track-list']={{type='sub',id=2,title='Bilibili Danmaku'}}
    clear_output();bindings['reset-adjustment']();assert_reset(94,1.25);eq(properties.sid,'no')
end
function no_record_does_not_write_properties()
    properties.sid='no';clear_output();bindings['reset-adjustment']()
    eq(properties['sub-pos'],80);eq(properties['sub-scale'],1.25);eq(properties.sid,'no')
    eq(#writes,0);eq(#commands,0);mode_off()
    eq(#messages,1);eq(messages[1][1],'SUB ADJUST: NO CHANGES');eq(messages[1][2],1)
    unchanged_unrelated()
end
function reentry_after_reset_captures_new_baseline()
    bindings['adjust-mode']();move_and_scale();bindings['reset-adjustment']()
    clear_output();bindings['reset-adjustment']();eq(#writes,0);eq(#commands,0)
    -- A later explicit adjustment starts a fresh temporary session.
    properties['sub-pos']=60;properties['user-data/mpvnet/subtitle-base-pos']=87
    properties['sub-scale']=0.9
    bindings['adjust-mode']();eq(properties['sub-pos'],87);mode_on()
    forced['adjust-down'].fn();forced['adjust-smaller'].fn()
    clear_output();bindings['reset-adjustment']();assert_reset(87,0.9)
end
function lifecycle_cleanup_is_silent_and_clears_record()
    for _, event in ipairs({'start-file','end-file','shutdown'}) do
        properties['sub-pos']=80;properties['sub-scale']=1.25
        properties['user-data/mpvnet/subtitle-base-pos']=94
        bindings['adjust-mode']();move_and_scale()
        clear_output();events[event]();mode_off()
        eq(#messages,0);eq(#commands,1);eq(commands[1][3],'subtitle-adjust-reset')
        eq(commands[1][4],94);eq(properties['sub-pos'],94);eq(properties['sub-scale'],1.25)
        clear_output();events[event]();eq(#messages,0);eq(#writes,0);eq(#commands,0)
        properties['sub-pos']=66;properties['sub-scale']=1.4
        bindings['reset-adjustment']();eq(#writes,0);eq(#commands,0)
        eq(properties['sub-pos'],66);eq(properties['sub-scale'],1.4)
        unchanged_unrelated()
    end
end
function normal_exit_keeps_working_adjustments()
    bindings['adjust-mode']();move_and_scale();clear_output();bindings['adjust-mode']()
    mode_off();eq(properties['sub-pos'],93);eq(properties['sub-scale'],1.3)
    eq(#writes,0);eq(#commands,0);eq(#messages,1);eq(messages[1][1],'SUB ADJUST: OFF')
    unchanged_unrelated()
end
function single_actions_keep_mode_off_and_share_baseline()
    for _, name in ipairs({'position-up','position-down','size-up','size-down'}) do
        eq(binding_keys[name],nil);assert(bindings[name],'missing single-action binding '..name)
    end
    bindings['size-up']();mode_off();eq(properties['sub-pos'],94);eq(properties['sub-scale'],1.3)
    bindings['position-up']();mode_off();eq(properties['sub-pos'],93)
    bindings['position-down']();mode_off();eq(properties['sub-pos'],94)
    bindings['size-down']();mode_off();eq(properties['sub-scale'],1.25)
    -- Going from a menu action into the interactive mode still keeps the first baseline.
    properties['sub-pos']=60;properties['sub-scale']=1.6
    bindings['adjust-mode']();mode_on();forced['adjust-down'].fn()
    eq(properties['sub-pos'],61)
    clear_output();bindings['reset-adjustment']();assert_reset(94,1.25)
end
function single_actions_preserve_active_mode()
    bindings['adjust-mode']();move_and_scale();bindings['position-down']();mode_on()
    eq(properties['sub-pos'],94);bindings['size-down']();mode_on()
    eq(properties['sub-scale'],1.25);forced['adjust-up'].fn();eq(properties['sub-pos'],93)
    clear_output();bindings['reset-adjustment']();assert_reset(94,1.25)
end
function single_actions_without_primary_subtitle_are_noops()
    properties.sid=2
    for _, name in ipairs({'position-up','position-down','size-up','size-down'}) do
        clear_output();bindings[name]();mode_off();eq(#writes,0);eq(#commands,0)
        eq(#messages,1);eq(messages[1][1],'NO SUBTITLE')
        eq(properties['sub-pos'],80);eq(properties['sub-scale'],1.25);eq(properties.sid,2)
        unchanged_unrelated()
    end
    clear_output();bindings['reset-adjustment']();eq(#writes,0);eq(#commands,0)
    eq(messages[1][1],'SUB ADJUST: NO CHANGES')
end
