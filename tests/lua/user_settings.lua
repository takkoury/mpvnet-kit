local parser=(function()
-- PARSER SOURCE
end)()
local model=(function()
-- MODEL SOURCE
end)()
local files,requests,removed={},{},{}
local config='X:/config/'
local user_path,local_path=config..'mpvnet-user.json',config..'script-opts/mpvnet-local.conf'
local read_failure,write_failure=false,false
local function eq(a,b) assert(a==b,'expected '..tostring(b)..', got '..tostring(a)) end
local writer_text
local function decode(text)
    if text=='writer-with-text' then return {ok=true,written_text=writer_text} end
    if text=='writer-ok' then return {ok=true} end
    if text=='writer-failed' then return {ok=false} end
    if text=='writer-conflict' then return {ok=false,conflict=true} end
    if text:sub(1,1)~='"' or text:sub(-1)~='"' then return nil end
    return (text:sub(2,-2):gsub('\\u(%x%x%x%x)',function(code) return string.char(tonumber(code,16)) end)
        :gsub('\\([\\"/bfnrt])',{['\\']='\\',['"']='"',['/']='/',b='\b',f='\f',n='\n',r='\r',t='\t'}))
end
local function encode(value)
    if type(value)=='string' then
        return '"'..value:gsub('[%z\1-\31\\"]',function(c)
            if c=='\\' or c=='"' then return '\\'..c end
            return string.format('\\u%04x',c:byte())
        end)..'"'
    elseif type(value)=='boolean' or type(value)=='number' then return tostring(value)
    elseif type(value)=='table' then
        local parts={};for k,v in pairs(value) do parts[#parts+1]=encode(k)..':'..encode(v) end
        return '{'..table.concat(parts,',')..'}'
    end
    return 'null'
end
local utils={parse_json=decode,format_json=encode,join_path=function(a,b) return a..'/'..b end,
    file_info=function(path) if files[path]~=nil then return {is_file=true} end end}
io.open=function(path,mode)
    if mode=='rb' then
        if read_failure and path==user_path then return nil,'denied',13 end
        if files[path]==nil then return nil,'missing',2 end
        return {read=function(_,count) return files[path]:sub(1,count) end,close=function() return true end}
    end
    eq(mode,'wb');assert(path:find('X:/temp/mpvnet-settings-',1,true)==1)
    if write_failure then return nil,'denied',13 end
    return {write=function(_,raw) files[path]=raw;return true end,close=function() return true end}
end
os.getenv=function(name) if name=='TEMP' then return 'X:/temp' end end
os.remove=function(path) removed[#removed+1]=path;files[path]=nil;return true end
local function instance(pid,order)
    local host={properties={pid=pid,['options/input-ipc-server']='',['sub-scale']=1.25,
        ['sub-pos']=80,['user-data/mpvnet/subtitle-base-pos']=80,sid=1,
        ['track-list']={{type='sub',id=1,title='ordinary'}}},observers={},events={},messages={},bindings={},timers={},commands={},osd={},fail=false}
    local script
    local function get(name,fallback) local value=host.properties[name];if value~=nil then return value end;return fallback end
    local function set(name,value)
        if host.fail and name=='sub-scale' then return nil end
        if host.float and name=='sub-scale' then value=math.floor(value*8388608+0.5)/8388608 end
        host.properties[name]=value
        for _,callback in ipairs(host.observers[name] or {}) do
            if host.defer and name=='user-data/mpvnet/settings-values' then
                host.pending=host.pending or {};host.pending[#host.pending+1]=function() callback(name,value) end
            else callback(name,value) end
        end
        return true
    end
    local mp={get_time=function() return 1 end,get_script_name=function() return script end,
        get_property=get,get_property_number=get,get_property_native=get,get_property_bool=get,
        set_property=set,set_property_number=set,set_property_native=set,set_property_bool=set,
        command_native=function(args) eq(args[1],'expand-path');return args[2]:gsub('^~~/',config) end,
        command_native_async=function(args,callback) requests[#requests+1]={host=host,args=args,callback=callback} end,
        commandv=function(...)
            local args={...};host.commands[#host.commands+1]=args
            if args[1]=='script-message-to' then
                local callback=host.messages[args[2]] and host.messages[args[2]][args[3]]
                if callback then callback(unpack(args,4)) end
            end
            return true
        end,
        add_key_binding=function(_,name,callback) host.bindings[script..'/'..name]=callback end,
        add_forced_key_binding=function(_,name,callback) host.bindings[script..'/'..name]=callback end,
        remove_key_binding=function() end,
        register_script_message=function(name,callback) host.messages[script]=host.messages[script] or {};host.messages[script][name]=callback end,
        observe_property=function(name,_,callback)
            host.observers[name]=host.observers[name] or {};table.insert(host.observers[name],callback)
            callback(name,host.properties[name])
        end,
        register_event=function(name,callback) host.events[name]=host.events[name] or {};table.insert(host.events[name],callback) end,
        add_periodic_timer=function(_,callback) host.timers[#host.timers+1]=callback end,
        osd_message=function(text) host.osd[#host.osd+1]=text end,msg={warn=function() end},
    }
    host.set=set
    function host.event(name) for _,callback in ipairs(host.events[name] or {}) do callback() end end
    function host.poll() for _,callback in ipairs(host.timers) do callback() end end
    function host.flush() local pending=host.pending or {};host.pending={};for _,callback in ipairs(pending) do callback() end end
    function host.state() return host.properties['user-data/mpvnet/settings'] end
    function host.field(id) for _,field in ipairs(host.state().fields) do if field.id==id then return field end end end
    function host.open() host.bindings['user_settings/open']();return host.state().editor_token end
    function host.send(name,...) host.messages.user_settings[name](...) end
    function host.load(name)
        script=name
        package.loaded['mp'],package.loaded['mp.utils']=mp,utils
        package.loaded['mp.input']={select=function() end}
        package.loaded['mp.options']={read_options=function(values)
            for line in ((files[local_path] or '')..'\n'):gmatch('(.-)\n') do
                local name,value=line:gsub('\r$',''):match('^([^=#]+)=(.*)$')
                if values[name]~=nil then values[name]=value end
            end
        end}
        dofile=function(path)
            if path==config..'script-modules/user-settings.lua' then return model end
            if path==config..'script-modules/user-shortcuts.lua' then return parser end
            if path==config..'script-modules/mpvnet-paths.lua' then
                local paths=(function()
-- PATHS SOURCE
                end)();host.paths=paths;return paths
            end
            error('unexpected dofile '..path)
        end
        if name=='user_settings' then
            (function()
-- CONTROLLER SOURCE
            end)()
        elseif name=='subtitle_controls' then
            (function()
-- SUBTITLE SOURCE
            end)()
        elseif name=='modernz' then
            local user_opts={scalewindowed=1.1}
            local settings_owner
            local request_init=function() host.modernz_inits=(host.modernz_inits or 0)+1 end
            local request_tick=function() end
-- MODERNZ INTEGRATION
            host.modernz_value=function() return user_opts.scalewindowed end
        end
    end
    for _,name in ipairs(order or {'user_settings','subtitle_controls','modernz'}) do host.load(name) end
    return host
end
local function writer(result,job)
    job=job or requests[#requests]
    local path=job.args.args[#job.args.args]
    local root,err=parser.parse(assert(files[path]),decode);assert(root,err)
    if result=='writer-ok' then
        if root.values.document_text then files[user_path]=root.values.document_text.value
        else
            local values=root.values.values.values
            local lines={};for _,name in ipairs(model.path_fields) do
                local node=values[name];if node and node.value~='' then lines[#lines+1]=name..'='..node.value end
            end
            files[local_path]=table.concat(lines,'\n')
        end
    end
    if result=='writer-ok' then
        writer_text=files[root.values.settings_path.value]
        job.callback(true,{status=0,stdout='writer-with-text'})
    else job.callback(true,{status=0,stdout=result}) end
    return root
end
local function save(host,page,value)
    host.send('save',host.state().editor_token,page=='paths' and host.state().paths_revision or host.state().revision,page,value)
end
function raw_patch_preserves_other_pages_and_unknowns()
    local raw='{"schema":1,"shortcuts":{"playback.pause":["x"]},"future":9007199254740993,"settings":{"future":{"a":null}, "modernz.scalewindowed":1.5, "sub-scale":2.0}}'
    local document=assert(model.document(raw,decode,parser))
    local next_raw=assert(model.prepare(document,'subtitles','{"sub-scale":null}',decode,encode,parser,{['sub-scale']=1.25}))
    assert(next_raw:find('"future":9007199254740993',1,true));assert(next_raw:find('"future":{"a":null}',1,true))
    assert(next_raw:find('"shortcuts":{"playback.pause":["x"]}',1,true))
    eq(model.document(next_raw,decode,parser).values['sub-scale'],nil)
    eq(model.document(next_raw,decode,parser).values['modernz.scalewindowed'],1.5)
    assert(not model.prepare(document,'subtitles','{"modernz.scalewindowed":2}',decode,encode,parser,{}))
    assert(not model.document('{"schema":2}',decode,parser))
    assert(not model.document('{"schema":1,"settings":{"sub-scale":0}}',decode,parser))
end
function script_load_order_and_startup_saved_values()
    for _,order in ipairs({{'user_settings','subtitle_controls','modernz'},{'modernz','subtitle_controls','user_settings'}}) do
        files[user_path]='{"schema":1,"settings":{"sub-scale":2,"modernz.scalewindowed":1.5}}'
        local host=instance(100+#requests,order)
        eq(host.field('sub-scale').effective,2);eq(host.field('sub-scale').default,1.25)
        eq(host.field('modernz.scalewindowed').effective,1.5);eq(host.field('modernz.scalewindowed').default,1.1)
    end
end
function preview_cancel_manual_and_media_fencing()
    local host=instance(1);local token=host.open()
    host.send('preview',token,'sub-scale','2');eq(host.field('sub-scale').status,'preview')
    host.send('cancel',token,'subtitles');eq(host.field('sub-scale').effective,1.25)
    host.send('preview',token,'sub-scale','2');host.set('sub-scale',1.7)
    host.send('cancel',token,'subtitles');eq(host.field('sub-scale').effective,1.7)
    host.send('preview',token,'sub-scale','2');host.event('start-file')
    eq(host.field('sub-scale').effective,1.7);host.event('file-loaded');eq(host.field('sub-scale').effective,1.25)
    host.send('preview',token,'sub-scale','null');eq(host.field('sub-scale').effective,1.25)
    host.send('preview',token,'modernz.scalewindowed','2');eq(host.modernz_value(),2)
    host.send('cancel',token,'controlbar');eq(host.modernz_value(),1.1)
end
function save_and_temporary_adjustment_baseline()
    local host=instance(2);host.open()
    host.bindings['subtitle_controls/size-up']();eq(host.field('sub-scale').effective,1.3)
    host.send('preview',host.state().editor_token,'sub-scale','2')
    save(host,'subtitles','{"sub-scale":2}');eq(host.state().saving,true)
    writer('writer-ok');eq(host.state().save_ok,true);eq(host.field('sub-scale').saved,2)
    host.send('cancel',host.state().editor_token,'subtitles');eq(host.field('sub-scale').effective,2)
    host.bindings['subtitle_controls/reset-adjustment']();eq(host.field('sub-scale').effective,2)
    host.event('start-file');host.event('file-loaded');eq(host.field('sub-scale').effective,2)
end
function two_instances_defer_external_changes()
    local first,second=instance(3),instance(4);first.open();second.open()
    local stale=second.state().revision
    save(first,'subtitles','{"sub-scale":2}');writer('writer-ok')
    eq(first.field('sub-scale').effective,2)
    second.poll();eq(second.field('sub-scale').saved,2);eq(second.field('sub-scale').effective,1.25)
    eq(second.field('sub-scale').status,'pending-media')
    second.send('save',second.state().editor_token,stale,'subtitles','{"sub-scale":3}')
    eq(second.state().save_ok,false);eq(second.field('sub-scale').effective,1.25)
    second.event('start-file');second.event('file-loaded');eq(second.field('sub-scale').effective,2)
end
function save_failure_and_application_failure_are_separate()
    local host=instance(5);host.open()
    save(host,'subtitles','{"sub-scale":2}');writer('writer-failed')
    eq(files[user_path],nil);eq(host.state().save_ok,false);eq(host.field('sub-scale').effective,1.25)
    host.fail=true;save(host,'subtitles','{"sub-scale":2}');writer('writer-ok')
    eq(host.state().save_ok,true);eq(host.state().save_error,'');eq(host.field('sub-scale').saved,2)
    eq(host.field('sub-scale').effective,1.25);eq(host.field('sub-scale').status,'apply-failed')
    host.fail=false;host.event('file-loaded');eq(host.field('sub-scale').status,'effective')
end
function session_close_stale_preview_and_shutdown()
    local host=instance(6);local token=host.open();local editor=requests[#requests]
    host.send('preview',token,'sub-scale','2');host.send('editor-close',token)
    eq(host.field('sub-scale').effective,1.25)
    host.send('preview',token,'sub-scale','3');eq(host.field('sub-scale').effective,1.25)
    editor.callback(true,{status=0});local next_token=host.open();assert(next_token~=token)
    host.send('preview',token,'sub-scale','3');eq(host.field('sub-scale').effective,1.25)
    host.send('preview',next_token,'sub-scale','2');host.event('shutdown')
    eq(host.field('sub-scale').effective,1.25)
    host.send('save',next_token,host.state().revision,'subtitles','{"sub-scale":3}')
    eq(files[user_path],nil)
end
function paths_separate_revision_and_restart_rules()
    local host=instance(7);host.open();local revision=host.state().revision
    save(host,'paths','{"capture_root":"X:/Capture","ffmpeg_path":"X:/ffmpeg.exe"}');writer('writer-ok')
    eq(host.state().revision,revision)
    eq(host.field('capture_root').saved,'X:/Capture');eq(host.field('capture_root').status,'effective')
    eq(host.field('ffmpeg_path').status,'pending-restart');eq(files[user_path],nil)
    -- The controller may reread both domains, but path writes never mutate JSON.
    local before=host.state().paths_revision
    files[user_path]='{"schema":1,"settings":{"sub-scale":2}}';host.poll()
    eq(host.state().paths_revision,before);eq(host.field('sub-scale').effective,1.25)
end
function defaults_delete_only_the_current_override()
    files[user_path]='{"schema":1,"settings":{"sub-scale":2,"modernz.scalewindowed":2},"shortcuts":{"future":[]}}'
    local host=instance(9);local token=host.open();local paths_revision=host.state().paths_revision
    host.send('preview',token,'sub-scale','null');eq(host.field('sub-scale').effective,1.25)
    save(host,'subtitles','{"sub-scale":null}');writer('writer-ok')
    eq(host.field('sub-scale').has_override,false);eq(host.field('sub-scale').saved,1.25)
    eq(host.field('modernz.scalewindowed').saved,2);eq(host.state().paths_revision,paths_revision)
    assert(files[user_path]:find('"shortcuts":{"future":[]}',1,true))
end
function local_reader_bom_and_new_task_frozen_program_paths()
    files[local_path]='capture_root=X:/old\nffmpeg_path=X:/old.exe\n'
    local host=instance(10);host.open()
    local values=assert(host.paths.parse_local('\239\187\191capture_root=X:/ignored\npython_path=X:/python.exe\n'))
    eq(values.capture_root,'');eq(values.python_path,'X:/python.exe')
    assert(not host.paths.parse_local('capture_root=X:/one\ncapture_root=X:/two'))
    local task=host.paths.capture_payload({})
    eq(task.capture_root,'X:/old');eq(task.ffmpeg_path,'X:/old.exe')
    save(host,'paths','{"capture_root":"X:/new","ffmpeg_path":"X:/new.exe"}');writer('writer-ok')
    local next_task=host.paths.capture_payload({})
    eq(task.capture_root,'X:/old');eq(next_task.capture_root,'X:/new');eq(next_task.ffmpeg_path,'X:/old.exe')
    files[local_path]=nil
    eq(host.paths.capture_payload({}).capture_root,nil)
end
function saved_success_with_newer_external_write_does_not_apply_foreign_value()
    local host=instance(11);host.open()
    save(host,'subtitles','{"sub-scale":2}')
    local job=requests[#requests]
    files[user_path]='{"schema":1,"settings":{"sub-scale":3}}'
    job.callback(true,{status=0,stdout='writer-ok'})
    eq(host.state().save_ok,true);eq(host.state().save_revision,'')
    eq(host.field('sub-scale').saved,3);eq(host.field('sub-scale').effective,1.25)
end
function delayed_observers_cannot_drop_commit_or_restore_old_saved_state()
    local host=instance(12);host.open();host.defer=true
    save(host,'subtitles','{"sub-scale":2}');writer('writer-ok')
    eq(host.field('sub-scale').effective,2);eq(host.field('sub-scale').saved,2)
    files[user_path]='{"schema":1,"settings":{"sub-scale":3}}';host.poll()
    host.flush();eq(host.field('sub-scale').saved,3);eq(host.field('sub-scale').effective,2)
    eq(host.field('sub-scale').status,'pending-media')
end
function advanced_startup_baseline_is_never_replaced_by_editor_range()
    local host=instance(13,{'modernz'})
    host.set('sub-scale',125);host.load('subtitle_controls');host.load('user_settings');host.open()
    eq(host.field('sub-scale').default,125);eq(host.field('sub-scale').effective,125)
    host.send('preview',host.state().editor_token,'sub-scale','2')
    host.send('preview',host.state().editor_token,'sub-scale','null');eq(host.field('sub-scale').effective,125)
end
function failed_save_application_keeps_preview_cancelable()
    local host=instance(14);local token=host.open()
    host.send('preview',token,'sub-scale','2');host.fail=true
    save(host,'subtitles','{"sub-scale":3}');writer('writer-ok')
    eq(host.field('sub-scale').effective,2);eq(host.field('sub-scale').saved,3)
    eq(host.field('sub-scale').status,'apply-failed');host.fail=false
    host.send('cancel',token,'subtitles');eq(host.field('sub-scale').effective,1.25)
    host.event('start-file');host.event('file-loaded');eq(host.field('sub-scale').effective,3)
end
function explicit_manual_same_value_invalidates_preview()
    local host=instance(15);local token=host.open()
    host.send('preview',token,'sub-scale','100')
    host.bindings['subtitle_controls/size-up']();eq(host.field('sub-scale').effective,100)
    host.send('cancel',token,'subtitles');eq(host.field('sub-scale').effective,100)
end
function failed_cancel_preserves_ownership_for_retry()
    local host=instance(16);local token=host.open()
    host.send('preview',token,'sub-scale','2');host.fail=true
    host.send('cancel',token,'subtitles');eq(host.field('sub-scale').effective,2)
    eq(host.field('sub-scale').status,'apply-failed');eq(host.field('sub-scale').can_cancel,true)
    host.fail=false;host.send('cancel',token,'subtitles')
    eq(host.field('sub-scale').effective,1.25);eq(host.field('sub-scale').can_cancel,false)
end
function path_write_receipt_does_not_adopt_a_newer_external_write()
    local host=instance(17);host.open()
    save(host,'paths','{"capture_root":"X:/ours"}')
    local job=requests[#requests]
    writer_text='capture_root=X:/ours\n';files[local_path]='capture_root=X:/theirs\n'
    job.callback(true,{status=0,stdout='writer-with-text'})
    eq(host.state().save_ok,true);eq(host.state().save_revision,'');eq(host.field('capture_root').saved,'X:/theirs')
end
function reopen_can_retry_only_its_retired_preview_owner()
    local host=instance(18);local token=host.open();local editor=requests[#requests]
    host.send('preview',token,'sub-scale','2');host.fail=true
    host.send('editor-close',token)
    eq(host.field('sub-scale').can_cancel,true)
    eq(host.osd[#host.osd],'预览未能恢复，请重新打开设置后重试撤销')
    editor.callback(true,{status=0});host.fail=false;local next_token=host.open()
    host.send('cancel',next_token,'subtitles');eq(host.field('sub-scale').effective,1.25)
    eq(host.field('sub-scale').can_cancel,false)
    host.messages.subtitle_controls['settings-preview']('foreign-owner','2')
    host.send('cancel',next_token,'subtitles');eq(host.field('sub-scale').effective,2)
end
function reopened_preview_retains_its_retired_restoration_point()
    local host=instance(19);local token=host.open();local editor=requests[#requests]
    host.send('preview',token,'sub-scale','2');host.fail=true;host.send('editor-close',token)
    editor.callback(true,{status=0});host.fail=false;local next_token=host.open()
    host.send('preview',next_token,'sub-scale','3');host.send('cancel',next_token,'subtitles')
    eq(host.field('sub-scale').effective,1.25)
end
function float_roundtrip_accepts_apply_and_keeps_exact_preview_ownership()
    local host=instance(20);host.float=true;local token=host.open()
    host.send('preview',token,'sub-scale','1.8')
    local actual=host.field('sub-scale').effective
    assert(actual~=1.8);assert(model.same_number(actual,1.8))
    eq(host.field('sub-scale').status,'preview');eq(host.field('sub-scale').apply_error,'')
    eq(host.field('sub-scale').can_cancel,true)
    host.send('cancel',token,'subtitles');eq(host.field('sub-scale').effective,1.25)
    host.send('preview',token,'sub-scale','1.8')
    save(host,'subtitles','{"sub-scale":1.8}');writer('writer-ok')
    eq(host.field('sub-scale').saved,1.8);eq(host.field('sub-scale').status,'effective')
    eq(host.field('sub-scale').apply_error,'');eq(host.field('sub-scale').can_cancel,false)
    host.send('preview',token,'sub-scale','2.1');host.set('sub-scale',2.15)
    local manual=host.field('sub-scale').effective
    host.send('cancel',token,'subtitles');eq(host.field('sub-scale').effective,manual)
    assert(not model.same_number(1.8,1.85));assert(not model.same_number(100,100.05))
    -- Even a much smaller observable manual edit invalidates exact ownership.
    host.send('preview',token,'sub-scale','2.1');host.set('sub-scale',2.1000002)
    manual=host.field('sub-scale').effective;host.send('cancel',token,'subtitles')
    eq(host.field('sub-scale').effective,manual);eq(host.field('sub-scale').can_cancel,false)
end
function corrupt_files_and_conflict_keep_runtime()
    local host=instance(8);host.open()
    files[user_path]='{"schema":1,"settings":{"sub-scale":2}}';host.poll()
    eq(host.field('sub-scale').effective,1.25)
    files[user_path]='{"schema":7}';host.poll();assert(host.state().error~='')
    save(host,'subtitles','{"sub-scale":3}');eq(host.state().save_ok,false)
    eq(files[user_path],'{"schema":7}')
    files[user_path]='{"schema":1}';host.poll()
    save(host,'subtitles','{"sub-scale":3}');writer('writer-conflict');eq(host.state().save_ok,false)
    eq(host.field('sub-scale').effective,1.25)
end

local function display_commands(host)
    local commands={}
    for _,command in ipairs(host.commands) do
        if command[1]=='script-message-to' and command[2]=='modernz' and command[3]=='settings-display-preview' then
            commands[#commands+1]=command
        end
    end
    return commands
end
function display_preview_token_and_operation_fencing()
    local host=instance(61);local token=host.open()
    host.send('preview-display','foreign','controlbar')
    host.send('preview-display',token,'subtitles')
    host.send('preview-display',token,'begin')
    eq(#display_commands(host),0)
    for _,operation in ipairs({'controlbar','renew','none'}) do host.send('preview-display',token,operation) end
    local commands=display_commands(host);eq(#commands,3)
    eq(commands[1][4],token);eq(commands[1][5],'begin')
    eq(commands[2][5],'renew');eq(commands[3][5],'end')
    host.send('editor-close',token)
    local count=#display_commands(host)
    host.send('preview-display',token,'controlbar');eq(#display_commands(host),count)
end
function display_preview_editor_lifecycle()
    for index,operation in ipairs({'close','exit','shutdown'}) do
        local host=instance(61+index);local token=host.open()
        local editor=requests[#requests]
        host.send('preview-display',token,'controlbar')
        if operation=='close' then host.send('editor-close',token)
        elseif operation=='exit' then editor.callback(true,{status=0})
        else host.event('shutdown') end
        local commands=display_commands(host);eq(#commands,2)
        eq(commands[2][4],token);eq(commands[2][5],'end')
        host.send('preview-display',token,'controlbar');eq(#display_commands(host),2)
    end
end
