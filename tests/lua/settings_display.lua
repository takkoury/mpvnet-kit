-- Only mpv, clocks, input regions and unrelated drawing are doubles. Visibility,
-- lease, mouse-leave, autohide, pause and media handlers are production source.
local state,settings_display,settings_owner
local settings_owners={}
local settings_showonpause
local now,properties,messages,observers,events,timers,bindings
local option_callback
local thumbfast={width=0,height=0,available=false}
local elements={}
local function noop() end
local msg={trace=noop,warn=noop}
local mp={
    get_time=function() return now end,
    get_property=function(name) return properties[name] or '0' end,
    get_property_number=function(name,default) return properties[name] or default end,
    set_property_native=function(name,value) properties[name]=value end,
    set_property=function(name,value) properties[name]=value end,
    del_property=function(name) properties[name]=nil end,
    commandv=noop,osd_message=noop,enable_key_bindings=noop,disable_key_bindings=noop,
    command_native=function() return '' end,
    get_script_name=function() return 'modernz' end,
    get_property_native=function(name,default) local value=properties[name];if value~=nil then return value end;return default end,
    register_script_message=function(name,callback) messages[name]=callback end,
    register_event=function(name,callback) events[name]=callback end,
    observe_property=function(name,_,callback) observers[name]=callback end,
    add_key_binding=function(_,name,callback) bindings[name]=callback end,
    add_periodic_timer=function(_,callback) timers[#timers+1]=callback end,
    add_timeout=function() return {timeout=0,kill=noop,resume=noop} end,
}
local opt={read_options=function(_,_,callback) option_callback=callback end}
local request_tick,request_init,update_margins,reset_margins=noop,noop,noop,noop
local close_popover,cancel_seekbar_drag,set_virt_mouse_area=noop,noop,noop
local render_wipe,is_image,check_path_url=noop,noop,noop
local load_locale_file,validate_user_opts,set_osc_locale,set_icon_theme=noop,noop,noop,noop
local set_osc_styles,set_time_styles,set_tick_delay=noop,noop,noop
local function window_controls_enabled() return true end
local function mouse_in_area() return false end
local function popover_inside() return false end
local function observe_cached(name,callback)
    observers[name]=function(_,value) state[name:gsub('-','_')]=value;callback() end
end
local tick=noop
local osc_param={areas={input={}}}
local function reset_fixture(mode,keep)
    now,properties,messages,observers,events,timers,bindings=0,{},{},{},{},{},{}
    state={enabled=true,osc_visible=false,wc_visible=false,idle_active=false,pause=false,
        showhide_enabled=false,keeponpause_active=false,visibility_modes={'never','auto','always'}}
    user_opts.visibility=mode or 'auto'
    user_opts.keeponpause=keep or 'no'
    user_opts.showonpause=true
    user_opts.hidetimeout=500
    user_opts.deadzone_hide='instant'
    user_opts.keep_with_cursor=false
    user_opts.windowcontrols_independent=true
    user_opts.fadeduration=0
    user_opts.fadein=false
end
reset_fixture()

-- SOURCE FUNCTIONS ARE INSERTED HERE

-- Save the handlers captured during source loading; each fixture uses the same
-- actual closures with newly reset state and a new production lease instance.
local source_messages,source_observers,source_events,source_bindings=messages,observers,events,bindings
local function fixture(mode,keep)
    reset_fixture(mode,keep)
    messages,observers,events,bindings=source_messages,source_observers,source_events,source_bindings
    settings_display=create_settings_display()
    visibility_mode(user_opts.visibility,true)
end
local function eq(a,b) assert(a==b,'expected '..tostring(b)..', got '..tostring(a)) end
local function send(operation,token) messages['settings-display-preview'](token or 'editor-1',operation) end
local function advance(value)
    now=value
    for _,timer in ipairs(timers) do timer() end
end
local function pause(value) observers.pause('pause',value) end
local function visible() eq(state.enabled,true);eq(state.osc_visible,true) end

function modes_and_mouse_leave()
    for _,mode in ipairs({'auto','always','never'}) do
        fixture(mode)
        send('begin');visible();eq(user_opts.visibility,mode);eq(properties['user-data/osc/visibility'],mode)
        eq(state.wc_visible,mode=='always')
        mouse_leave();visible()
        user_opts.deadzone_hide='timeout';mouse_leave();visible()
        now=2;autohide();visible()
        send('end');eq(settings_display.active(),false)
        eq(user_opts.visibility,mode);eq(state.enabled,mode~='never');eq(state.osc_visible,mode=='always')
    end
end
function lease_cancels_fade_out()
    fixture('auto');user_opts.fadeduration=200;user_opts.fadein=true
    state.osc_visible=true;state.anitype='out';state.anistart=0;state.animation=180
    send('begin');visible();eq(state.anitype,nil);eq(state.anistart,nil);eq(state.animation,nil)
end
function renew_expiry_and_foreign_tokens()
    fixture('never');send('renew');eq(settings_display.active(),false)
    send('begin');now=1;send('renew','foreign');send('end','foreign');visible()
    now=2;send('renew');advance(3);visible()
    advance(4.999);visible();advance(5);eq(settings_display.active(),false);eq(state.enabled,false)
    send('renew');eq(settings_display.active(),false)
    send('begin');visible();now=9;send('renew') -- expiry checked even before the timer callback
    eq(settings_display.active(),false);eq(state.enabled,false)
end
function manual_modes_and_hide()
    for _,mode in ipairs({'auto','always','never'}) do
        fixture('auto');send('begin')
        messages['osc-visibility'](mode,true);eq(settings_display.active(),false)
        send('renew');send('end');eq(user_opts.visibility,mode);eq(state.osc_visible,mode=='always')
    end
    fixture();send('begin');messages['osc-hide']();eq(settings_display.active(),false);eq(state.osc_visible,false)
    fixture('always');send('begin');bindings.visibility();eq(user_opts.visibility,'never');eq(settings_display.active(),false)
    fixture();send('begin');messages['osc-visibility']('invalid',true);eq(settings_display.active(),true)
end
function pause_policy_matrix()
    for _,mode in ipairs({'auto','always','never'}) do
        for _,keep in ipairs({'no','bottombar','both'}) do
            fixture(mode,keep);send('begin');pause(true);visible();pause(false);visible()
            eq(user_opts.visibility,mode)
            send('end');eq(state.enabled,mode~='never');eq(state.osc_visible,mode=='always')
            fixture(mode,keep);pause(true);send('begin');pause(false);visible();send('end')
            eq(user_opts.visibility,mode);eq(state.osc_visible,mode=='always')
            fixture(mode,keep);send('begin');pause(true);send('end')
            eq(state.osc_visible,mode~='never');eq(settings_display.active(),false)
            if mode~='never' and keep=='bottombar' then eq(state.keeponpause_active,true) end
            pause(false);eq(user_opts.visibility,mode)
        end
    end
end
function manual_pause_override()
    for _,mode in ipairs({'auto','always','never'}) do
        fixture('auto','both');send('begin');pause(true)
        eq(user_opts.visibility,'always');eq(state.keeponpause_restore,'auto')
        messages['osc-visibility'](mode,true);eq(settings_display.active(),false);eq(state.keeponpause_restore,nil)
        send('renew');pause(false);send('end');eq(user_opts.visibility,mode)
    end
end
function manual_pause_without_lease()
    fixture('auto','both');pause(true)
    eq(state.keeponpause_restore,'auto')
    messages['osc-visibility']('always',true)
    eq(state.keeponpause_restore,'auto');eq(state.keeponpause_active,false)
    pause(false);eq(user_opts.visibility,'auto')
    fixture('auto','bottombar');pause(true);eq(state.keeponpause_active,true)
    messages['osc-visibility']('always',true)
    eq(state.keeponpause_active,true);eq(state.keeponpause_restore,nil)
    pause(false);eq(state.keeponpause_active,false);eq(user_opts.visibility,'always')
end
function pause_display_disabled()
    for _,mode in ipairs({'auto','always','never'}) do
        for _,keep in ipairs({'no','bottombar','both'}) do
            fixture(mode,keep);user_opts.showonpause=false
            pause(true);eq(state.keeponpause_active,false);eq(state.keeponpause_restore,nil)
            send('begin');visible();send('end')
            eq(state.enabled,mode~='never');eq(state.osc_visible,mode=='always')
            eq(state.keeponpause_active,false);eq(state.keeponpause_restore,nil)
            pause(false);eq(user_opts.visibility,mode)
        end
    end
end
function media_shutdown_and_reopen()
    for _,event in ipairs({'start-file','end-file','shutdown'}) do
        fixture('never');send('begin');events[event]();eq(settings_display.active(),false);eq(state.enabled,false)
        send('renew');eq(settings_display.active(),false)
    end
    fixture('never');send('begin');send('begin','editor-2');send('end','editor-1');visible()
    send('renew','editor-1');advance(3);eq(settings_display.active(),false)
    fixture();state.idle_active=true;send('begin');eq(settings_display.active(),false)
end
function option_changes()
    fixture();send('begin');option_callback({scalewindowed=true});visible();eq(settings_display.active(),true)
    user_opts.visibility='never';option_callback({visibility=true});eq(settings_display.active(),false)
    send('renew');eq(state.enabled,false);eq(user_opts.visibility,'never')
end
function idle_and_console()
    fixture('never');send('begin');observers['idle-active']('idle-active',true)
    eq(settings_display.active(),false);eq(state.enabled,false)
    send('renew');eq(settings_display.active(),false)
    fixture();send('begin');observers['user-data/mpv/console/open']('',true)
    eq(settings_display.active(),false);eq(state.osc_visible,false)
    send('renew');eq(settings_display.active(),false)
end

function live_pause_previews_restore_policy()
    fixture('auto');user_opts.showonpause=false;pause(true)
    install_settings_owners();send('begin')
    messages['settings-preview']('editor-1','both','','modernz.keeponpause')
    eq(user_opts.keeponpause,'both');eq(user_opts.showonpause,true)
    eq(user_opts.visibility,'always');eq(state.keeponpause_restore,'auto');visible()
    messages['settings-preview']('editor-1','bottombar','','modernz.keeponpause')
    eq(user_opts.visibility,'auto');eq(state.keeponpause_restore,nil);eq(state.keeponpause_active,true)
    messages['settings-cancel']('editor-1','modernz.keeponpause')
    eq(user_opts.keeponpause,'no');eq(user_opts.showonpause,false)
    eq(user_opts.visibility,'auto');eq(state.keeponpause_active,false);eq(state.keeponpause_restore,nil)
    visible();send('end');pause(false);eq(user_opts.visibility,'auto')
end
