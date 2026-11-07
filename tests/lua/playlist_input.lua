-- Full production modules are loaded before this file. Only host boundaries are doubled.
local function eq(actual, expected)
    assert(actual == expected, 'expected '..tostring(expected)..', got '..tostring(actual))
end
local function host()
    local h = {properties={pid=123, ['working-directory']='X:/fixture',
        path='X:/fixture/current.mkv', ['playlist-pos']=0, pause=true,
        playlist={{id=0,filename='X:/fixture/current.mkv'}, {id=92,filename='X:/fixture/later.mp4'}},
        ['options/video-exts']={'mkv','mp4'}, ['options/audio-exts']='flac,mp3',
        ['options/sub-auto-exts']={'srt','ass'}},
        calls={}, writes={}, messages={}, jobs={}, aborted={}, removed={}, files={}, payloads={}}
    local mp = {
        get_time=function() return 1 end,
        get_property=function(name, default) local v=h.properties[name];if v~=nil then return v end;return default end,
        get_property_number=function(name, default) local v=h.properties[name];if v~=nil then return v end;return default end,
        get_property_native=function(name, default) local v=h.properties[name];if v~=nil then return v end;return default end,
        set_property_native=function(name, value)
            h.writes[#h.writes+1]={name,value};h.properties[name]=value
            if h.on_write then h.on_write(name,value) end
            return true
        end,
        command_native=function(args)
            if args[1]=='expand-path' then return args[2] end
            h.calls[#h.calls+1]=args
            if h.on_command then h.on_command(args) end
            if args[2]==h.failed_path then return nil,'command failed' end
            return true
        end,
        command_native_async=function(args, done)
            local job={args=args,done=done,id=#h.jobs+101}
            h.jobs[#h.jobs+1]=job
            return job.id
        end,
        abort_async_command=function(id) h.aborted[#h.aborted+1]=id end,
        osd_message=function(text, seconds) h.messages[#h.messages+1]={text,seconds} end,
        commandv=function(...) error('unexpected commandv') end,
    }
    local utils = {
        file_info=function(_) if h.fail=='helper' then return nil end;return {is_file=true} end,
        join_path=function(a,b) return a..'/'..b end,
        format_json=function(payload)
            h.payloads[#h.payloads+1]=payload
            if h.fail=='format' then return nil end
            if h.fail=='payload-size' then return string.rep('x',2*1024*1024+1) end
            return 'request-json'
        end,
        parse_json=function(raw)
            if h.on_parse then h.on_parse() end
            return h.response
        end,
    }
    os.getenv=function(name)
        if (name=='TEMP' or name=='TMP') and h.fail~='temp' then return 'X:/fixture/temp' end
    end
    os.remove=function(path) h.removed[#h.removed+1]=path;h.files[path]=nil;return true end
    io.open=function(path, mode)
        eq(mode,'wb')
        if h.fail=='open' then return nil end
        h.files[path]=''
        return {
            write=function(_, data) if h.fail=='write' then return nil end;h.files[path]=data;return true end,
            close=function() if h.fail=='close' then return nil end;return true end,
        }
    end
    h.controller=input_module.new(mp,utils,feedback_module.new(mp))
    function h.start(mode, operation, files) h.controller.request(mode or 'open',operation or 'files',files) end
    function h.result(entries, extra, index)
        local payload=h.payloads[index or #h.payloads]
        local data={schema=1,request_id=payload.request_id,status='ok',entries=entries or {},
            single_media=false,duplicates=0,skipped=0}
        for key,value in pairs(extra or {}) do data[key]=value end
        return data
    end
    function h.finish(data, index, ok, result)
        h.response=data
        h.jobs[index or #h.jobs].done(ok~=false, result or {status=0,stdout='response-json'})
    end
    return h
end
local function entry(path, kind) return {path='X:/fixture/'..path,kind=kind or 'media'} end
local function message(h,text,seconds)
    eq(#h.messages,1);eq(h.messages[1][1],text);eq(h.messages[1][2],seconds)
end
local function load(h,index,path,mode,exact)
    local call=h.calls[index]
    eq(call[1],'loadfile');eq(call[2],'X:/fixture/'..path);eq(call[3],mode)
    if exact then eq(#call,5);eq(call[4],-1);eq(call[5]['autocreate-playlist'],'no')
    else eq(#call,3) end
end
function request_contract()
    local h=host();local paths={'relative movie.mkv','字幕.srt'};h.start('append','paths',paths)
    eq(#h.jobs,1);local p=h.payloads[1]
    eq(p.schema,1);eq(p.mode,'append');eq(p.operation,'paths');eq(p.paths,paths)
    eq(p.parent_pid,123);eq(p.working_directory,'X:/fixture')
    eq(table.concat(p.video_exts,','),'mkv,mp4');eq(table.concat(p.audio_exts,','),'flac,mp3')
    eq(table.concat(p.subtitle_exts,','),'srt,ass');eq(#p.existing_paths,2)
    eq(p.existing_paths[1],'X:/fixture/current.mkv');eq(p.existing_paths[2],'X:/fixture/later.mp4')
    local job=h.jobs[1];eq(job.args.name,'subprocess');eq(job.args.args[1],'~~/helpers/KitPlaylistInput.exe')
    eq(job.args.args[2],'-RequestPath');eq(job.args.args[3],'X:/fixture/temp/mpvnet-input-'..p.request_id..'.json')
    eq(h.files[job.args.args[3]],'request-json');eq(job.args.capture_stdout,true)
    eq(job.args.capture_stderr,false);eq(job.args.playback_only,false);eq(#h.calls,0)
    h.finish(h.result({entry('one.mkv')}));eq(h.files[job.args.args[3]],nil)
end
function single_open()
    local h=host();h.start();h.finish(h.result({entry('one.mkv')},{single_media=true}))
    eq(#h.calls,1);load(h,1,'one.mkv','replace',false)
    eq(#h.writes,1);eq(h.writes[1][1],'pause');eq(h.writes[1][2],false);eq(#h.messages,0)
end
function mixed_open()
    local h=host();h.start();h.finish(h.result({entry('before.srt','subtitle'),entry('one.mkv'),
        entry('middle.ass','subtitle'),entry('two.mp4')}))
    eq(#h.calls,4);eq(h.calls[1][1],'sub-add');eq(h.calls[1][2],'X:/fixture/before.srt')
    load(h,2,'one.mkv','replace',true);eq(h.calls[3][1],'sub-add');load(h,4,'two.mp4','append',true)
    eq(#h.writes,1);eq(h.properties.pause,false)
end
function append_preserves_state()
    for _, empty in ipairs({false,true}) do
        local h=host()
        if empty then h.properties.playlist={};h.properties.path=nil;h.properties['playlist-pos']=-1 end
        h.start('append','clipboard');h.finish(h.result({entry('one.mkv'),entry('two.mp4')},{single_media=true}))
        eq(#h.calls,2);load(h,1,'one.mkv','append',true);load(h,2,'two.mp4','append',true)
        eq(#h.writes,0);eq(h.properties.pause,true);eq(#h.messages,0)
    end
end
function subtitle_and_native()
    local h=host();h.start();h.finish(h.result({entry('one.srt','subtitle'),entry('two.ass','subtitle')}))
    eq(#h.calls,2);eq(h.calls[1][1],'sub-add');eq(h.calls[2][1],'sub-add');eq(#h.writes,0)
    h=host();h.start();h.finish(h.result({entry('saved.m3u','native')}))
    eq(#h.calls,1);load(h,1,'saved.m3u','replace',false);eq(h.properties.pause,false)
end
function result_feedback()
    local h=host();h.start();h.finish(h.result({}, {status='cancelled'}));eq(#h.calls,0);eq(#h.writes,0);eq(#h.messages,0)
    h=host();h.start('append');h.finish(h.result({}, {duplicates=3}));eq(#h.calls,0)
    message(h,'所选文件已在播放列表中',1.5)
    h=host();h.start();h.finish(h.result({}, {skipped=2}));eq(#h.calls,0)
    message(h,'没有可添加的媒体文件',4)
    h=host();h.start('append');h.finish(h.result({entry('one.mkv')},{skipped=2,duplicates=1}))
    eq(#h.calls,1);message(h,'已跳过无法加入的文件',1.5)
end
function preparation_failures()
    for _, failure in ipairs({'temp','helper','format','payload-size','open','write','close'}) do
        local h=host();h.fail=failure;h.start()
        eq(#h.jobs,0);eq(#h.calls,0);eq(#h.writes,0);eq(#h.messages,1)
        if failure=='write' or failure=='close' then eq(#h.removed,1) else eq(#h.removed,0) end
        eq(next(h.files),nil)
    end
end
function invalid_results()
    local cases={'schema','token','json','worker','exit','missing-result','oversize','entries','kind','control-path','error','known-error','known-error-exit'}
    for _, case in ipairs(cases) do
        local h=host();h.start();local data=h.result({entry('one.mkv')});local ok,result=true,nil
        if case=='schema' then data.schema=2
        elseif case=='token' then data.request_id='old'
        elseif case=='json' then data=nil
        elseif case=='worker' then ok=false
        elseif case=='exit' then result={status=2,stdout='X:/private/secret.mkv'}
        elseif case=='oversize' then result={status=0,stdout=string.rep('x',4*1024*1024+1)}
        elseif case=='entries' then data.entries=false
        elseif case=='kind' then data.entries[1].kind='command'
        elseif case=='control-path' then data.entries[1].path='X:/private/secret\n.mkv'
        elseif case=='error' then data.status='error';data.error_code='X:/private/secret.mkv'
        elseif case=='known-error' or case=='known-error-exit' then
            data.status='error';data.error_code='native_entry_required'
            if case=='known-error-exit' then result={status=1,stdout='response-json'} end
        end
        if case=='missing-result' then h.response=data;h.jobs[1].done(true,nil)
        else h.finish(data,nil,ok,result) end
        eq(#h.calls,0);eq(#h.writes,0);eq(#h.messages,1)
        assert(not h.messages[1][1]:find('secret',1,true),'raw helper value leaked')
        if case=='known-error' or case=='known-error-exit' then message(h,'此格式请拖入播放器主窗口打开',4) end
    end
end
function stale_snapshot()
    local mutations={
        function(h) h.properties.playlist[1].id=999 end,
        function(h) h.properties.playlist[1].filename='X:/fixture/replacement.mkv' end,
        function(h) h.properties.playlist={h.properties.playlist[2],h.properties.playlist[1]} end,
        function(h) h.properties.playlist[3]={id=93,filename='X:/fixture/new.mkv'} end,
        function(h) h.properties['working-directory']='X:/elsewhere' end,
        function(h) h.properties['playlist-pos']=1 end,
        function(h) h.properties.path='X:/fixture/other-current.mkv' end,
    }
    for index, mutate in ipairs(mutations) do
        local h=host();h.start();mutate(h);h.finish(h.result({entry('one.mkv')}))
        assert(#h.calls==0,'stale snapshot mutation '..index..' committed')
        eq(#h.writes,0);message(h,'播放列表已变化，请重新选择文件',1.5)
    end
end
function retired_callbacks()
    local h=host();h.start();local first=h.result({entry('old.mkv')});local oldpath=h.jobs[1].args.args[3]
    h.start('append','clipboard');eq(#h.aborted,1);eq(h.aborted[1],h.jobs[1].id);eq(h.files[oldpath],nil)
    assert(h.payloads[1].request_id~=h.payloads[2].request_id)
    h.finish(first,1);eq(#h.calls,0);eq(#h.messages,0)
    local current=h.result({entry('new.mkv')});h.finish(current,2);eq(#h.calls,1);load(h,1,'new.mkv','append',true)
    h.finish(first,1);h.finish(current,2);eq(#h.calls,1);eq(#h.messages,0)
    h.start();local late=h.result({entry('late.mkv')});local path=h.jobs[3].args.args[3]
    h.controller.shutdown();eq(#h.aborted,2);eq(h.aborted[2],h.jobs[3].id);eq(h.files[path],nil)
    h.finish(late,3);eq(#h.calls,1);eq(#h.messages,0)
    h.start();eq(#h.jobs,3)
end
function synchronous_snapshot_change()
    local h=host();h.start();h.on_parse=function() h.properties['playlist-pos']=1 end
    h.finish(h.result({entry('one.mkv')}));eq(#h.calls,0);eq(#h.writes,0)
    message(h,'播放列表已变化，请重新选择文件',1.5)
end
function synchronous_reentry()
    for _, action in ipairs({'request','shutdown'}) do
        local h=host();h.start('append')
        h.on_command=function()
            h.on_command=nil
            if action=='request' then h.start('append','clipboard') else h.controller.shutdown() end
        end
        h.finish(h.result({entry('old-one.mkv'),entry('old-two.mkv')}),1)
        eq(#h.calls,1);eq(#h.writes,0);eq(#h.messages,0)
        if action=='request' then
            eq(#h.jobs,2);h.finish(h.result({entry('new.mkv')}),2)
            eq(#h.calls,2);load(h,2,'new.mkv','append',true)
        end
    end
end
function command_failures()
    local h=host();h.failed_path='X:/fixture/one.mkv';h.start()
    h.finish(h.result({entry('one.mkv')},{single_media=true}));eq(#h.writes,0)
    message(h,'部分文件未能加入播放列表',4)
    h=host();h.failed_path='X:/fixture/one.mkv';h.start()
    h.finish(h.result({entry('one.mkv'),entry('two.mp4')}))
    eq(#h.calls,2);load(h,1,'one.mkv','replace',true);load(h,2,'two.mp4','replace',true)
    eq(#h.writes,1);eq(h.properties.pause,false);message(h,'部分文件未能加入播放列表',4)
    h=host();h.failed_path='X:/fixture/one.srt';h.start('append')
    h.finish(h.result({entry('one.srt','subtitle'),entry('two.mp4')}))
    eq(#h.calls,2);load(h,2,'two.mp4','append',true);eq(#h.writes,0)
    message(h,'部分文件未能加入播放列表',4)
end
