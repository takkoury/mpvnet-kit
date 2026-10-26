-- The whole production script runs below; doubles represent mpv and the OS only.
local bindings, events, script_messages, commands, messages, logs = {}, {}, {}, {}, {}, {}
local properties = {pid = 123, ['working-directory'] = 'X:/fixture', path = 'X:/fixture/current.mkv',
    ['options/input-ipc-server'] = '', ['options/video-exts'] = {'mkv', 'mp4'},
    ['options/audio-exts'] = {'flac', 'mp3'}, playlist = {{id=71}, {id=92}}}
local failure, callback, removed, temp = '', nil, {}, 'X:/fixture/temp'
local parsed, emitted_payload
local observers = {}
local function set_property(name, value)
    local previous = properties[name]
    properties[name] = value
    if previous ~= value then
        for _, observer in ipairs(observers[name] or {}) do observer(name, value) end
    end
    return true
end
local mp = {
    get_time=function() return 1 end,
    get_script_name=function() return 'playlist_controls' end,
    get_property=function(name, default) if properties[name] ~= nil then return properties[name] end;return default end,
    get_property_native=function(name, default) if properties[name] ~= nil then return properties[name] end;return default end,
    get_property_number=function(name, default) if properties[name] ~= nil then return properties[name] end;return default end,
    set_property=function(name, value)
        if failure == 'ipc' and name == 'options/input-ipc-server' then return nil end
        return set_property(name, value)
    end,
    set_property_native=set_property,
    observe_property=function(name, kind, observer)
        assert(kind == 'native', 'fixture supports native property observers only')
        observers[name] = observers[name] or {}
        table.insert(observers[name], observer)
        observer(name, properties[name])
    end,
    osd_message=function(value, duration) messages[#messages+1]={value,duration} end,
    commandv=function(...)
        local args={...};commands[#commands+1]=args
        if failure == 'append' and args[2]=='loadfile' then return nil end
        return true
    end,
    command_native=function(args)
        if args[1]=='expand-path' then return args[2] end
        return {status=0}
    end,
    command_native_async=function(_, done) callback=done end,
    add_key_binding=function(_, name, fn) bindings[name]=fn end,
    register_event=function(name, fn) events[name]=fn end,
    register_script_message=function(name, fn) script_messages[name]=fn end,
    msg={warn=function(value) logs[#logs+1]=value end},
}
local utils = {
    parse_json=function(_) return parsed end,
    format_json=function(value) emitted_payload=value;return 'json' end,
    join_path=function(a,b) return a..'/'..b end,
    file_info=function(file) if file:find('missing',1,true) then return nil end;return {is_file=not file:find('directory',1,true)} end,
}
package.loaded['mp']=mp;package.loaded['mp.utils']=utils
local original_dofile, original_open, original_getenv, original_remove=dofile,io.open,os.getenv,os.remove
dofile=function(_) return {powershell=function() return 'powershell.exe' end} end
os.getenv=function(name) if name=='TEMP' or name=='TMP' then return temp end;return nil end
os.remove=function(path) removed[#removed+1]=path;return true end
io.open=function(_, _)
    if failure=='open' then return nil end
    return {write=function() if failure=='write' then return nil end;return true end,
        close=function() if failure=='close' then return nil end;return true end}
end

-- COMPLETE SOURCE IS INSERTED HERE

local function eq(actual, expected)
    assert(actual==expected,'expected '..tostring(expected)..', got '..tostring(actual))
end
local function reset(mode)
    failure=mode or '';messages,commands,logs,removed={}, {}, {}, {};temp='X:/fixture/temp'
    callback,parsed=nil,nil
    properties['options/input-ipc-server']=''
end
local function open()
    bindings.toggle()
    return properties['user-data/mpvnet/playlist-window'].token
end
local function only_message(text)
    eq(#messages,1);eq(messages[1][1],text);eq(messages[1][2],1)
end
local function ready_window()
    local token=open()
    script_messages['helper-ready'](token,'999')
    return token
end
local function key_command(index, phase, key)
    eq(#commands[index],3)
    eq(commands[index][1],'no-osd');eq(commands[index][2],phase);eq(commands[index][3],key)
end
function open_failure_paths()
    for _, mode in ipairs({'ipc','temp','open','write','close'}) do
        reset(mode);if mode=='temp' then temp=nil end
        local token=open();only_message('PLAYLIST OPEN FAILED')
        eq(properties['user-data/mpvnet/playlist-window'].visible,false)
        eq(callback,nil)
        if mode=='write' or mode=='close' then
            eq(#removed,1);eq(removed[1],'X:/fixture/temp/mpvnet-playlist-'..token..'.json')
        else eq(#removed,0) end
    end
end
function worker_failure_and_cancellation()
    reset();open();assert(callback)
    parsed={phase='https://secret.invalid/token',error_class='https://secret.invalid/token',error_member='url?secret'}
    callback(false,{status=1,stdout='untrusted'})
    only_message('PLAYLIST OPEN FAILED');eq(#removed,1)
    assert(not table.concat(logs,' '):find('secret',1,true),'raw worker data leaked')
    reset();open();bindings.toggle();callback(false,{status=1})
    eq(#messages,0);eq(properties['user-data/mpvnet/playlist-window'].visible,false)
end
function success_and_shutdown_are_silent()
    reset();open();callback(true,{status=0});eq(#messages,0)
    reset();local token=open();eq(#messages,0)
    script_messages['helper-ready'](token,'999')
    eq(properties['user-data/mpvnet/playlist-window'].ready,true)
    events.shutdown();callback(false,{status=1})
    eq(#messages,0)
end
function append_rejections_and_partial_success()
    reset();local token=properties['user-data/mpvnet/playlist-window'].token
    parsed={'X:/fixture/wrong.flac','X:/fixture/image.png','X:/fixture/missing.mp4','https://private.invalid/secret.mkv'}
    script_messages.action(token,'append','json');only_message('NO SUPPORTED FILES');eq(#commands,0)
    messages={};parsed={'X:/fixture/wrong.flac','X:/fixture/valid.mp4','X:/fixture/image.png'}
    script_messages.action(token,'append','json');eq(#messages,0);eq(#commands,1)
    eq(commands[1][2],'loadfile');eq(commands[1][3],'X:/fixture/valid.mp4');eq(commands[1][4],'append')
    messages={};commands={};parsed={};script_messages.action(token,'append','json');only_message('NO SUPPORTED FILES')
    messages={};parsed=nil;script_messages.action(token,'append','bad json');only_message('NO SUPPORTED FILES')
    messages={};failure='append';parsed={'X:/fixture/valid.mp4'}
    script_messages.action(token,'append','json');only_message('PLAYLIST APPEND FAILED')
    eq(#logs,0)
end
function actions_keep_queue_ids_and_token_boundary()
    reset();local token=properties['user-data/mpvnet/playlist-window'].token
    parsed={'X:/fixture/image.png'};script_messages.action('wrong','append','json');eq(#messages,0)
    script_messages.action(token,'play','92');eq(commands[1][3],1)
    script_messages.action(token,'remove','71');eq(commands[2][3],0)
    script_messages.action(token,'remove','stale');eq(#commands,2)
    script_messages.action(token,'move','71','92','after');eq(commands[3][3],0);eq(commands[3][4],2)
end

function locate_reads_current_queue_without_playing()
    reset();local token=properties['user-data/mpvnet/playlist-window'].token
    -- An old UI ID/position cannot override the live current queue identity.
    properties.playlist={{id=92},{id=154},{id=71}};properties['playlist-pos']=1
    script_messages.action(token,'locate','71')
    eq(#commands,1);eq(commands[1][1],'script-message')
    eq(commands[1][2],'mpvnet-playlist-locate');eq(commands[1][3],token);eq(commands[1][4],'154')
    eq(properties['playlist-pos'],1);eq(properties.playlist[1].id,92);eq(properties.playlist[2].id,154)
    commands={};properties.playlist={{id=71},{id=92},{id=154}};properties['playlist-pos']=2
    script_messages.action(token,'locate');eq(#commands,1);eq(commands[1][4],'154')
    commands={};script_messages.action('wrong','locate');eq(#commands,0)
    for _, position in ipairs({-1,3,0.5}) do
        properties['playlist-pos']=position;script_messages.action(token,'locate');eq(#commands,0)
    end
    properties.playlist={};properties['playlist-pos']=0
    script_messages.action(token,'locate');eq(#commands,0);eq(#messages,0)
end

function shortcut_changes_release_old_keys_and_update_forwarding()
    reset();local token=ready_window()
    script_messages.key(token,'down','Space')
    eq(#commands,1);key_command(1,'keydown','Space')

    -- Change the real observed property while the old shortcut is held.
    mp.set_property_native('user-data/mpvnet/shortcuts',{schema=1,forward_keys={'ctrl+f8'}})
    eq(#commands,2);key_command(2,'keyup','Space')
    script_messages.key(token,'up','Space')
    script_messages.key(token,'press','Space')
    script_messages.key(token,'down','Space')
    script_messages.key(token,'press','F8')
    eq(#commands,2)

    script_messages.key(token,'down','Ctrl+F8')
    eq(#commands,3);key_command(3,'keydown','Ctrl+F8')
    script_messages.key(token,'down','ctrl+f8')
    script_messages.key(token,'press','Ctrl+F8')
    eq(#commands,3)
    script_messages.key(token,'up','Ctrl+F8')
    eq(#commands,4);key_command(4,'keyup','Ctrl+F8')
    script_messages.key(token,'press','Ctrl+F8')
    eq(#commands,5);key_command(5,'keypress','Ctrl+F8')
end

function equivalent_shortcut_updates_keep_held_keys_and_invalid_state_restores_defaults()
    reset();local token=ready_window()
    mp.set_property_native('user-data/mpvnet/shortcuts',{schema=1,forward_keys={'F8','Space'}})
    script_messages.key(token,'down','F8')
    eq(#commands,1);key_command(1,'keydown','F8')

    -- Order, spelling, duplicates and rejected keys do not change the effective set.
    mp.set_property_native('user-data/mpvnet/shortcuts',{
        schema=1,forward_keys={'space','f8','F8','not-a-key'},
    })
    eq(#commands,1)
    script_messages.key(token,'down','F8');eq(#commands,1)

    mp.set_property_native('user-data/mpvnet/shortcuts',{schema=2,forward_keys={'F8'}})
    eq(#commands,2);key_command(2,'keyup','F8')
    script_messages.key(token,'up','F8')
    script_messages.key(token,'press','F8');eq(#commands,2)
    script_messages.key(token,'press','d')
    eq(#commands,3);key_command(3,'keypress','d')
end

function initial_shortcuts_define_forwarding()
    reset();local token=ready_window()
    script_messages.key(token,'press','Space');eq(#commands,0)
    script_messages.key(token,'press','F8')
    eq(#commands,1);key_command(1,'keypress','F8')
end
