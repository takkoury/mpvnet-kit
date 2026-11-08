-- Full production modules are loaded before this file. Only host boundaries are doubled.
local function eq(actual, expected)
    assert(actual == expected, 'expected '..tostring(expected)..', got '..tostring(actual))
end
local function host()
    local h = {properties={pid=123, ['working-directory']='X:/fixture',
        path='X:/fixture/current.mkv', ['playlist-pos']=0, pause=true,
        playlist={{id=0,filename='X:/fixture/current.mkv'}, {id=92,filename='X:/fixture/later.mp4'}},
        ['options/video-exts']={'mkv','mp4'}, ['options/audio-exts']='flac,mp3',
        ['options/sub-auto-exts']={'srt','ass'}, ['options/image-exts']={'png','jpg'}},
        calls={}, writes={}, messages={}, jobs={}, aborted={}, removed={}, files={}, payloads={},
        observers={}, hooks={}, timers={}, detached={}, loaded_lists={}, replies={}, clock=1}
    local mp = {
        get_time=function() return h.clock end,
        add_periodic_timer=function(interval, callback)
            eq(interval,0.1)
            local timer={callback=callback,active=true,kill=function(self) self.active=false end}
            h.timers[#h.timers+1]=timer;return timer
        end,
        observe_property=function(name, kind, callback)
            eq(kind,'native');h.observers[name]=callback
            callback(name,h.properties[name])
        end,
        add_hook=function(name, priority, callback)
            eq(name,'on_load');eq(priority,50);h.hooks[name]=callback
        end,
        set_property=function(name,value)
            h.writes[#h.writes+1]={name,value};h.properties[name]=value
            return true
        end,
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
            if args.name=='subprocess' then
                eq(args.detach,true);eq(args.capture_stdout,false);eq(args.capture_stderr,false)
                eq(args.playback_only,false);eq(args.args[4],'-DetachedSave')
                local job={args=args,detached=true}
                h.jobs[#h.jobs+1]=job;h.detached[#h.detached+1]=job
                if h.fail=='detach' then return nil,'launch failed' end
                return {status=0}
            end
            h.calls[#h.calls+1]=args
            if args[1]=='loadlist' then
                assert(h.files[args[2]],'loadlist source must exist while the core parses it')
                h.loaded_lists[#h.calls]={path=args[2],content=h.files[args[2]]}
            end
            if h.on_command then h.on_command(args) end
            if h.failed_path and args[2]==h.failed_path then return nil,'command failed' end
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
        file_info=function(path)
            if path=='~~/helpers/KitPlaylistInput.exe' then
                if h.fail=='helper' then return nil end;return {is_file=true}
            end
            if h.files[path]~=nil then return {is_file=true} end
        end,
        join_path=function(a,b) return a..'/'..b end,
        format_json=function(payload)
            h.payloads[#h.payloads+1]=payload
            if h.fail=='format' then return nil end
            if h.fail=='payload-size' then return string.rep('x',2*1024*1024+1) end
            return 'request-json'
        end,
        parse_json=function(raw)
            if h.on_parse then h.on_parse() end
            if raw:find('writer-json-',1,true)==1 then return h.replies[raw] end
            return h.response
        end,
    }
    os.getenv=function(name)
        if (name=='TEMP' or name=='TMP') and h.fail~='temp' then return 'X:/fixture/temp' end
    end
    os.remove=function(path) h.removed[#h.removed+1]=path;h.files[path]=nil;return true end
    io.open=function(path, mode)
        if mode=='rb' then
            local content=h.files[path]
            if content==nil then return nil end
            return {read=function(_,limit) return content:sub(1,limit) end,close=function() return true end}
        end
        eq(mode,'wb')
        if h.fail=='open' or (h.fail_open_path and h.fail_open_path(path)) then return nil end
        h.files[path]=''
        return {
            write=function(_, data)
                if h.fail=='write' or (h.fail_write_path and h.fail_write_path(path)) then return nil end
                h.files[path]=data;return true
            end,
            close=function()
                if h.fail=='close' or (h.fail_close_path and h.fail_close_path(path)) then return nil end
                return true
            end,
        }
    end
    h.controller=input_module.new(mp,utils,feedback_module.new(mp),function() return h.include_images == true end)
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
    function h.tick(seconds)
        h.clock=h.clock+seconds
        for _,timer in ipairs(h.timers) do if timer.active then timer.callback() end end
    end
    function h.writer_reply(data,index)
        local job=h.jobs[index or #h.jobs];assert(job.detached,'writer must use detached launch')
        local raw='writer-json-'..tostring(index or #h.jobs)
        h.replies[raw]=data;h.files[job.args.args[3]..'.result']=raw
        h.tick(0)
    end
    function h.queue(entries, delayed_notification)
        h.properties.playlist=entries
        if h.observers.playlist then h.observers.playlist('playlist',delayed_notification or entries) end
    end
    function h.loading(position)
        h.properties['playlist-pos']=position;h.hooks.on_load()
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
    eq(table.concat(p.image_exts,','),'png,jpg')
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
function folder_input_and_feedback()
    local h=host();h.start('open','folder')
    eq(h.payloads[1].operation,'folder')
    h.finish(h.result({entry('one.mkv')},{single_media=false}))
    load(h,1,'one.mkv','replace',true);eq(h.properties.pause,false)
    h=host();h.start('append','folder')
    h.finish(h.result({entry('two.mp4')},{single_media=false}))
    load(h,1,'two.mp4','append',true);eq(#h.writes,0)
    h=host();h.start('open','folder');h.finish(h.result({}))
    eq(#h.calls,0);message(h,'文件夹中没有可添加的媒体',1.5)
    h=host();h.start('open','folder');h.finish(h.result({}, {unreadable_directories=1}))
    eq(#h.calls,0);message(h,'无法读取 1 个文件夹，当前队列保持不变',4)
    h=host();h.start('append','paths')
    h.finish(h.result({entry('one.mkv')},{unreadable_directories=2}))
    eq(#h.calls,1);eq(#h.writes,0);message(h,'已添加可用文件，2 个文件夹无法读取',4)
    h=host();h.start('open','folder');h.finish(h.result({}, {skipped_links=1}))
    eq(#h.calls,0);eq(#h.writes,0);message(h,'已跳过 1 个目录链接，当前队列保持不变',1.5)
    h=host();h.start('append','folder')
    h.finish(h.result({entry('one.mkv')},{skipped_links=2}))
    eq(#h.calls,1);eq(#h.writes,0);message(h,'已跳过 2 个目录链接',1.5)
    h=host();h.start('open','folder')
    h.finish(h.result({entry('one.mkv')}, {status='cancelled'}))
    eq(#h.calls,0);eq(#h.writes,0);eq(#h.messages,0)
    h=host();h.start('open','folder')
    h.finish(h.result({}, {status='error',error_code='input_too_large'}))
    eq(#h.calls,0);message(h,'文件数量或路径内容过多，未修改播放列表',4)
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
local function loaded_list(h,index,content,mode)
    local args=h.calls[index];eq(args[1],'loadlist');eq(args[3],mode);eq(#args,3)
    assert(not args[2]:find('memory://',1,true));assert(#args[2]<260,'short source provenance expected')
    eq(h.loaded_lists[index].content,content);eq(h.files[args[2]],nil)
end
local function listed(path,title,kind)
    local value=entry(path,kind);value.from_playlist=true;value.title=title or '';return value
end
function playlist_segments()
    local h=host();h.start()
    h.finish(h.result({entry('before.srt','subtitle'),listed('repeat.mkv','第一集'),
        listed('repeat.mkv','重复\n标题'),entry('middle.mp4'),listed('stream.m3u8','直播','native')},
        {had_playlist=true}))
    eq(#h.calls,4);eq(h.calls[1][1],'sub-add')
    loaded_list(h,2,'#EXTM3U\n#EXTINF:-1,第一集\nX:/fixture/repeat.mkv\n'
        ..'#EXTINF:-1,重复 标题\nX:/fixture/repeat.mkv\n','replace')
    load(h,3,'middle.mp4','append',true)
    loaded_list(h,4,'#EXTM3U\n#EXTINF:-1,直播\nX:/fixture/stream.m3u8\n','append')
    assert(h.calls[2][2]~=h.calls[4][2],'each prepared segment needs its own source')
    eq(#h.writes,1);eq(h.properties.pause,false);eq(#h.messages,0);eq(next(h.files),nil)
    h=host();h.start('append');h.finish(h.result({listed('repeat.mkv'),listed('repeat.mkv')},{had_playlist=true}))
    eq(#h.calls,1);eq(#h.writes,0);eq(h.properties.pause,true)
    loaded_list(h,1,'#EXTM3U\nX:/fixture/repeat.mkv\nX:/fixture/repeat.mkv\n','append')
end
function playlist_loading_policy()
    local h=host();local original=h.properties.playlist
    h.on_command=function(args)
        if args[1]=='loadlist' then
            h.queue({original[1],original[2],{id=101,filename='X:/fixture/current.mkv',['playlist-path']=args[2]},
                {id=102,filename='X:/fixture/second.mkv',['playlist-path']=args[2]},
                {id=104,filename='X:/fixture/current.mkv',['playlist-path']='X:/other/source.m3u8'}})
        end
    end
    h.start('append');h.finish(h.result({listed('current.mkv'),listed('second.mkv')},{had_playlist=true}))
    eq(#h.writes,0)
    h.loading(0);eq(#h.writes,0) -- Same filename, pre-existing ID: no imported policy.
    h.loading(4);eq(#h.writes,0) -- A newly added ID from another source is not ours.
    h.loading(2);eq(#h.writes,1);eq(h.writes[1][1],'file-local-options/autocreate-playlist');eq(h.writes[1][2],'no')
    h.writes={}
    local imported=h.properties.playlist
    h.queue(imported, original) -- Delayed callback data must not erase policies for live IDs.
    h.loading(3);eq(#h.writes,1);h.writes={}
    h.queue({original[1],original[2],imported[4],{id=103,filename='X:/fixture/current.mkv'}})
    h.loading(3);eq(#h.writes,0) -- External addition of the same filename.
    h.queue({original[1],original[2],imported[4],{id=101,filename='X:/fixture/current.mkv'}})
    h.loading(3);eq(#h.writes,0) -- A removed ID cannot regain the retired policy.
    h.queue({original[1],original[2],{id=102,filename='X:/fixture/replaced.mkv'}})
    h.loading(2);eq(#h.writes,0)
    h.queue({original[1],original[2],{id=102,filename='X:/fixture/second.mkv'}})
    h.loading(2);eq(#h.writes,0) -- Same ID changed filename and changed back.
    h.loading(-1);eq(#h.writes,0)
end
function playlist_segment_failure()
    local h=host();h.start()
    h.on_command=function(args) if args[1]=='loadlist' then h.failed_path=args[2] end end
    h.finish(h.result({listed('one.mkv'),entry('next.mp4')},{had_playlist=true}))
    eq(#h.calls,2);load(h,2,'next.mp4','replace',true)
    eq(#h.writes,1);eq(h.properties.pause,false);message(h,'部分文件未能加入播放列表',4)
    h.writes={};h.loading(0);eq(#h.writes,0)
end
function playlist_feedback()
    local h=host();h.start();h.finish(h.result({}, {had_playlist=true}))
    eq(#h.calls,0);message(h,'播放列表文件中没有可用条目',1.5)
    h=host();h.start();h.finish(h.result({}, {had_playlist=true,missing_files=2}))
    eq(#h.calls,0);eq(#h.writes,0);message(h,'已跳过 2 个缺失文件，当前队列保持不变',4)
    h=host();h.start('append');h.finish(h.result({listed('one.mkv')},{had_playlist=true,missing_files=2,skipped=1}))
    eq(#h.calls,1);eq(#h.writes,0);message(h,'已跳过 2 个缺失文件\n已跳过无法加入的文件',1.5)
    h=host();h.start();h.finish(h.result({}, {status='error',error_code='playlist_read_failed'}),nil,true,{status=1,stdout='response-json'})
    eq(#h.calls,0);message(h,'未能读取播放列表，请检查文件内容或编码',4)
end
function playlist_invalid_metadata()
    for _, invalid in ipairs({'source','title','subtitle'}) do
        local h=host();h.start();local value=listed('one.mkv')
        if invalid=='source' then value.from_playlist='true'
        elseif invalid=='title' then value.title={}
        else value.kind='subtitle' end
        h.finish(h.result({entry('valid.mp4'),value},{had_playlist=true}))
        eq(#h.calls,0);eq(#h.writes,0);message(h,'未能读取文件操作结果',4)
    end
end
local function target(h,extra,index)
    local data={target_path='X:/fixture/saved.m3u8',target_exists=false,target_sha256=''}
    for key,value in pairs(extra or {}) do data[key]=value end
    return h.result({},data,index)
end
local function begin_write(h,extra)
    h.controller.save();local dialog=#h.jobs
    h.finish(target(h,extra,dialog),dialog)
    eq(h.payloads[#h.payloads].operation,'save')
    return #h.jobs
end
function save_latest_queue()
    local h=host();h.controller.save()
    eq(#h.jobs,1);eq(h.payloads[1].mode,'save');eq(h.payloads[1].operation,'save-dialog')
    eq(h.payloads[1].suggested_path,'');eq(#h.payloads[1].existing_paths,0)
    h.queue({{id=93,filename='X:/fixture/最新.mkv',title='最新 标题'},
        {id=94,filename='X:/fixture/最新.mkv',title='重复标题'},
        {id=95,filename='https://example.invalid/live?a=1&b=2'}})
    h.properties['working-directory']='X:/new cwd';h.properties['playlist-pos']=2
    local hash=string.rep('a',64);h.finish(target(h,{target_exists=true,target_sha256=hash}),1)
    eq(#h.jobs,2);local p=h.payloads[2]
    eq(p.operation,'save');eq(p.mode,'save');eq(p.request_id,h.payloads[1].request_id..'-write')
    eq(p.target_path,'X:/fixture/saved.m3u8');eq(p.target_exists,true);eq(p.target_sha256,hash)
    eq(p.working_directory,'X:/new cwd');eq(#p.existing_paths,0);eq(#p.save_entries,3)
    eq(p.save_entries[1].path,'X:/fixture/最新.mkv');eq(p.save_entries[1].title,'最新 标题')
    eq(p.save_entries[2].path,p.save_entries[1].path);eq(p.save_entries[2].title,'重复标题')
    eq(p.save_entries[3].path,'https://example.invalid/live?a=1&b=2');eq(p.save_entries[3].title,'')
    eq(#h.calls,0);eq(#h.writes,0);eq(#h.messages,0)
    h.properties.playlist[1].title='外部后改';eq(p.save_entries[1].title,'最新 标题')
    h.writer_reply(h.result({}, {saved=true,target_path=p.target_path}),2)
    eq(#h.calls,0);eq(#h.writes,0);message(h,'已保存播放列表',2)
    h.messages={};h.controller.save();eq(#h.jobs,3);eq(h.payloads[3].operation,'save-dialog')
    eq(h.payloads[3].suggested_path,p.target_path);assert(h.payloads[3].request_id~=h.payloads[1].request_id)
    h.finish(h.result({}, {status='cancelled'}),3);eq(#h.jobs,3);eq(#h.messages,0)
end
function save_rejections()
    local h=host();h.queue({});h.controller.save();eq(#h.jobs,0)
    message(h,'播放列表为空，无法保存',1.5)
    h=host();h.controller.save();h.finish(h.result({}, {status='cancelled'}));eq(#h.jobs,1);eq(#h.messages,0)
    h=host();h.controller.save();h.queue({});h.finish(target(h));eq(#h.jobs,1)
    message(h,'播放列表为空，未保存',1.5)
    h=host();h.controller.save();h.queue({{id=9,filename=''}});h.finish(target(h));eq(#h.jobs,1)
    message(h,'无法读取完整播放列表，未保存',4)
    local invalid={{target_path=''}, {target_path='X:/fixture/bad\n.m3u8'}, {target_exists='false'},
        {target_exists=true,target_sha256=''}, {target_exists=false,target_sha256=string.rep('a',64)},
        {target_exists=true,target_sha256=string.rep('z',64)}}
    for _, fields in ipairs(invalid) do
        h=host();h.controller.save();h.finish(target(h,fields))
        eq(#h.jobs,1);eq(#h.calls,0);eq(#h.writes,0)
        message(h,'未能确认保存位置，未写入文件',4)
    end
end
function save_dialog_retired()
    local h=host();h.controller.save();local old=target(h);local path=h.jobs[1].args.args[3]
    h.start('append','files');eq(#h.aborted,1);eq(h.aborted[1],h.jobs[1].id);eq(h.files[path],nil)
    h.finish(old,1);eq(#h.jobs,2);eq(#h.calls,0);eq(#h.messages,0)
    h.finish(h.result({entry('new.mkv')}),2);eq(#h.calls,1);load(h,1,'new.mkv','append',true)
    h=host();h.controller.save();old=target(h);h.controller.save()
    eq(#h.jobs,2);eq(#h.aborted,1);eq(h.payloads[2].operation,'save-dialog')
    h.finish(old,1);eq(#h.jobs,2);eq(#h.messages,0)
    h=host();h.start('append');old=h.result({entry('old.mkv')})
    h.controller.save();eq(#h.aborted,1);eq(h.aborted[1],h.jobs[1].id)
    h.finish(old,1);eq(#h.calls,0);eq(#h.jobs,2);eq(h.payloads[2].operation,'save-dialog')
end
function save_independent_write()
    local h=host();local writer=begin_write(h);local path=h.jobs[writer].args.args[3]
    h.controller.save();eq(#h.jobs,2);message(h,'正在保存播放列表，请稍候',1.5)
    h.messages={};h.start('append','files');eq(#h.jobs,3);eq(#h.aborted,0)
    eq(h.files[path],'request-json')
    h.finish(h.result({entry('new.mkv')}),3);eq(#h.calls,1);load(h,1,'new.mkv','append',true)
    h.writer_reply(h.result({entry('untrusted-old.mkv')},{saved=true,target_path='X:/fixture/saved.m3u8'},writer),writer)
    eq(#h.calls,1);eq(#h.writes,0);message(h,'已保存播放列表',2);eq(h.files[path],nil)
    eq(h.files[path..'.result'],nil);eq(h.timers[1].active,false)
    h.writer_reply(h.result({}, {saved=true,target_path='X:/fixture/saved.m3u8'},writer),writer)
    eq(#h.messages,1);eq(#h.calls,1)
    h.controller.save();eq(#h.jobs,4);eq(h.payloads[4].operation,'save-dialog')
end
function save_result_validation()
    for _, case in ipairs({'unsaved','wrong-target','changed','failed'}) do
        local h=host();local writer=begin_write(h)
        local data=h.result({}, {saved=true,target_path='X:/fixture/saved.m3u8'},writer)
        if case=='unsaved' then data.saved=false
        elseif case=='wrong-target' then data.target_path='X:/private/secret.m3u8'
        elseif case=='changed' or case=='failed' then
            data.status='error';data.error_code=case=='changed' and 'target_changed' or 'save_failed'
        end
        h.writer_reply(data,writer);eq(#h.calls,0);eq(#h.writes,0);eq(#h.messages,1)
        assert(not h.messages[1][1]:find('secret',1,true));assert(h.messages[1][1]~='已保存播放列表')
        if case=='changed' then message(h,'目标文件已变化，未覆盖；请重新保存',4) end
        if case=='failed' then message(h,'保存播放列表失败，请检查目标文件',4) end
        h.messages={};h.controller.save();eq(#h.jobs,3) -- Errors release the saving slot.
    end
end
function save_shutdown()
    local h=host();local writer=begin_write(h);local writepath=h.jobs[writer].args.args[3]
    h.start('append','files');local input=#h.jobs;local inputpath=h.jobs[input].args.args[3]
    h.files['X:/fixture/foreign-request.json']='preserve'
    h.controller.shutdown()
    eq(#h.aborted,1);eq(h.aborted[1],h.jobs[input].id)
    eq(h.files[writepath],'request-json');eq(h.files[writepath..'.cancel'],'cancel')
    eq(h.files[inputpath],nil);eq(h.files['X:/fixture/foreign-request.json'],'preserve')
    eq(h.timers[1].active,false)
    h.writer_reply(h.result({}, {saved=true,target_path='X:/fixture/saved.m3u8'},writer),writer)
    h.finish(h.result({entry('late.mkv')},nil,input),input)
    eq(#h.calls,0);eq(#h.writes,0);eq(#h.messages,0)
    h.controller.save();h.start();eq(#h.jobs,3)
end

function save_write_preparation_failure_releases_slot()
    local h=host();h.controller.save();h.fail='write';h.finish(target(h),1)
    eq(#h.jobs,1);eq(#h.calls,0);eq(#h.writes,0);eq(next(h.files),nil)
    message(h,'无法准备文件操作',4)
    h.fail=nil;h.messages={};h.controller.save()
    eq(#h.jobs,2);eq(h.payloads[#h.payloads].operation,'save-dialog');eq(#h.messages,0)
end

function playlist_prepare_failure_preserves_queue()
    for _, failure in ipairs({'open','write','close'}) do
        local h=host();h.start();local seen=0
        h['fail_'..failure..'_path']=function(path)
            if path:sub(-5)=='.m3u8' then seen=seen+1;return seen==2 end
        end
        local before=h.properties.playlist
        h.finish(h.result({entry('first.mp4'),listed('one.mkv'),entry('between.mp4'),listed('two.mkv')},
            {had_playlist=true}))
        eq(seen,2);eq(#h.calls,0);eq(#h.writes,0);eq(h.properties.playlist,before)
        eq(next(h.files),nil);message(h,'无法准备播放列表，当前队列保持不变',4)
    end
end
function playlist_reentry_cleans_prepared_sources()
    local h=host();h.start()
    h.on_command=function(args)
        h.on_command=nil
        h.queue({{id=101,filename='X:/fixture/one.mkv',['playlist-path']=args[2]}})
        h.start('append','files')
    end
    h.finish(h.result({listed('one.mkv'),entry('between.mp4'),listed('two.mkv')},{had_playlist=true}),1)
    eq(#h.calls,1);eq(#h.jobs,2);eq(#h.writes,0);eq(#h.messages,0)
    for path in pairs(h.files) do assert(path:sub(-5)~='.m3u8','prepared source leaked after reentry') end
    h.loading(0);eq(#h.writes,0) -- The retired import must not tag the new ID.
end
function save_detach_launch_failure()
    local h=host();h.controller.save();h.fail='detach';h.finish(target(h),1)
    eq(#h.detached,1);eq(#h.jobs,2);eq(#h.timers,0);eq(next(h.files),nil)
    eq(#h.aborted,0);eq(#h.calls,0);message(h,'未能启动保存，请重试',4)
    h.fail=nil;h.messages={};h.controller.save();eq(#h.jobs,3);eq(#h.messages,0)
end
function save_reply_ownership_and_timeout()
    for _, invalid in ipairs({'token','schema','json'}) do
        local h=host();local writer=begin_write(h);local path=h.jobs[writer].args.args[3]
        local data=h.result({}, {saved=true,target_path='X:/fixture/saved.m3u8'},writer)
        if invalid=='token' then data.request_id='foreign'
        elseif invalid=='schema' then data.schema=2
        else data=nil end
        h.writer_reply(data,writer)
        eq(h.files[path],'request-json');eq(h.files[path..'.cancel'],'cancel')
        eq(h.files[path..'.result'],'writer-json-'..writer)
        eq(h.timers[1].active,false);eq(#h.aborted,0);eq(#h.calls,0)
        message(h,'未能确认保存结果，请检查目标文件',4)
    end
    local h=host();local writer=begin_write(h);local path=h.jobs[writer].args.args[3]
    eq(h.timers[1].active,true);h.tick(29);eq(#h.messages,0)
    h.tick(1);eq(h.timers[1].active,false);eq(h.files[path],'request-json')
    eq(h.files[path..'.cancel'],'cancel');eq(#h.aborted,0)
    message(h,'保存尚未确认完成，请检查目标文件后重试',4)
    h.messages={};h.controller.save();eq(#h.jobs,3);eq(h.payloads[3].operation,'save-dialog')
    h.writer_reply(h.result({}, {saved=true,target_path='X:/fixture/saved.m3u8'},writer),writer)
    eq(#h.messages,0);eq(#h.calls,0) -- A timed-out writer cannot reenter the new dialog.
end
function save_shutdown_without_worker_avoids_orphan_cancel()
    local h=host();local writer=begin_write(h);local path=h.jobs[writer].args.args[3]
    h.files[path]=nil -- A completed worker already owns and removed its request.
    h.controller.shutdown();eq(h.files[path..'.cancel'],nil);eq(#h.aborted,0)
    eq(h.timers[1].active,false);eq(#h.messages,0)
end
function save_dialog_parse_reentry_cannot_start_old_writer()
    for _, action in ipairs({'request','shutdown'}) do
        local h=host();h.controller.save();local data=target(h)
        h.on_parse=function()
            h.on_parse=nil
            if action=='request' then h.start('append','files') else h.controller.shutdown() end
        end
        h.finish(data,1)
        eq(#h.detached,0);eq(#h.calls,0);eq(#h.writes,0);eq(#h.messages,0)
        if action=='request' then eq(#h.jobs,2) else eq(#h.jobs,1) end
    end
end

function playlist_transport_encoding_ownership()
    for _, outcome in ipairs({'success','failure','external-change'}) do
        local h=host();h.properties['options/metadata-codepage']='+gb18030';h.start('append')
        eq(h.payloads[1].metadata_codepage,'+gb18030') -- Decode the original with the user's policy.
        h.on_command=function(args)
            eq(args[1],'loadlist');eq(h.properties['options/metadata-codepage'],'utf-8')
            eq(h.files[args[2]],'#EXTM3U\n#EXTINF:-1,中文标题\nX:/fixture/中文路径.mkv\n')
            if outcome=='failure' then h.failed_path=args[2]
            elseif outcome=='external-change' then h.properties['options/metadata-codepage']='+windows-1252' end
        end
        h.finish(h.result({listed('中文路径.mkv','中文标题')},{had_playlist=true}))
        eq(#h.calls,1);eq(h.writes[1][1],'options/metadata-codepage');eq(h.writes[1][2],'utf-8')
        if outcome=='external-change' then
            eq(#h.writes,1);eq(h.properties['options/metadata-codepage'],'+windows-1252')
        else
            eq(#h.writes,2);eq(h.writes[2][1],'options/metadata-codepage');eq(h.writes[2][2],'+gb18030')
            eq(h.properties['options/metadata-codepage'],'+gb18030')
        end
        eq(next(h.files),nil)
        if outcome=='failure' then message(h,'部分文件未能加入播放列表',4) else eq(#h.messages,0) end
    end
    for _, encoding in ipairs({'auto','utf-8','UTF8','+utf-8','+UTF8','gb18030'}) do
        local h=host();h.properties['options/metadata-codepage']=encoding;h.start('append')
        h.on_command=function() eq(h.properties['options/metadata-codepage'],encoding) end
        h.finish(h.result({listed('中文路径.mkv','中文标题')},{had_playlist=true}))
        eq(#h.calls,1);eq(#h.writes,0);eq(h.properties['options/metadata-codepage'],encoding)
    end
end

function image_inputs_capture_setting_and_use_local_still_duration()
    local h=host();h.start('append');eq(h.payloads[1].include_images,false)
    h.finish(h.result({}, {skipped_images=1}));eq(#h.calls,0);eq(#h.writes,0)
    message(h,'图片管理未开启，已跳过 1 个图片文件',1.5)
    h=host();h.include_images=true;h.start('append');eq(h.payloads[1].include_images,true)
    h.include_images=false -- The started request keeps its own input choice.
    h.finish(h.result({entry('photo.png','image'),entry('next.mkv')}))
    load(h,1,'photo.png','append',true);eq(h.calls[1][5]['image-display-duration'],'inf')
    load(h,2,'next.mkv','append',true);eq(h.calls[2][5]['image-display-duration'],nil)
    eq(#h.writes,0);eq(h.properties.pause,true)
    h.start('append');eq(h.payloads[2].include_images,false)
end
function image_lists_keep_policy_by_real_id_and_retire_it_on_replacement()
    local h=host()
    local image=listed('photo.png');image.kind='image'
    h.on_command=function(args)
        if args[1]=='loadlist' then
            h.queue({{id=101,filename='X:/fixture/photo.png',['playlist-path']=args[2]},
                {id=102,filename='X:/fixture/video.mkv',['playlist-path']=args[2]}})
        end
    end
    h.start('append');eq(h.payloads[1].include_images,false)
    h.finish(h.result({image,listed('video.mkv')},{had_playlist=true}))
    h.loading(0);eq(h.properties['file-local-options/image-display-duration'],'inf');eq(#h.writes,2)
    h.writes={};h.loading(1);eq(#h.writes,1);eq(h.writes[1][1],'file-local-options/autocreate-playlist')
    h.queue({{id=101,filename='X:/fixture/replacement.mkv'}})
    h.writes={};h.loading(0);eq(#h.writes,0)
end

function clear_cancels_input_without_cancelling_confirmed_save()
    local h=host();h.start('append','folder')
    local old=h.result({entry('late.mkv')})
    h.controller.clear();eq(#h.aborted,1);eq(#h.calls,1);eq(h.calls[1][1],'stop')
    h.finish(old);eq(#h.calls,1);eq(#h.messages,0)
    h.controller.shutdown();h.controller.clear();eq(#h.calls,1)
    h=host();h.controller.save()
    h.finish(h.result({}, {target_path='X:/saved.m3u8',target_exists=false,target_sha256=''}))
    eq(#h.detached,1)
    local path=h.jobs[2].args.args[3]
    h.controller.clear();eq(h.files[path..'.cancel'],nil);eq(#h.aborted,0)
    eq(h.calls[#h.calls][1],'stop')
end
