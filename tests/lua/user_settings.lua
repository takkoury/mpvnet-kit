local parser=(function()
-- PARSER SOURCE
end)()
local model=(function()
-- MODEL SOURCE
end)()
local package_options={
-- PACKAGE OPTIONS
}
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
local function instance(pid,order,startup_options)
    local host={properties={pid=pid,['options/input-ipc-server']='',['sub-scale']=1.25,
        ['sub-pos']=80,['sub-font']='Default Font',['sub-visibility']=true,slang='eng',alang='jpn',hwdec='auto-safe',
        volume=75,mute=true,fullscreen=false,ontop=false,['user-data/mpvnet/subtitle-base-pos']=80,sid=1,
        ['track-list']={{type='sub',id=1,title='ordinary'}}},observers={},events={},messages={},bindings={},timers={},commands={},writes={},hooks={},local_options={},osd={},fail=false}
    for id,value in pairs(startup_options or {}) do host.properties[id]=value end
    local script
    local function get(name,fallback) local value=host.properties[name];if value~=nil then return value end;return fallback end
    local function set(name,value)
        host.writes[#host.writes+1]={name,value}
        local option=name:match('^file%-local%-options/(.+)$')
        if option then
            if not host.local_options[option] then host.local_options[option]={value=get(option)} end
            name=option
        end
        if host.fail and name=='sub-scale' or host.fail_audio and (name=='volume' or name=='mute') then return nil end
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
        add_hook=function(name,_,callback) host.hooks[name]=host.hooks[name] or {};table.insert(host.hooks[name],callback) end,
        register_event=function(name,callback) host.events[name]=host.events[name] or {};table.insert(host.events[name],callback) end,
        add_periodic_timer=function(_,callback) host.timers[#host.timers+1]=callback end,
        osd_message=function(text) host.osd[#host.osd+1]=text end,msg={warn=function() end},
    }
    host.set=set
    function host.event(name)
        for _,callback in ipairs(host.events[name] or {}) do callback() end
        if name=='end-file' then
            for id,old in pairs(host.local_options) do set(id,old.value) end
            host.local_options={}
        end
    end
    function host.hook(name) for _,callback in ipairs(host.hooks[name] or {}) do callback() end end
    function host.media() host.event('end-file');host.event('start-file');host.hook('on_load');host.event('file-loaded') end
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
        elseif name=='settings_options' then
            (function()
-- OPTIONS SOURCE
            end)()
        elseif name=='modernz' then
            local user_opts={scalewindowed=1.1,scalefullscreen=1,hidetimeout=1500,keeponpause='no',chapter_fmt='Chapter %s',timecurrent=true,timems=false,persistent_progress=false,showonpause=true}
            local state={pause=false}
            local settings_owner
            local settings_owners={}
            local settings_showonpause
            local function set_time_styles(current,ms)
                if current then state.tc_left_rem=not user_opts.timecurrent end
                if ms then state.tc_ms=user_opts.timems end
            end
            local function apply_pause_policy() host.pause_policy=(host.pause_policy or 0)+1 end
            local function visibility_mode() end
            local request_init=function() host.modernz_inits=(host.modernz_inits or 0)+1 end
            local request_tick=function() end
-- MODERNZ INTEGRATION
            host.modernz_value=function(name) return user_opts[name or 'scalewindowed'] end
            host.modernz_state=state
            local ne={eventresponder={}}
-- MODERNZ TIME ACTION
            host.modernz_manual_time=ne.eventresponder.mbtn_left_up
-- MODERNZ PROGRESS ACTION
        end
    end
    for _,name in ipairs(order or {'user_settings','subtitle_controls','modernz','settings_options'}) do host.load(name) end
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

function editor_refresh_reads_external_without_writing_or_changing_session()
    local host=instance(90);local token=host.open()
    eq(host.state().refresh_id,'')
    local revision=host.state().revision;local count=#requests
    local raw='{"schema":1,"settings":{"sub-scale":2},"shortcuts":{"playback.pause":["F2"]}}'
    files[user_path]=raw
    local original={};for path,text in pairs(files) do original[path]=text end
    host.send('editor-refresh',token,'close-1')
    eq(host.state().refresh_id,'close-1');assert(host.state().revision~=revision)
    eq(host.field('sub-scale').saved,2);eq(host.state().save_serial,0);eq(host.state().saving,false)
    eq(host.state().editor_token,token);eq(host.state().editor_visible,true);eq(#requests,count)
    for path,text in pairs(files) do eq(text,original[path]) end
    for path,text in pairs(original) do eq(files[path],text) end
    revision=host.state().revision
    host.send('editor-refresh',token,'close-2')
    eq(host.state().refresh_id,'close-2');eq(host.state().revision,revision);eq(#requests,count)
    -- The acknowledgement does not authorize overwriting a later external edit.
    files[user_path]='{"schema":1,"settings":{"sub-scale":3}}'
    host.send('save',token,revision,'subtitles','{"sub-scale":4}')
    eq(host.state().save_ok,false);eq(host.field('sub-scale').saved,3);eq(#requests,count)
end

function editor_refresh_rejects_invalid_busy_and_closed_requests()
    local host=instance(91);local token=host.open();local initial=host.state()
    files[user_path]='{"schema":1,"settings":{"sub-scale":2}}'
    host.send('editor-refresh','wrong','valid-1');eq(host.state(),initial)
    for _,id in ipairs({'','bad_id','bad id','bad/id','中文',string.rep('a',65),false,123}) do
        host.send('editor-refresh',token,id);eq(host.state(),initial)
    end
    host.send('editor-refresh',token,nil);eq(host.state(),initial)
    host.send('editor-refresh',token,string.rep('a',64));eq(host.state().refresh_id,string.rep('a',64))
    save(host,'subtitles','{"sub-scale":3}');eq(host.state().saving,true)
    local busy=host.state();local count=#requests
    host.send('editor-refresh',token,'busy-1');eq(host.state(),busy);eq(#requests,count)
    writer('writer-failed');host.send('editor-close',token)
    local closed=host.state();host.send('editor-refresh',token,'closed-1');eq(host.state(),closed)
    host.event('shutdown');closed=host.state()
    host.send('editor-refresh',token,'shutdown-1');eq(host.state(),closed)
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

-- M2-C fields exercise production model, controller, subtitle and option adapters.
function typed_values_and_raw_page_patch()
    local raw='{"schema":1,"settings":{"mute":false,"sub-visibility":false,"sub-font":"null","slang":"","future":{"exact":9007199254740993}},"extra":1e99}'
    local doc=assert(model.document(raw,decode,parser))
    eq(doc.values.mute,false);eq(doc.values['sub-visibility'],false);eq(doc.values.slang,'')
    eq(doc.values['sub-font'],'null')
    local next_raw=assert(model.prepare(doc,'audio','{"mute":false,"volume":0,"alang":"eng,jpn"}',decode,encode,parser,{mute=true,volume=75,alang='jpn'}))
    local parsed=assert(model.document(next_raw,decode,parser))
    eq(parsed.values.mute,false);eq(parsed.values.volume,0);eq(parsed.values.alang,'eng,jpn')
    assert(next_raw:find('"future":{"exact":9007199254740993}',1,true));assert(next_raw:find('"extra":1e99',1,true))
    next_raw=assert(model.prepare(parsed,'audio','{"mute":null}',decode,encode,parser,{mute=true}))
    eq(model.document(next_raw,decode,parser).values.mute,nil)
    for _,bad in ipairs({'{"mute":"false"}','{"volume":false}','{"alang":true}'}) do assert(not model.proposed('audio',bad,decode,parser)) end
    assert(not model.proposed('decoding','{"hwdec":"arbitrary"}',decode,parser))
    assert(not model.proposed('subtitles','{"sub-font":"bad\\nfont"}',decode,parser))
end
function all_fields_publish_their_type_timing_and_page()
    local host=instance(71)
    eq(#host.state().fields,23);eq(#host.state().pages,8);eq(#host.state().actions,5)
    for _,field in ipairs(host.state().fields) do
        assert(field.kind=='number' or field.kind=='string' or field.kind=='boolean' or field.kind=='choice')
        assert(field.timing and field.default~=nil and field.saved~=nil and field.status)
        if field.kind=='choice' then assert(#field.choices>0) end
    end
    eq(host.field('mute').default,true);eq(host.field('modernz.timems').default,false)
    eq(host.field('modernz.timems').saved,false);eq(host.field('sub-pos').display,'position')
end
function multiple_preview_fields_restore_independently()
    local host=instance(72);local token=host.open()
    host.send('preview',token,'sub-font','"New Font"')
    host.send('preview',token,'sub-pos','60')
    host.send('preview',token,'sub-scale','1.8')
    eq(host.field('sub-font').effective,'New Font');eq(host.field('sub-pos').effective,60);eq(host.field('sub-scale').effective,1.8)
    host.set('user-data/mpvnet/subtitle-base-pos',61);host.set('sub-pos',61)
    host.send('cancel',token,'subtitles')
    eq(host.field('sub-font').effective,'Default Font');eq(host.field('sub-pos').effective,61);eq(host.field('sub-scale').effective,1.25)
    host.send('preview',token,'sub-font','"null"');eq(host.field('sub-font').effective,'null')
    host.send('preview',token,'sub-font','""');eq(host.field('sub-font').effective,'')
    host.send('cancel',token,'subtitles');eq(host.field('sub-font').effective,'Default Font')
end
function next_media_options_run_before_selection_and_never_at_save()
    local host=instance(73);local token=host.open()
    save(host,'subtitles','{"slang":"zho,eng","sub-visibility":false}');writer('writer-ok')
    save(host,'audio','{"alang":"eng,jpn"}');writer('writer-ok')
    save(host,'decoding','{"hwdec":"no"}');writer('writer-ok')
    eq(host.field('slang').effective,'eng');eq(host.field('sub-visibility').effective,true)
    eq(host.field('alang').effective,'jpn');eq(host.field('hwdec').effective,'auto-safe')
    eq(host.field('hwdec').status,'pending-media')
    for _,write in ipairs(host.writes) do assert(write[1]~='hwdec' and not write[1]:find('file-local-options/',1,true)) end
    host.send('preview',token,'hwdec','"no"');eq(host.field('hwdec').effective,'auto-safe')
    host.event('start-file');eq(host.field('hwdec').effective,'auto-safe')
    host.hook('on_load')
    -- These assertions precede file-loaded: selection/decoder construction sees
    -- the options already applied, not a late property change after decoding.
    eq(host.field('slang').effective,'zho,eng');eq(host.field('sub-visibility').effective,false)
    eq(host.field('alang').effective,'eng,jpn');eq(host.field('hwdec').effective,'no')
    local count=0
    for _,write in ipairs(host.writes) do if write[1]=='file-local-options/hwdec' then count=count+1 end end
    eq(count,1);host.event('file-loaded');host.poll()
    local next_count=0
    for _,write in ipairs(host.writes) do if write[1]=='file-local-options/hwdec' then next_count=next_count+1 end end
    eq(next_count,count)
    save(host,'decoding','{"hwdec":null}');writer('writer-ok');eq(host.field('hwdec').effective,'no')
    host.media();eq(host.field('hwdec').effective,'auto-safe')
    -- Inheritance avoids writing any option, preserving file-specific choices.
    host.set('hwdec','nvdec');host.hook('on_load');eq(host.field('hwdec').effective,'nvdec')
end
function startup_overrides_initialize_once_and_false_is_not_missing()
    files[user_path]='{"schema":1,"settings":{"volume":0,"mute":false,"fullscreen":true,"ontop":true}}'
    local host=instance(74);host.open()
    eq(host.field('volume').effective,75);eq(host.field('mute').effective,true)
    eq(host.field('volume').status,'pending-startup');eq(host.field('volume').timing,'first-media')
    host.hook('on_load');eq(host.field('volume').effective,0);eq(host.field('mute').effective,false)
    eq(host.field('mute').saved,false);eq(host.field('mute').has_override,true)
    eq(host.field('fullscreen').effective,true);eq(host.field('ontop').effective,true)
    host.set('volume',33);host.set('mute',true);host.set('fullscreen',false);host.set('ontop',false)
    host.media();host.poll();host.media()
    eq(host.field('volume').effective,33);eq(host.field('mute').effective,true)
    eq(host.field('fullscreen').effective,false);eq(host.field('ontop').effective,false)
    save(host,'audio','{"volume":50,"mute":false}');writer('writer-ok')
    save(host,'window','{"fullscreen":true,"ontop":true}');writer('writer-ok')
    eq(host.field('volume').effective,33);eq(host.field('mute').effective,true)
    eq(host.field('volume').status,'pending-startup');eq(host.field('fullscreen').effective,false)
    local fresh=instance(75)
    eq(fresh.field('volume').effective,75);fresh.hook('on_load')
    eq(fresh.field('volume').effective,50);eq(fresh.field('mute').effective,false)
    eq(fresh.field('fullscreen').effective,true);eq(fresh.field('ontop').effective,true)
end
function options_observers_can_be_delayed_and_external_changes_defer()
    local first,second=instance(76),instance(77);first.open();second.open();second.defer=true
    save(first,'subtitles','{"slang":"zho","sub-visibility":false}');writer('writer-ok')
    save(first,'decoding','{"hwdec":"no"}');writer('writer-ok')
    save(first,'audio','{"mute":false}');writer('writer-ok')
    second.poll();eq(second.field('hwdec').saved,'no');eq(second.field('hwdec').effective,'auto-safe')
    second.media();eq(second.field('hwdec').effective,'no');eq(second.field('slang').effective,'zho')
    eq(second.field('sub-visibility').effective,false);eq(second.field('mute').effective,true)
    second.flush();eq(second.field('mute').saved,false);eq(second.field('hwdec').effective,'no')
end
function all_modernz_fields_apply_preview_and_cancel()
    local host=instance(78);local token=host.open()
    local changes={scalewindowed='1.5',scalefullscreen='1.8',hidetimeout='2.5',keeponpause='"both"',chapter_fmt='false',timecurrent='false',timems='true',persistent_progress='true'}
    for id,value in pairs(changes) do host.send('preview',token,'modernz.'..id,value) end
    eq(host.modernz_value('scalewindowed'),1.5);eq(host.modernz_value('scalefullscreen'),1.8)
    eq(host.modernz_value('hidetimeout'),2500);eq(host.modernz_value('keeponpause'),'both')
    eq(host.modernz_value('chapter_fmt'),'no');eq(host.modernz_state.tc_left_rem,true)
    eq(host.modernz_state.tc_ms,true);eq(host.modernz_state.persistent_progress_toggle,true)
    for id in pairs(changes) do eq(host.field('modernz.'..id).status,'preview') end
    host.send('cancel',token,'controlbar')
    eq(host.modernz_value('scalewindowed'),1.1);eq(host.modernz_value('hidetimeout'),1500)
    eq(host.modernz_value('chapter_fmt'),'Chapter %s');eq(host.modernz_value('timems'),false)
    eq(host.modernz_state.persistent_progress_toggle,false);eq(host.modernz_value('keeponpause'),'no')
    for id in pairs(changes) do eq(host.field('modernz.'..id).can_cancel,false) end
end
function actions_require_current_token_and_fixed_allowlist()
    local host=instance(79);local token=host.open();local before=#host.commands
    host.send('open-action','stale','shortcuts.open')
    host.send('open-action',token,'edit.anything');eq(#host.commands,before)
    for _,action in ipairs(host.state().actions) do host.send('open-action',token,action.id) end
    eq(#host.commands,before+5)
    eq(host.commands[before+1][1],'script-binding');eq(host.commands[before+1][2],'user_shortcuts/open')
    eq(host.commands[before+2][2],'mpvnet');eq(host.commands[before+2][4],'mpv.conf')
    host.send('editor-close',token);before=#host.commands
    host.send('open-action',token,'open.config-folder');eq(#host.commands,before)
end

function explicit_values_equal_to_baseline_keep_the_override()
    local host=instance(80);host.open()
    save(host,'audio','{"volume":75,"mute":true,"alang":"jpn"}');writer('writer-ok')
    save(host,'subtitles','{"sub-visibility":true,"slang":"eng","sub-font":"Default Font"}');writer('writer-ok')
    save(host,'window','{"fullscreen":false,"ontop":false}');writer('writer-ok')
    save(host,'controlbar','{"modernz.timems":false,"modernz.chapter_fmt":true,"modernz.keeponpause":"no"}');writer('writer-ok')
    local saved=assert(model.document(files[user_path],decode,parser)).values
    eq(saved.volume,75);eq(saved.mute,true);eq(saved.fullscreen,false);eq(saved['modernz.timems'],false)
    eq(host.field('fullscreen').has_override,true);eq(host.field('modernz.timems').has_override,true)
    local fresh=instance(81,{'user_settings'})
    fresh.set('volume',100);fresh.set('mute',false);fresh.set('fullscreen',true);fresh.set('ontop',true)
    fresh.load('settings_options')
    eq(fresh.field('volume').effective,100);eq(fresh.field('mute').effective,false)
    fresh.hook('on_load')
    eq(fresh.field('volume').default,100);eq(fresh.field('volume').effective,75)
    eq(fresh.field('mute').effective,true);eq(fresh.field('fullscreen').effective,false);eq(fresh.field('ontop').effective,false)
    fresh.open();save(fresh,'audio','{"mute":false}');writer('writer-ok')
    eq(fresh.field('mute').default,false);eq(fresh.field('mute').has_override,true)
    local another=instance(85);eq(another.field('mute').default,true);eq(another.field('mute').effective,true)
    another.hook('on_load');eq(another.field('mute').effective,false)
    save(fresh,'window','{"fullscreen":null}');writer('writer-ok')
    eq(fresh.field('fullscreen').has_override,false);eq(fresh.field('fullscreen').effective,false)
end
function first_media_hook_reads_snapshot_before_delayed_notifications()
    files[user_path]='{"schema":1,"settings":{"slang":"zho","alang":"eng","sub-visibility":false,"hwdec":"no","volume":25,"mute":false}}'
    local host=instance(82,{'settings_options'})
    host.defer=true;host.load('user_settings')
    eq(host.field('hwdec').effective,'auto-safe');eq(host.field('volume').effective,75)
    host.event('start-file');host.hook('on_load')
    eq(host.field('hwdec').effective,'no');eq(host.field('slang').effective,'zho')
    eq(host.field('sub-visibility').effective,false);eq(host.field('alang').effective,'eng')
    eq(host.field('volume').effective,25);eq(host.field('mute').effective,false)
    host.set('volume',40);host.flush();host.event('file-loaded');host.poll();host.hook('on_load')
    eq(host.field('volume').effective,40)
    -- If no valid preference existed at startup, repairing it later cannot
    -- suddenly reset playback's volume or mute halfway through this instance.
    files[user_path]='{"schema":7}'
    local broken=instance(83);broken.event('start-file');broken.hook('on_load')
    files[user_path]='{"schema":1,"settings":{"volume":10,"mute":false}}';broken.poll()
    eq(broken.field('volume').saved,10);eq(broken.field('volume').effective,75)
    eq(broken.field('mute').effective,true)
end

function manual_modernz_actions_invalidate_owned_preview()
    local host=instance(84);local token=host.open()
    host.send('preview',token,'modernz.timecurrent','false')
    eq(host.modernz_state.tc_left_rem,true)
    host.modernz_manual_time();eq(host.modernz_state.tc_left_rem,false)
    host.send('cancel',token,'controlbar');eq(host.modernz_state.tc_left_rem,false)
    eq(host.field('modernz.timecurrent').can_cancel,false)
    host.send('preview',token,'modernz.persistent_progress','true')
    host.bindings['modernz/progress-toggle']();eq(host.modernz_state.persistent_progress_toggle,false)
    host.send('cancel',token,'controlbar');eq(host.modernz_state.persistent_progress_toggle,false)
    eq(host.field('modernz.persistent_progress').can_cancel,false)
end

function saved_modernz_booleans_and_strings_defer_other_instances()
    local first,second=instance(86),instance(87);local token=first.open()
    save(first,'controlbar','{"modernz.chapter_fmt":false,"modernz.timecurrent":false,"modernz.timems":true,"modernz.persistent_progress":true,"modernz.keeponpause":"bottombar","modernz.scalefullscreen":1.8,"modernz.hidetimeout":2}');writer('writer-ok')
    eq(first.field('modernz.chapter_fmt').saved,false);eq(first.modernz_value('chapter_fmt'),'no')
    eq(first.modernz_state.tc_left_rem,true);eq(first.modernz_state.tc_ms,true)
    eq(first.modernz_state.persistent_progress_toggle,true)
    first.send('cancel',token,'controlbar');eq(first.modernz_value('chapter_fmt'),'no')
    second.poll();eq(second.field('modernz.chapter_fmt').saved,false)
    eq(second.modernz_value('chapter_fmt'),'Chapter %s');eq(second.field('modernz.chapter_fmt').status,'pending-media')
    second.media();eq(second.modernz_value('chapter_fmt'),'no');eq(second.modernz_state.tc_left_rem,true)
    eq(second.modernz_state.tc_ms,true);eq(second.modernz_state.persistent_progress_toggle,true)
    eq(second.modernz_value('keeponpause'),'bottombar');eq(second.modernz_value('scalefullscreen'),1.8)
    eq(second.modernz_value('hidetimeout'),2000)
end

function host_remember_volume_orders_apply_only_at_first_load()
    for index,order in ipairs({'scripts-first','host-first'}) do
        files[user_path]='{"schema":1,"settings":{"volume":0,"mute":false}}'
        local load_order
        if order=='host-first' then load_order={'user_settings'} end
        local host=instance(90+index,load_order)
        host.set('volume',87);host.set('mute',true)
        if order=='host-first' then host.load('settings_options') end
        eq(host.field('volume').effective,87);eq(host.field('mute').effective,true)
        eq(host.field('volume').default,87);eq(host.field('volume').saved,0)
        eq(host.field('volume').status,'pending-startup');eq(host.field('mute').status,'pending-startup')
        eq(host.field('volume').default_source,'宿主首次播放前设置')
        local function audio_writes()
            local count=0
            for _,write in ipairs(host.writes) do if write[1]=='volume' or write[1]=='mute' then count=count+1 end end
            return count
        end
        local writes=audio_writes()
        host.event('start-file');eq(audio_writes(),writes)
        host.hook('on_load');eq(host.field('volume').effective,0);eq(host.field('mute').effective,false)
        eq(audio_writes(),writes+2)
        eq(host.field('volume').default,87);eq(host.field('mute').default,true)
        eq(host.field('volume').status,'effective');eq(host.field('mute').status,'effective')
        host.set('volume',33);host.set('mute',true);host.media();host.poll();host.media()
        eq(audio_writes(),writes+4)
        eq(host.field('volume').effective,33);eq(host.field('mute').effective,true)
    end
end
function first_load_uses_frozen_startup_snapshot_despite_new_save()
    files[user_path]='{"schema":1,"settings":{"volume":25,"mute":false}}'
    local host=instance(93);host.open()
    save(host,'audio','{"volume":40,"mute":true}');writer('writer-ok')
    eq(host.field('volume').saved,40);eq(host.field('volume').effective,75)
    host.hook('on_load')
    eq(host.field('volume').effective,25);eq(host.field('mute').effective,false)
    eq(host.field('volume').saved,40);eq(host.field('mute').saved,true)
    eq(host.field('volume').status,'pending-startup');eq(host.field('mute').status,'pending-startup')
    host.poll();host.media();eq(host.field('volume').effective,25);eq(host.field('mute').effective,false)
    local next_host=instance(94);next_host.hook('on_load')
    eq(next_host.field('volume').effective,40);eq(next_host.field('mute').effective,true)
end
function inherited_startup_stays_inherited_when_saved_before_first_load()
    local host=instance(95);host.open()
    save(host,'audio','{"volume":0,"mute":false}');writer('writer-ok')
    host.set('volume',88);host.set('mute',true)
    eq(host.field('volume').default,88);eq(host.field('volume').saved,0)
    local count=0
    for _,write in ipairs(host.writes) do if write[1]=='volume' or write[1]=='mute' then count=count+1 end end
    host.hook('on_load')
    eq(host.field('volume').effective,88);eq(host.field('mute').effective,true)
    local after=0
    for _,write in ipairs(host.writes) do if write[1]=='volume' or write[1]=='mute' then after=after+1 end end
    eq(after,count);eq(host.field('volume').status,'pending-startup')
end
function invalid_bootstrap_cannot_be_repaired_into_this_startup()
    for index,late in ipairs({false,true}) do
        files[user_path]='{"schema":7}'
        local host=instance(96+index,late and {'user_settings'} or nil)
        files[user_path]='{"schema":1,"settings":{"volume":0,"mute":false}}';host.poll()
        if late then host.load('settings_options') end
        eq(host.field('volume').saved,0);eq(host.field('mute').saved,false)
        host.hook('on_load');eq(host.field('volume').effective,75);eq(host.field('mute').effective,true)
        eq(host.field('volume').status,'pending-startup');eq(host.field('mute').status,'pending-startup')
        -- A later malformed edit preserves the already published valid bus.
        local bus=host.properties['user-data/mpvnet/settings-values']
        files[user_path]='{"schema":8}';host.poll()
        eq(host.properties['user-data/mpvnet/settings-values'],bus)
        host.media();eq(host.properties.volume,75);eq(host.properties.mute,true)
    end
end
function equal_startup_override_is_pending_until_first_load_and_baseline_refreshes()
    files[user_path]='{"schema":1,"settings":{"volume":75,"mute":false}}'
    local host=instance(99)
    eq(host.field('volume').effective,75);eq(host.field('volume').saved,75)
    eq(host.field('volume').status,'pending-startup')
    host.set('volume',82);host.set('mute',true)
    eq(host.field('volume').default,82);eq(host.field('volume').saved,75)
    host.hook('on_load');eq(host.field('volume').default,82);eq(host.field('volume').effective,75)
    eq(host.field('mute').default,true);eq(host.field('mute').effective,false)
end

function failed_first_media_initialization_is_not_retried_on_media_change()
    files[user_path]='{"schema":1,"settings":{"volume":0,"mute":false}}'
    local host=instance(100);host.fail_audio=true;host.hook('on_load')
    eq(host.field('volume').status,'apply-failed');eq(host.field('mute').status,'apply-failed')
    eq(host.field('volume').effective,75);eq(host.field('mute').effective,true)
    host.fail_audio=false;host.poll();host.media();host.media()
    eq(host.field('volume').effective,75);eq(host.field('mute').effective,true)
    eq(host.field('volume').status,'apply-failed')
    local count=0
    for _,write in ipairs(host.writes) do if write[1]=='volume' or write[1]=='mute' then count=count+1 end end
    eq(count,2)
end

function package_language_defaults_come_from_actual_startup_configuration()
    eq(package_options.slang,'zh,zho,chi,ja,jpn,en,eng')
    eq(package_options.alang,'');eq(package_options['sub-visibility'],true)
    for _,id in ipairs({'slang','alang','sub-visibility'}) do eq(model.field(id).default,package_options[id]) end
    for _,order in ipairs({{'user_settings','settings_options'},{'settings_options','user_settings'}}) do
        local host=instance(101,order,package_options)
        for id,value in pairs(package_options) do
            eq(host.field(id).saved,value);eq(host.field(id).default,value)
            eq(host.field(id).effective,value);eq(host.field(id).has_override,false)
            eq(host.field(id).default_source,'播放器启动配置')
        end
        host.media()
        eq(host.field('slang').effective,package_options.slang)
        eq(host.field('alang').effective,'');eq(host.field('sub-visibility').effective,true)
        -- Inherited preferences do not manufacture a track ID or rewrite a
        -- per-file choice; mpv owns selection from these startup options.
        for _,write in ipairs(host.writes) do
            assert(write[1]~='sid' and write[1]~='aid' and not write[1]:find('file-local-options/',1,true))
        end
    end
end

function language_defaults_preserve_advanced_configuration_and_explicit_empty_values()
    for _,slang in ipairs({'fr,zh-Hant',''}) do
        local custom={slang=slang,alang='deu,eng',['sub-visibility']=false}
        local host=instance(102,{'user_settings','settings_options'},custom)
        host.media()
        for id,value in pairs(custom) do
            eq(host.field(id).default,value);eq(host.field(id).saved,value)
            eq(host.field(id).effective,value);eq(host.field(id).has_override,false)
        end
    end
    files[user_path]='{"schema":1,"settings":{"slang":"","alang":"custom-Lang,jpn","sub-visibility":false,"future":42}}'
    local original=files[user_path]
    local host=instance(103,{'settings_options','user_settings'},package_options)
    eq(files[user_path],original);eq(host.field('slang').has_override,true)
    eq(host.field('slang').saved,'');eq(host.field('slang').status,'pending-media')
    host.hook('on_load')
    eq(host.field('slang').effective,'');eq(host.field('alang').effective,'custom-Lang,jpn')
    eq(host.field('sub-visibility').effective,false);eq(files[user_path],original)
    host.open()
    save(host,'subtitles','{"slang":null,"sub-visibility":null}');writer('writer-ok')
    save(host,'audio','{"alang":null}');writer('writer-ok')
    local doc=assert(model.document(files[user_path],decode,parser))
    eq(doc.values.slang,nil);eq(doc.values.alang,nil);eq(doc.values['sub-visibility'],nil)
    assert(files[user_path]:find('"future":42',1,true))
    eq(host.field('slang').saved,package_options.slang)
    eq(host.field('slang').effective,'');eq(host.field('sub-visibility').effective,false)
    eq(host.field('slang').has_override,false)
    host.media()
    eq(host.field('slang').effective,package_options.slang)
    eq(host.field('alang').effective,'');eq(host.field('sub-visibility').effective,true)
end
