local properties, observers, events, bindings, files = {}, {}, {}, {}, {}
local commands, aborts, seeks, timers, updates = {}, {}, {}, {}, {}
local opened, request, missing_module, start_failure, seek_failure
local configured_ffmpeg = ''
local function eq(actual, expected)
    assert(actual == expected, 'expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
end

local function complete(index, result, success)
    commands[index].done(success ~= false, result)
end
local function succeed(index, stdout)
    complete(index, {status=0, stdout=stdout})
end
local mp = {
    get_property_native=function(name, default)
        if properties[name] ~= nil then return properties[name] end
        return default
    end,
    add_key_binding=function(key, name, fn) eq(key, nil); bindings[name]=fn end,
    observe_property=function(name, kind, fn) eq(kind, 'native'); observers[name]=fn end,
    unobserve_property=function(fn)
        for name, observer in pairs(observers) do if observer == fn then observers[name]=nil end end
    end,
    register_event=function(name, fn) events[name]=fn end,
    command_native=function(args)
        if args[1] == 'expand-path' then return 'expanded/' .. args[2] end
        eq(args[1], 'seek'); eq(args[3], 'absolute')
        seeks[#seeks+1] = args[2]
        if seek_failure then return nil, 'synthetic seek failure' end
        return true
    end,
    command_native_async=function(spec, done)
        eq(spec.name, 'subprocess'); assert(spec.playback_only and spec.capture_stdout and spec.capture_stderr)
        eq(spec.capture_size, 8*1024*1024+1)
        if start_failure then return nil end
        commands[#commands+1] = {spec=spec, done=done}
        return #commands
    end,
    abort_async_command=function(index)
        assert(commands[index])
        aborts[#aborts+1] = index
        -- Exercise a reentrant abort reply as well as later manually queued replies.
        complete(index, {status=-1, error_string='killed', killed_by_us=true})
    end,
    add_timeout=function(seconds, fn)
        eq(seconds, 30)
        local timer = {fire=fn, kill=function(self) self.killed=true end}
        timers[#timers+1] = timer
        return timer
    end,
    osd_message=function() error('unexpected OSD message') end,
}
package.loaded.mp = mp
package.loaded['mp.utils'] = {file_info=function(path) return files[path] end}

local renderer = {
    open=function(options) assert(not opened); request=options; opened=true; return true end,
    close=function() if opened then opened=false; request.close() end end,
    is_open=function() return opened end,
    update=function(rows, current, notice, state)
        assert(opened)
        updates[#updates+1] = {rows=rows, current=current, notice=notice, state=state}
        request.tracks, request.current_id, request.notice = rows, current, notice
        if state then request.state=state end
    end,
}

-- The module uses global dofile; the controller below sees this same seam.
function dofile(path)
    eq(path, 'expanded/~~/script-modules/mpvnet-paths.lua')
    return {options={ffmpeg_path=configured_ffmpeg}}
end
local open_paths = dofile

-- DATA MODULE IS INSERTED HERE
local function dofile(path)
    if path == 'expanded/~~/script-modules/track-selector.lua' then return renderer end
    if path == 'expanded/~~/script-modules/subtitle-lines.lua' then
        if missing_module then error('synthetic missing file') end
        return Data
    end
    return open_paths(path)
end

-- CONTROLLER IS INSERTED HERE

local media_path = [[D:\合成 [一] & 影片's.mkv]]
local external_path = [[D:\合成 [一] & 台词's.ass]]
local other = {type='sub', id=4, codec='subrip', ['ff-index']=2}
local main = {type='sub', id=11, codec='ass', ['ff-index']=5}
local external = {type='sub', id=8, codec='ass', external=true, ['external-filename']=external_path}
local function set_track(track, property)
    properties['current-tracks/sub'] = track
    properties.sid = track and track.id or 'no'
    if property then observers[property]() end
end
local function fixture(track)
    properties.path = media_path
    properties['track-list'] = {{type='audio', id=1}, external, other, {type='video', id=1}, main}
    properties['time-pos'], properties['sub-delay'], properties.duration = 6.4, 0.1, 80
    properties['sub-visibility'], properties['secondary-sid'] = false, external.id
    set_track(track or main)
end
local function open_lines()
    bindings['select-subtitle-line']()
    assert(opened)
    eq(request.kind, 'lines')
end
local function contains(value, substring)
    assert(type(value) == 'string' and value:find(substring,1,true), tostring(value))
end
local function check_extraction(index, executable, path, stream)
    local args=commands[index].spec.args
    eq(args[1], executable);eq(args[5], '-nostdin');eq(args[6], '-i');eq(args[7], path)
    eq(args[8], '-map');eq(args[9], stream);eq(args[10], '-f');eq(args[11], 'lrc')
    eq(args[#args], '-')
end

function extraction_source_uses_real_stream_index_and_fallback_order()
    fixture()
    eq(Data.source().map, '0:5')
    main['ff-index'] = nil
    eq(Data.source().map, '0:s:1') -- an earlier external track and ID gaps do not count
    properties['track-list'] = {main, other, external}
    eq(Data.source().map, '0:s:0')
    properties['track-list'] = {other, external}
    eq(Data.source().problem, 'source')
    set_track(external)
    eq(Data.source().map, '0:s:0')
    external['ff-index'] = 3
    eq(Data.source().map, '0:3')
    eq(Data.source().input, external_path)
    external['external-filename'] = 'edl://!new_stream;https://host.invalid/字幕.ass?part=2'
    eq(Data.source().input, 'https://host.invalid/字幕.ass?part=2')
    external['external-filename'] = 'edl://!new_stream;D:/合成.ass'
    eq(Data.source().input, external['external-filename'])
    external['external-filename'] = external_path
    configured_ffmpeg = [[C:\工具 [合成]\FFmpeg\ffmpeg.exe]]
    open_lines()
    eq(#commands,1)
    check_extraction(1, configured_ffmpeg, external_path, '0:3')
end

function parse_keeps_text_and_time_paired_and_strips_markup()
    local data = '\239\187\191[00:07.99]  <b>七</b>  \r\n' ..
        '[00:04.91]{\\i1}甲\\h乙\\N丙{=styled}\r\n' ..
        '[00:04.10]丁\n[00:04.44]甲 乙 丙\n' ..
        '[00:07.01]还在七秒\n[00:04.90]戊\n[01:02]最晚\n' ..
        '[00:03.99]{\\p1}m 0 0 l 1 1{\\p0}保留\n' ..
        '[00:03.90]m 0 0 l 1 1\n[00:02.50]  {\\i1}<i></i> \n' ..
        '[00:88.10]bad seconds\n[xx:01.20]bad minutes\n[00:01..0]bad fraction\n' ..
        'garbage 12:14\n[00:00.01]开始\n[ar:metadata]\n'
    local lines = assert(Data.parse(data))
    local expected = {{0,'开始'}, {3,'保留'}, {4,'甲 乙 丙'}, {4,'丁'}, {4,'戊'},
        {7,'七'}, {7,'还在七秒'}, {62,'最晚'}}
    eq(#lines, #expected)
    for index, item in ipairs(expected) do
        eq(lines[index].time, item[1]); eq(lines[index].title, item[2])
    end
    eq(#assert(Data.parse('')),0)
    eq(#assert(Data.parse('broken\n[bad:bad]\n[00:00.99]')),0)
    local invalid, problem = Data.parse({})
    eq(invalid,nil); eq(problem,'failed')
end

function bounds_reject_partial_results()
    local exact = {}
    for index=1,10000 do exact[index] = '[00:10.00]行 ' .. index end
    local data = table.concat(exact,'\n')
    eq(#assert(Data.parse(data)),10000)
    local rows, problem = Data.parse(data .. '\n[00:10.00]另一行')
    eq(rows,nil);eq(problem,'too_large')
    rows, problem = Data.parse(('x'):rep(8*1024*1024+1))
    eq(rows,nil);eq(problem,'too_large')
    fixture()
    open_lines()
    complete(1,{status=1,stdout=('[00:10.00]不允许提交\n') .. ('x'):rep(8*1024*1024)})
    contains(request.state.empty_title,'超过读取限制')
    eq(#request.tracks,0)
    eq(request.submit(1),false)
    eq(#seeks,0)
end

function unavailable_sources_and_failures_can_recover()
    fixture()
    set_track(nil)
    missing_module = true
    open_lines()
    assert(request.state.can_retry);contains(request.state.empty_title,'无法读取')
    missing_module = false
    request.retry()
    contains(request.state.empty_title,'没有主字幕');eq(#commands,0)
    local bitmap = {id=3,type='sub',codec='hdmv_pgs_subtitle',['ff-index']=8}
    set_track(bitmap,'current-tracks/sub')
    contains(request.state.empty_title,'图形字幕');eq(#commands,0)
    set_track(main,'sid')
    contains(request.state.empty_title,'正在读取')
    check_extraction(1, 'ffmpeg', media_path, '0:5')
    complete(1,{status=-1,error_string='init',stderr='private command line'})
    contains(request.state.empty_title,'FFmpeg');assert(request.state.can_retry)
    assert(timers[1].killed)
    start_failure = true
    request.retry()
    contains(request.state.empty_title,'未能提取');eq(#timers,1)
    start_failure = false
    request.retry()
    eq(#commands,2)
    request.retry()
    eq(#commands,2) -- a repeated click does not start a concurrent process
    complete(2,{status=1,stderr='https://private.invalid/secret'})
    contains(request.state.empty_title,'未能提取');assert(request.state.can_retry)
    assert(not request.state.empty_hint:find('private',1,true))
    request.retry();succeed(3,'[00:01.00]\nnot subtitles')
    contains(request.state.empty_title,'没有可选择');eq(#request.tracks,0)
end

function submit_uses_latest_delay_and_marker_does_not_reload()
    fixture()
    properties['current-tracks/video/image'] = false
    open_lines()
    eq(#commands,1);eq(#request.tracks,0)
    succeed(1,'[00:00.05]开始\n[00:06.30]第一行\n[00:06.80]第二行\n[00:09.04]结束')
    local rows = request.tracks
    eq(#rows,4);eq(rows[2].title,'第一行');eq(rows[3].title,'第二行')
    eq(rows[2].time_text,'00:06');eq(rows[3].time_text,'00:06')
    eq(request.current_id,rows[3].id);eq(request.state.reveal_id,rows[3].id)
    local count = #updates
    properties['time-pos']=6.5;observers['time-pos']()
    eq(#updates,count)
    properties['time-pos']=9.6;observers['time-pos']()
    eq(request.current_id,rows[4].id);eq(updates[#updates].state,nil)
    eq(updates[#updates].rows,rows)
    properties['sub-delay']=1.3;observers['sub-delay']()
    eq(request.current_id,rows[3].id);eq(#commands,1)
    assert(request.submit(rows[2].id));eq(seeks[1],7.3)
    assert(request.submit(rows[3].id));eq(seeks[2],7.3)
    properties['current-tracks/video/image']=nil
    properties['sub-delay']=0.25
    assert(request.submit(rows[4].id));eq(seeks[3],9.35)
    properties['current-tracks/video/image']=true
    properties['sub-delay']=-4
    assert(request.submit(rows[1].id));eq(seeks[4],0)
    eq(properties.sid,main.id);eq(properties['secondary-sid'],external.id);eq(properties['sub-visibility'],false)
    seek_failure=true
    local ok, err=request.submit(rows[4].id)
    eq(ok,false);contains(err,'未能跳转');assert(opened)
end

function changes_reject_previous_row_ids_and_reread()
    fixture()
    open_lines()
    set_track(external,'sid')
    eq(aborts[1],1);assert(timers[1].killed);eq(#commands,2)
    succeed(1,'[00:03.00]旧结果')
    eq(#request.tracks,0)
    files[external_path] = {mtime=15,ctime=10,size=80}
    succeed(2,'[00:03.00]读取期间修改')
    eq(#commands,3);eq(#request.tracks,0)
    succeed(3,'[00:04.00]新结果')
    local previous_id = request.tracks[1].id
    files[external_path].mtime = 16 -- same track and path, no mpv event
    local ok, err = request.submit(previous_id)
    eq(ok,false);contains(err,'来源已变化')
    eq(#seeks,0);eq(#commands,4);eq(#request.tracks,0)
    succeed(4,'[00:05.00]编辑后')
    assert(request.tracks[1].id > previous_id)
    eq(request.submit(previous_id),false);eq(#seeks,0)
    assert(request.submit(request.tracks[1].id));eq(#seeks,1)
    local second_id=request.tracks[1].id
    set_track(main) -- queued user click can arrive before mpv observer
    eq(request.submit(second_id),false);eq(#seeks,1);eq(#commands,5)
    observers['track-list']()
    eq(#commands,5)
end

function cancel_timeout_and_media_retirement_abort_their_own_jobs()
    fixture()
    open_lines()
    local old, old_marker = request, observers['time-pos']
    timers[1].fire()
    eq(aborts[1],1);assert(timers[1].killed)
    contains(request.state.empty_title,'超时');assert(request.state.can_retry)
    succeed(1,'[00:06.00]过期');eq(#request.tracks,0)
    old.retry();eq(#commands,2)
    renderer.close()
    eq(aborts[2],2);assert(timers[2].killed);assert(not opened)
    eq(observers['time-pos'],nil);eq(observers['sub-delay'],nil)
    succeed(2,'[00:06.00]关闭后');eq(#seeks,0)
    open_lines()
    old.close();old.retry();old_marker()
    eq(old.submit(1),false);eq(#commands,3)
    events['start-file']()
    eq(aborts[3],3);assert(timers[3].killed);assert(not opened)
    open_lines()
    succeed(3,'[00:06.00]切片后');eq(#request.tracks,0)
    succeed(4,'[00:06.00]当前')
    eq(#request.tracks,1);assert(timers[4].killed)
    events['shutdown']()
    assert(not opened);eq(#aborts,3);eq(#seeks,0)
end
