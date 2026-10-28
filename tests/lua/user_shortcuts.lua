local model = (function()
-- MODEL SOURCE IS INSERTED HERE
end)()
local files, requests, commands, timers, bindings, events, messages, removed = {}, {}, {}, {}, {}, {}, {}, {}
local config = 'X:/config/'
local user_path = config .. 'mpvnet-user.json'
local properties = {pid=123, ['options/input-ipc-server']=''}
local open_failure, key_failure
local function eq(actual, expected)
    assert(actual == expected, 'expected '..tostring(expected)..', got '..tostring(actual))
end
local function contains(values, wanted)
    for _, value in ipairs(values) do if value == wanted then return true end end
    return false
end
local function utf8(code)
    if code < 128 then return string.char(code) end
    if code < 2048 then return string.char(192+math.floor(code/64),128+code%64) end
    if code < 65536 then return string.char(224+math.floor(code/4096),128+math.floor(code/64)%64,128+code%64) end
    return string.char(240+math.floor(code/262144),128+math.floor(code/4096)%64,128+math.floor(code/64)%64,128+code%64)
end
-- Host-only scalar JSON conversion. Production structural validation is real.
local function decode(text)
    if text == 'writer-ok' then return {ok=true} end
    if text == 'writer-conflict' then return {ok=false, conflict=true} end
    if text == 'writer-failed' then return {ok=false} end
    if text:sub(1,1) ~= '"' or text:sub(-1) ~= '"' then return nil end
    local result, i = {}, 2
    local escapes = {['"']='"', ['\\']='\\', ['/']='/', b='\b', f='\f', n='\n', r='\r', t='\t'}
    while i < #text do
        local c = text:sub(i,i)
        if c == '\\' then
            local e = text:sub(i+1,i+1)
            if e == 'u' then
                local code = tonumber(text:sub(i+2,i+5),16); i = i+6
                if code >= 0xD800 and code <= 0xDBFF then
                    code = 65536+(code-0xD800)*1024+tonumber(text:sub(i+2,i+5),16)-0xDC00; i=i+6
                end
                result[#result+1] = utf8(code)
            else result[#result+1]=assert(escapes[e]); i=i+2 end
        else result[#result+1]=c; i=i+1 end
    end
    return table.concat(result)
end
local function encode(value)
    if type(value) == 'string' then
        return '"' .. value:gsub('[%z\1-\31\\"]', function(c)
            if c == '\\' or c == '"' then return '\\'..c end
            return string.format('\\u%04x',c:byte())
        end) .. '"'
    elseif type(value) == 'boolean' or type(value) == 'number' then return tostring(value)
    elseif type(value) == 'table' then
        local parts={}
        for k,v in pairs(value) do parts[#parts+1]=encode(k)..':'..encode(v) end
        return '{'..table.concat(parts,',')..'}'
    end
    return 'null'
end
local utils = {parse_json=decode, format_json=encode,
    join_path=function(a,b) return a..'/'..b end,
    file_info=function(path) if files[path] ~= nil then return {is_file=true} end end}
local actual_bindings = {}
local mp = {
    get_time=function() return 1 end,
    get_script_name=function() return 'user_shortcuts' end,
    get_property_number=function(name, fallback) return properties[name] or fallback end,
    get_property=function(name, fallback) return properties[name] or fallback end,
    set_property=function(name, value) properties[name]=value; return true end,
    set_property_native=function(name,value) properties[name]=value; return true end,
    command_native=function(args)
        if args[1]=='expand-path' then return args[2]:gsub('^~~/',config) end
        error('unexpected native command')
    end,
    commandv=function(...)
        local args={...}; commands[#commands+1]=args
        if args[1]=='keybind' then
            if key_failure == args[2] then key_failure=nil; return nil end
            actual_bindings[args[2]]=args[3]
        end
        return true
    end,
    command_native_async=function(args,callback) requests[#requests+1]={args=args,callback=callback} end,
    add_key_binding=function(_,name,callback) bindings[name]=callback end,
    register_script_message=function(name,callback) messages[name]=callback end,
    register_event=function(name,callback) events[name]=callback end,
    add_periodic_timer=function(period,callback) eq(period,1); timers[#timers+1]=callback end,
}
package.loaded['mp'],package.loaded['mp.utils']=mp,utils
dofile=function(path)
    if path == config..'script-modules/user-shortcuts.lua' then return model end
    return {powershell=function() return 'powershell.exe' end}
end
os.getenv=function(name) if name=='TEMP' then return 'X:/temp' end end
os.remove=function(path) removed[#removed+1]=path; files[path]=nil; return true end
io.open=function(path,mode)
    if mode=='rb' then
        if files[path] == nil then return nil,'missing',2 end
        if open_failure=='read' and path==user_path then return nil,'denied',13 end
        return {read=function(_,count) return files[path]:sub(1,count) end, close=function() return true end}
    end
    assert(mode=='wb'); assert(path:find('X:/temp/mpvnet-shortcuts-',1,true)==1,'write outside owned temp')
    if open_failure=='write' then return nil,'denied',13 end
    return {write=function(_,data) files[path]=data; return true end, close=function() return true end}
end
files[config..'input.conf']=input_source
-- INITIAL DOCUMENT IS INSERTED HERE

-- SCRIPT SOURCE IS INSERTED HERE

local function state() return properties['user-data/mpvnet/shortcuts'] end
local function doc(raw) local result,err=model.document(raw,decode);assert(result,err);return result end
local function resolve(raw,catalog)
    local result,err=model.resolve(catalog or model.catalog(input_source),doc(raw));assert(result,err);return result
end
local function action(mapping,id)
    for _,entry in ipairs(mapping.actions) do if entry.id==id then return entry end end
    error('unknown action')
end
local function update(raw) files[user_path]=raw;timers[1]() end
local function save(shortcuts)
    messages.save(state().editor_token,state().revision,shortcuts)
end
local function request(index)
    local job=requests[index or #requests];assert(job,'missing async job')
    local args=job.args.args;local path=args[#args];local raw=assert(files[path])
    local root,err=model.parse(raw,decode);assert(root,err)
    return job,root,raw,path
end
local function succeed()
    local job,root=request()
    local node=root.values.document_text;assert(node and node.kind=='string')
    files[user_path]=node.value
    job.callback(true,{status=0,stdout='writer-ok'})
end
local function reject(shortcuts,catalog)
    local result=model.resolve(catalog or model.catalog(input_source),doc('{"schema":1,"shortcuts":'..shortcuts..'}'))
    assert(not result,'mapping should be rejected')
end

function catalog_defaults()
    local catalog=model.catalog(input_source)
    assert(#catalog.actions>39)
    local total=0;for _,entry in ipairs(catalog.actions) do total=total+#entry.default_keys end;eq(total,40)
    local info=catalog.by_id['tools.media-info'];eq(#info.default_keys,2);eq(info.default_keys[1],'Ctrl+i');eq(info.default_keys[2],'Ctrl+m')
    eq(catalog.by_id['tools.stats'].default_keys[1],'Tab')
    eq(catalog.baseline.F2,'ignore');eq(catalog.baseline.M,'script-binding playback_feedback/jump-mark')
    local changed=model.catalog(input_source:gsub('Space script%-binding playback_feedback/space','F7 script-binding playback_feedback/space'))
    eq(changed.by_id['playback.pause'].default_keys[1],'F7')
end

function key_normalization()
    local cases={['shift+m']='M',['CTRL+Shift+M']='Ctrl+Shift+m',['alt+CTRL+f2']='Ctrl+Alt+F2',
        ['TAB']='Tab',['Delete']='Del',['Ctrl+Shift+1']='Ctrl+!',['Shift+;']=':',
        ['Ctrl+Shift+?']='Ctrl+?',['Ctrl++']='Ctrl++',['Alt+Shift+[']='Alt+{',['Ctrl+M']='Ctrl+m'}
    for raw,expected in pairs(cases) do eq(model.normalize_key(raw),expected) end
    for _,raw in ipairs({'','Win+a','Meta+a','MBTN_LEFT','F25','Ctrl+Ctrl+a','a b','Ctrl+','é','F01','Ctrl+Up','Shift+Delete'}) do eq(model.normalize_key(raw),nil) end
end

function swap_disable_and_reset()
    local catalog=model.catalog(input_source)
    local original=resolve('')
    local changed=resolve('{"schema":1,"shortcuts":{"playback.pause":["Right"],"playback.seek-forward":["Space"],"tools.media-info":[]}}')
    eq(changed.by_key.Right.id,'playback.pause');eq(changed.by_key.Space.id,'playback.seek-forward')
    eq(changed.by_key['Ctrl+i'],nil);eq(changed.by_key['Ctrl+m'],nil)
    local plan={};for _,item in ipairs(model.plan(catalog,original,changed)) do plan[item.key]=item.command end
    eq(plan.Right,'script-binding playback_feedback/space');eq(plan['Ctrl+i'],'ignore')
    local custom=resolve('{"schema":1,"shortcuts":{"playback.pause":["F2"]}}')
    plan={};for _,item in ipairs(model.plan(catalog,custom,original)) do plan[item.key]=item.command end
    eq(plan.F2,'ignore');eq(plan.Space,'script-binding playback_feedback/space')
    catalog.baseline.F2='no-osd show-text "baseline"'
    plan={};for _,item in ipairs(model.plan(catalog,custom,original)) do plan[item.key]=item.command end
    eq(plan.F2,'no-osd show-text "baseline"')
end

function mapping_rejections()
    reject('{"playback.pause":["Right"]}')
    reject('{"playback.pause":["F2","F2"]}')
    reject('{"playback.pause":["F2","F3","F4"]}')
    reject('{"playback.pause":{}}');reject('{"playback.pause":[5]}')
    for _,key in ipairs({'Esc','Up','Down','Delete','Ctrl+f','Alt+F4','_','MBTN_LEFT','Win+a'}) do
        reject('{"playback.pause":['..encode(key)..']}')
    end
    local foreign=model.catalog(input_source..'\nF2 no-osd show-text "foreign"\n')
    reject('{"playback.pause":["F2"]}',foreign)
    assert(resolve('{"schema":1,"shortcuts":{"playback.pause":["Ctrl+_"]}}'))
end

function complete_conflict_candidates()
    local catalog=model.catalog(input_source)
    local mapping,err,detail=model.resolve(catalog,doc('{"schema":1,"shortcuts":{"playback.pause":["Right"],"subtitle.copy":["F3"]}}'))
    eq(mapping,nil);assert(err);eq(detail.kind,'mapping-conflict');eq(#detail.actions,#catalog.actions)
    eq(action(detail,'playback.pause').keys[1],'Right');eq(action(detail,'subtitle.copy').keys[1],'F3')
    mapping,err,detail=model.resolve(catalog,doc('{"schema":1,"shortcuts":{"playback.pause":["Right"],"subtitle.copy":["MBTN_LEFT"]}}'))
    eq(mapping,nil);assert(err);eq(detail,nil)
end

function repair_startup_conflict()
    eq(state().repairable,true);assert(state().error~='');eq(#state().editable_actions,#state().actions)
    eq(action(state(),'playback.pause').keys[1],'Space');eq(action(state(),'subtitle.copy').keys[1],'Ctrl+c')
    local draft={actions=state().editable_actions}
    eq(action(draft,'playback.pause').keys[1],'Right');eq(action(draft,'subtitle.copy').keys[1],'F3')
    assert(contains(state().forward_keys,'Space'));assert(not contains(state().forward_keys,'F3'))
    local original=files[user_path]
    save('{"playback.pause":["Right"],"subtitle.copy":["F3"]}')
    eq(#requests,0);eq(state().repairable,true);assert(state().save_error~='');eq(files[user_path],original)
    save('{"playback.pause":["F2"],"subtitle.copy":["F3"]}')
    eq(state().saving,true);local job,root=request();eq(root.values.expected_text.value,original)
    succeed();eq(state().repairable,false);eq(state().error,'');eq(state().save_error,'')
    eq(action(state(),'playback.pause').keys[1],'F2');eq(action(state(),'subtitle.copy').keys[1],'F3')
    assert(files[user_path]:find('"future.action":[]',1,true));assert(files[user_path]:find('"null":null',1,true))
end

function native_catalog_coverage()
    local catalog=model.catalog(input_source)
    for _,command in ipairs(native_commands) do
        if command=='ignore' then
            eq(catalog.by_command[command],nil) -- A mouse no-op is not a callable feature.
        else
            local entry=catalog.by_command[command]
            assert(entry,'uncovered native default: '..command)
            local source=catalog.command_sources[command]
            eq(source.id,entry.id);eq(source.command,entry.command)
            assert(source.kind=='exact' or source.kind=='equivalent')
        end
    end
    local aliases={
        ['script-message-to mpvnet play-pause']='playback.pause',
        ['script-binding playback_feedback/toggle-pause']='playback.pause',
        ['playlist-prev']='playlist.previous',['playlist-next']='playlist.next',
        ['frame-step']='playback.frame-forward',['frame-back-step']='playback.frame-back',
        ['seek 5']='playback.seek-forward-5',['no-osd seek 5 exact']='playback.seek-forward-5',
        ['script-message-to playback_feedback set-speed 1']='playback.speed-reset',
        ['cycle sub-visibility']='subtitle.toggle', ['script-binding osc/visibility']='window.osc',
    }
    for command,id in pairs(aliases) do eq(catalog.by_command[command].id,id) end
    assert(catalog.by_command['multiply speed 2.0'].id~='playback.speed-up')
    assert(catalog.by_command['async screenshot'].id~='capture.screenshot')
    assert(catalog.by_command['script-message-to mpvnet open-clipboard'].id~='tools.clipboard-url')
    assert(catalog.by_command['script-binding select/select-playlist'].id~='playlist.toggle')
    assert(catalog.by_command['add sub-scale 0.1'].id~=catalog.by_command['script-binding subtitle_controls/size-up'].id)
    eq(catalog.by_command['show-progress'].id,'tools.progress')
    eq(catalog.by_command['script-message-to playback_feedback show-time'].id,'playback.show-time')
    assert(catalog.by_command['show-progress'].id~=catalog.by_command['script-message-to playback_feedback show-time'].id)
end

function menu_catalog_coverage()
    local catalog=model.catalog(input_source)
    local containers={['近期文件']=true,['章节']=true,['标题']=true,['音频设备']=true,['轨道']=true,['配置文件']=true}
    for line in (input_source..'\n'):gmatch('(.-)\r?\n') do
        local command,path=line:match('^%s*_%s+(.+)%s+#menu:%s*(.-)%s*$')
        if command then
            command=command:gsub('%s+$','')
            if command=='ignore' then
                local leaf=path:match('([^>]+)$'):gsub('^%s+',''):gsub('%s+$','')
                assert(leaf=='-' or containers[leaf],'unexplained non-executable menu node: '..path)
            else assert(catalog.by_command[command],'uncovered menu action: '..command..' / '..path) end
        end
    end
end

function project_catalog_coverage()
    local catalog=model.catalog(input_source)
    local expected={
        ['script-binding playback_feedback/open-media-path']='file.open-location',
        ['script-binding playback_feedback/copy-media-path']='file.copy-location',
        ['script-binding playback_feedback/revert-seek']='playback.revert-seek',
        ['script-binding playback_feedback/audio-only']='audio.only',
        ['script-binding subtitle_controls/cycle-prev']='subtitle.cycle-prev',
        ['script-binding modernz/progress-toggle']='window.persistent-progress',
        ['no-osd add volume 5']='audio.volume-up-large',['no-osd add volume -5']='audio.volume-down-large',
        ['no-osd set volume 100']='audio.volume-reset',
        ['script-message-to playback_feedback add-speed 0.25']='playback.speed-add-up',
        ['script-message-to playback_feedback add-speed -0.25']='playback.speed-add-down',
        ['cycle window-minimized']='window.minimize',['cycle window-maximized']='window.maximize',
        ['script-message-to mpvnet show-profiles']='tools.profiles',
    }
    for command,id in pairs(expected) do eq(assert(catalog.by_command[command],command).id,id) end
    for _,value in ipairs({'0.5','0.75','1','1.25','1.5','2'}) do assert(catalog.by_command['script-message-to playback_feedback set-speed '..value]) end
    for _,value in ipairs({'OFF','QUALITY','SMOOTH','ANIME_LIGHT','ANIME_STRONG'}) do assert(catalog.by_command['script-message-to enhancement_controls set-preset '..value]) end
    for _,value in ipairs({'webp','gif','mp4'}) do assert(catalog.by_command['script-message-to capture_controls set-default-format '..value]) end
    for _,entry in ipairs(catalog.actions) do
        if entry.command:match('^script%-binding select/') or entry.id=='subtitle.select' or entry.id=='tools.native-input-editor'
            or entry.id=='tools.config-editor' or entry.id=='tools.shortcuts-editor' then eq(entry.focus_main,true) end
    end
    local hostile=model.catalog(input_source..'\n_ run arbitrary-user-command #menu: 工具与设置 > test\n')
    eq(hostile.by_command['run arbitrary-user-command'],nil)
    assert(not model.prepare(catalog,doc(''),'{"run arbitrary-user-command":["F2"]}',decode,encode,false))
end

function new_action_bindings()
    local catalog=model.catalog(input_source)
    local original={
        'danmaku.toggle','playback.pause','playback.seek-back','playback.seek-forward','playback.seek-back-small',
        'playback.seek-forward-small','playback.seek-back-large','playback.seek-forward-large','playback.frame-back',
        'playback.frame-forward','playback.reload','playback.speed-down','playback.speed-up','playback.speed-reset',
        'subtitle.toggle','subtitle.select-line','subtitle.seek-prev','subtitle.seek-next','subtitle.delay-down',
        'subtitle.delay-up','subtitle.delay-reset','subtitle.adjust','subtitle.copy','playback.save-mark',
        'playback.jump-mark','playback.ab-loop','playback.file-loop','playlist.previous','playlist.next','window.fullscreen',
        'window.ontop','window.scale-reset','tools.media-info','tools.stats','window.osc','tools.console',
        'tools.copy-time','tools.clipboard-url','playlist.toggle',
    }
    local old={};for _,id in ipairs(original) do old[id]=true;assert(catalog.by_id[id]) end
    for _,entry in ipairs(catalog.actions) do if not old[entry.id] then eq(#entry.default_keys,0) end end
    local draft='{"schema":1,"shortcuts":{"audio.mute":["j"],"audio.volume-up":["F6"],"capture.format-gif":["F7"]}}'
    local mapping=resolve(draft)
    eq(mapping.by_key.j.command,'cycle mute');eq(mapping.by_key.F6.command,'add volume 2')
    eq(mapping.by_key.F7.command,'script-message-to capture_controls set-default-format gif')
    eq(mapping.by_key.Space.id,'playback.pause');assert(contains(mapping.forward_keys,'j'))
    local commands={};for _,entry in ipairs(model.plan(catalog,resolve(''),mapping)) do commands[entry.key]=entry.command end
    eq(commands.j,'cycle mute');eq(commands.F6,'add volume 2');eq(commands.F7,'script-message-to capture_controls set-default-format gif')
end

function trial_catalog()
    local catalog=model.catalog(input_source)
    eq(#catalog.actions,195)
    eq(catalog.by_id['tools.settings-editor'].command,'script-binding user_settings/open')
    eq(#catalog.by_id['tools.settings-editor'].default_keys,0)
    eq(catalog.by_id['danmaku.renderer-overlay'],nil);eq(catalog.by_id['danmaku.renderer-ass'],nil)
    local with_trial=input_source..'\n_ script-message-to bilibiliAssert renderer overlay #menu: 字幕与弹幕 > 固定字号试用\n'
        ..'_ script-message-to bilibiliAssert renderer ass #menu: 字幕与弹幕 > 原ASS\n'
    catalog=model.catalog(with_trial)
    eq(#catalog.actions,197)
    eq(catalog.by_id['danmaku.renderer-overlay'].command,'script-message-to bilibiliAssert renderer overlay')
    eq(catalog.by_id['danmaku.renderer-ass'].command,'script-message-to bilibiliAssert renderer ass')
    eq(#catalog.by_id['danmaku.renderer-overlay'].default_keys,0);eq(#catalog.by_id['danmaku.renderer-ass'].default_keys,0)
    catalog=model.catalog(input_source..'\n# _ script-message-to bilibiliAssert renderer overlay #menu: commented\n')
    eq(catalog.by_id['danmaku.renderer-overlay'],nil)
end

function reset_startup_conflict()
    eq(state().repairable,true);messages.reset(state().editor_token,state().revision)
    eq(state().saving,true);succeed();eq(state().repairable,false);eq(state().error,'')
    eq(action(state(),'playback.pause').keys[1],'Space');eq(action(state(),'subtitle.copy').keys[1],'Ctrl+c')
    assert(files[user_path]:find('"future.action":[]',1,true));assert(files[user_path]:find('"null":null',1,true))
end

function json_validation()
    for _,raw in ipairs({'','[]','{"schema":2}','{"schema":1,"shortcuts":[]}',
        '{"schema":1,}','{"schema":1,"schema":1}','{"schema":1,"x":"\\uD800"}',
        '{"schema":1,"x":"\\uDC00"}','{"schema":1,"x":"\\q"}',
        '{"schema":01}','{"schema":1}false','{"schema":1,"x":1e}',
        '{"schema":1,"x":"'..string.char(0xED,0xA0,0x80)..'"}'}) do
        if raw ~= '' then assert(not model.document(raw,decode),'must reject '..raw) end
    end
    assert(doc('\239\187\191{"schema":1,"x":"\\uD83D\\uDE00"}'))
    assert(not model.document(string.rep(' ',model.max_bytes+1),decode))
end

function unknown_fields_preserved()
    local raw='{ "schema":1, "future": {"nothing":null,"emptyObj":{},"emptyList":[],"nested":[{},[],null]}, "shortcuts":{"future.action":{"x":null},"playback.pause":["F2"]} }'
    local catalog=model.catalog(input_source)
    local next_raw, mapping=model.prepare(catalog,doc(raw),'{"playback.pause":["F3"],"tools.media-info":[]}',decode,encode,false)
    assert(next_raw,mapping);assert(next_raw:find('"nothing":null,"emptyObj":{},"emptyList":[],"nested":[{},[],null]',1,true))
    assert(next_raw:find('"future.action":{"x":null}',1,true));assert(next_raw:find('"tools.media-info":[]',1,true))
    local reset=model.prepare(catalog,doc(next_raw),'',decode,encode,true)
    assert(reset:find('"future.action":{"x":null}',1,true));assert(not reset:find('"playback.pause"',1,true))
    local new=model.prepare(catalog,doc(''),'{"playback.pause":["Space"]}',decode,encode,false)
    eq(new,'{"schema":1,"shortcuts":{}}')
end

function direct_default_bindings()
    for _,args in ipairs(commands) do
        eq(args[1],'keybind');eq(#args,3)
        assert(not args[3]:find('user_shortcuts',1,true),'callback forwarding must not replace original commands')
        assert(not args[2]:find('MBTN',1,true));assert(not model.is_reserved(args[2]))
    end
    save('{"playback.pause":["F2"]}');succeed()
    eq(actual_bindings.F2,'script-binding playback_feedback/space');eq(actual_bindings.Space,'ignore')
    -- keybind writes only default bindings; it never disables force/local sections.
    for _,args in ipairs(commands) do assert(args[1]~='disable-section' and args[1]~='define-section') end
end

function release_changed_keys()
    commands={};update('{"schema":1,"shortcuts":{"playback.pause":["F2"]}}')
    local first_bind, released=nil,{}
    for i,args in ipairs(commands) do
        if args[1]=='keybind' then first_bind=first_bind or i
        elseif args[1]=='no-osd' and args[2]=='keyup' then
            assert(not first_bind,'all changed keys must release before first keybind');released[args[3]]=true
        else error('unexpected command') end
    end
    assert(released.Space and released.F2);eq(released.Left,nil);eq(released.MBTN_LEFT,nil)
    commands={};update('{"schema":1,"future":null,"shortcuts":{"playback.pause":["F2"]}}')
    for _,args in ipairs(commands) do assert(args[1]~='no-osd','unchanged mapping must keep held keys') end
end

function binding_failure()
    key_failure='F2';update('{"schema":1,"shortcuts":{"playback.pause":["F2"]}}')
    assert(state().error~='');eq(action(state(),'playback.pause').keys[1],'Space')
    eq(actual_bindings.Space,'script-binding playback_feedback/space');eq(actual_bindings.F2,'ignore')
end

function save_success()
    local before=state().revision
    save('{"playback.pause":["F2"]}')
    eq(state().saving,true);eq(state().save_serial,0);eq(actual_bindings.F2,nil)
    local job,root,raw,path=request()
    eq(job.args.args[#job.args.args-2],'Save');eq(root.values.expected_exists.kind,'false')
    eq(root.values.expected_text.value,'');eq(root.values.settings_path.value,user_path)
    succeed()
    eq(state().saving,false);eq(state().save_serial,1);eq(state().save_error,'');assert(state().revision~=before)
    eq(action(state(),'playback.pause').keys[1],'F2');eq(files[path],nil)
    assert(contains(state().forward_keys,'F2'));assert(not contains(state().forward_keys,'Space'))
    assert(contains(state().opening_keys,'Ctrl+i'));assert(contains(state().opening_keys,'Tab'))
end

function editor_refresh_reads_external_without_writing_or_changing_session()
    bindings.open();local token=state().editor_token
    eq(state().refresh_id,'')
    local revision=state().revision;local count=#requests
    local raw='{"schema":1,"settings":{"sub-scale":2},"shortcuts":{"playback.pause":["F2"]}}'
    files[user_path]=raw
    local original={};for path,text in pairs(files) do original[path]=text end
    messages['editor-refresh'](token,'close-1')
    eq(state().refresh_id,'close-1');assert(state().revision~=revision)
    eq(action(state(),'playback.pause').keys[1],'F2');eq(state().save_serial,0);eq(state().saving,false)
    eq(state().editor_token,token);eq(state().editor_visible,true);eq(#requests,count)
    for path,text in pairs(files) do eq(text,original[path]) end
    for path,text in pairs(original) do eq(files[path],text) end
    revision=state().revision;local before=state()
    messages['editor-refresh'](token,'close-2')
    eq(state().refresh_id,'close-2');eq(state().revision,revision);assert(state()~=before);eq(#requests,count)
    files[user_path]='{"schema":1,"shortcuts":{"playback.pause":["F3"]}}'
    messages.save(token,revision,'{"playback.pause":["F4"]}')
    eq(state().saving,false);assert(state().save_error~='')
    eq(action(state(),'playback.pause').keys[1],'F3');eq(#requests,count)
end

function editor_refresh_rejects_invalid_busy_and_shutdown_requests()
    bindings.open();local token=state().editor_token;local initial=state()
    files[user_path]='{"schema":1,"shortcuts":{"playback.pause":["F2"]}}'
    messages['editor-refresh']('wrong','valid-1');eq(state(),initial)
    for _,id in ipairs({'','bad_id','bad id','bad/id','中文',string.rep('a',65),false,123}) do
        messages['editor-refresh'](token,id);eq(state(),initial)
    end
    messages['editor-refresh'](token,nil);eq(state(),initial)
    messages['editor-refresh'](token,string.rep('a',64));eq(state().refresh_id,string.rep('a',64))
    save('{"playback.pause":["F3"]}');eq(state().saving,true)
    local busy=state();local count=#requests
    messages['editor-refresh'](token,'busy-1');eq(state(),busy);eq(#requests,count)
    local job=request();job.callback(false,{status=1,stdout='writer-failed'})
    events.shutdown();local closed=state()
    messages['editor-refresh'](token,'shutdown-1');eq(state(),closed)
end

function save_failures_and_stale()
    local before=state().revision
    save('{"playback.pause":["F2"]}')
    local job=request();job.callback(false,{status=1,stdout='writer-failed'})
    eq(files[user_path],nil);eq(actual_bindings.F2,nil);eq(state().revision,before)
    eq(state().save_serial,1);assert(state().save_error~='');eq(state().error,'')
    files[user_path]='{"schema":1,"shortcuts":{"playback.pause":["F3"]}}'
    messages.save(state().editor_token,before,'{"playback.pause":["F2"]}')
    eq(#requests,1);eq(state().save_serial,2);assert(state().save_error~='')
    eq(action(state(),'playback.pause').keys[1],'F3')
    save('{"playback.pause":["F4"]}');job=request();job.callback(true,{status=0,stdout='writer-conflict'})
    eq(state().save_serial,3);eq(actual_bindings.F4,nil)
    local serial=state().save_serial;messages.save('wrong',state().revision,'{}');eq(state().save_serial,serial)
end

function bom_save()
    local raw='\239\187\191{"schema":1,"future":null}'
    update(raw);eq(state().error,'');save('{"playback.pause":["F2"]}')
    local job,root,text=request();eq(root.values.expected_text.value,raw)
    local node=root.values.document_text;eq(node.kind,'string');eq(node.value:sub(1,1),'{')
    succeed();eq(state().error,'');eq(action(state(),'playback.pause').keys[1],'F2')
    assert(files[user_path]:find('"future":null',1,true))
end

function document_text_preserved()
    local future='"future":{"integer":123456789012345678901234567890,"fraction":0.123456789012345678901234567890,"date":"\\/Date(1700000000000)\\/","iso":"2026-10-23T12:34:56Z"}'
    local raw='{"schema":1,'..future..',"shortcuts":{}}'
    update(raw);eq(state().error,'');save('{"playback.pause":["F2"]}')
    local job,root=request();eq(root.values.document,nil)
    local node=root.values.document_text;eq(node.kind,'string')
    assert(node.value:find(future,1,true),'unknown numeric and date source text must survive request encoding')
    eq(root.values.expected_text.value,raw)
    succeed();eq(state().error,'')
    assert(files[user_path]:find(future,1,true),'writer receives original future field bytes')
end

function external_reload()
    update('{"schema":1,"shortcuts":{"playback.pause":["F2"]}}')
    eq(action(state(),'playback.pause').keys[1],'F2')
    local serial=state().save_serial
    for _,invalid in ipairs({'broken','{"schema":2}','',string.rep('x',model.max_bytes+1),
        '{"schema":1,"shortcuts":{"playback.pause":{}}}',
        '{"schema":1,"shortcuts":{"playback.pause":["Up"]}}',
        '{"schema":1,"shortcuts":{"playback.pause":["Right"],"subtitle.copy":["Win+a"]}}'}) do
        update(invalid);assert(state().error~='');eq(action(state(),'playback.pause').keys[1],'F2')
        eq(state().repairable,false)
        local count=#requests;save('{}');eq(#requests,count);assert(state().save_error~='')
    end
    files[user_path]='{"schema":1}';open_failure='read';timers[1]();assert(state().error~='')
    eq(action(state(),'playback.pause').keys[1],'F2');open_failure=nil
    files[user_path]=nil;timers[1]();eq(state().error,'');eq(action(state(),'playback.pause').keys[1],'Space')
    assert(state().save_serial>serial)
end

function runtime_reset()
    update('{"schema":1,"future":{"null":null},"shortcuts":{"future.action":[],"playback.pause":["F2"]}}')
    messages.reset(state().editor_token,state().revision);eq(state().saving,true);succeed()
    eq(action(state(),'playback.pause').keys[1],'Space');eq(actual_bindings.F2,'ignore')
    assert(files[user_path]:find('"future.action":[]',1,true));assert(files[user_path]:find('"null":null',1,true))
    eq(state().save_serial,1)
end

function editor_lifecycle()
    properties['options/input-ipc-server']='\\\\.\\pipe\\existing-instance'
    bindings.open();eq(state().editor_visible,true)
    local job,root,raw,path=request()
    eq(root.values.pipe.value,'\\\\.\\pipe\\existing-instance');eq(root.values.script.value,'user_shortcuts')
    eq(root.values.parent_pid.value,123);eq(root.values.token.value,state().editor_token)
    eq(job.args.args[#job.args.args-2],'Editor');eq(job.args.playback_only,false)
    local count=#requests;bindings.open();eq(#requests,count)
    eq(commands[#commands][2],'mpvnet-shortcuts-show')
    messages['editor-close']('wrong');eq(state().editor_visible,true)
    messages['editor-close'](state().editor_token);eq(state().editor_visible,false)
    messages['editor-ready'](state().editor_token);eq(state().editor_visible,true)
    events.shutdown();eq(commands[#commands][2],'mpvnet-shortcuts-close');eq(files[path],nil)
    job.callback(false,{status=1});assert(not files[path])
end

function write_boundaries()
    local managed=files[config..'input.conf']
    save('{"playback.pause":["F2"]}');succeed()
    eq(files[config..'input.conf'],managed)
    for _,job in ipairs(requests) do
        local args=job.args.args
        eq(args[#args-1],'-RequestPath');assert(args[#args]:find('X:/temp/mpvnet-shortcuts-',1,true)==1)
        eq(args[7],config..'helpers/shortcuts-window.ps1')
    end
    update('{"schema":1,"shortcuts":{}}')
    open_failure='write';save('{"playback.pause":["F3"]}')
    assert(state().save_error~='');eq(actual_bindings.F3,nil);eq(files[config..'input.conf'],managed)
end
