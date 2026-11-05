-- Execute the actual controller with only the mpv host and renderer replaced.
local bindings, events, observers, writes, messages, calls = {}, {}, {}, {}, {}, {}
local audio = {type='audio', id=3, title='Commentary', lang='eng', codec='aac',
    ['demux-channel-count']=6, ['audio-channels']='5.1', ['demux-samplerate']=48000,
    ['demux-bitrate']=384000, external=true, ['external-filename']='file:///audio.flac',
    default=true, forced=false, ['unknown-metadata']={value='preserved'}}
local subtitle = {type='sub', id=1, title='Primary', lang='zho', codec='ass'}
local properties = {['track-list']={subtitle,
    {type='sub', id=2, title='Bilibili Danmaku'}, audio,
    {type='video', id=4}, {type='audio',id=5,title='Bilibili Danmaku'}},
    sid=1, aid=3, ['secondary-sid']=2, mute=false, volume=83,
    ['audio-device']='auto', ['sub-visibility']=true,
    ['chapter-list']={{time=0,title='Opening'},{time=83,title='Middle'},{time=142.9}},chapter=-1,duration=200}
local function get(name, default)
    if properties[name] ~= nil then return properties[name] end
    return default
end
local set_failure, load_failure, open_failure, readback_override, notify_device_write
local loads = 0
local history_commands, history_loads, history_json = {}, {}, {}
local mp = {
    get_property_native=get,
    get_property=get,
    set_property_native=function(name,value)
        assert(name=='user-data/mpvnet/video-selection-revision');properties[name]=value;return true
    end,
    set_property=function(name, value)
        if set_failure then return nil,'rejected' end
        writes[#writes+1]={name,value};properties[name]=readback_override or value
        if notify_device_write and name=='audio-device' then observers['audio-device']() end
        return true
    end,
    command_native=function(args)
        if args[1]=='loadfile' then
            assert(#args==2);history_loads[#history_loads+1]=args[2];return {}
        end
        assert(args[1]=='expand-path')
        if args[2]=='~~/script-modules/track-selector.lua' then return 'expanded/track-selector.lua' end
        if args[2]=='~~/script-modules/history-data.lua' then return 'expanded/history-data.lua' end
        if args[2]=='~~/helpers/history-store.ps1' then return 'expanded/history-store.ps1' end
        assert(args[2]==properties['watch-history-path']);return 'expanded/'..args[2]
    end,
    command_native_async=function(spec,done)
        assert(spec.name=='subprocess' and spec.playback_only==false and spec.capture_stdout and spec.capture_stderr)
        history_commands[#history_commands+1]={spec=spec,done=done}
        return {}
    end,
    add_key_binding=function(key,name,fn) assert(key==nil);bindings[name]=fn end,
    observe_property=function(name,kind,fn) assert(kind=='native');observers[name]=fn end,
    register_event=function(name,fn) events[name]=fn end,
    osd_message=function(text,duration) messages[#messages+1]={text,duration} end,
}
package.loaded['mp']=mp
package.loaded['mp.utils']={parse_json=function(raw) return history_json[raw] end}
package.loaded['mp.options']={read_options=function(options,name)
    assert(name=='select');options.history_date_format='!%Y/%m/%d'
end}
local request, opened, requests = nil, false, {}
local renderer = {
    open=function(value)
        assert(not opened,'old panel must close before another open')
        calls[#calls+1]='open';request=value;requests[#requests+1]=value;opened=true
        if open_failure then return false,'renderer unavailable' end
        return true
    end,
    close=function()
        calls[#calls+1]='close';opened=false
        -- Deliberately synchronous: callback retirement must precede this call.
        if request then request.close() end
    end,
    is_open=function() return opened end,
    update=function(tracks,current,notice,state)
        calls[#calls+1]='update';request.tracks=tracks;request.current_id=current;request.notice=notice
        request.state=state
    end,
}
local dofile=function(path)
    if path=='expanded/history-data.lua' then return make_history_data() end
    loads=loads+1;assert(path=='expanded/track-selector.lua')
    if load_failure then error('missing module') end
    return renderer
end

-- COMPLETE SOURCE IS INSERTED HERE

local function eq(actual, expected)
    assert(actual==expected,'expected '..tostring(expected)..', got '..tostring(actual))
end
local function clear() writes,messages,calls={},{},{} end
local function preserve_unrelated()
    eq(properties['secondary-sid'],2);eq(properties.mute,false);eq(properties.volume,83)
    eq(properties['audio-device'],'auto');eq(properties['sub-visibility'],true)
    for _,write in ipairs(writes) do
        assert(write[1]=='aid' or write[1]=='sid','unrelated property write '..write[1])
    end
end

local function history_setup()
    properties['watch-history-path']='watch history.jsonl'
    properties['save-watch-history']=true
    local raw='first\n'
    local first_path='D:/One/合成 "quoted".mkv'
    local second_path='D:/Two/合成 "quoted".mkv'
    history_json.first={path=first_path,time=1735689600}
    history_json.second={path=second_path,time=1767225600}
    io.open=function(path,mode)
        eq(path,'expanded/'..properties['watch-history-path']);eq(mode,'rb')
        return {read=function(_,size) return raw:sub(1,size) end,close=function() end}
    end
    return function(value) raw=value end,first_path,second_path
end

local hash1, hash2 = string.rep('a',64), string.rep('B',64)
local function finish_history(index, op, reply, hash, path)
    local command=assert(history_commands[index])
    local args=command.spec.args
    eq(args[1],'powershell.exe');eq(args[6],'-File');eq(args[7],'expanded/history-store.ps1')
    eq(args[8],'-Operation');eq(args[9],op);eq(args[10],'-Path')
    eq(args[11],'expanded/'..(path or properties['watch-history-path']))
    if hash then eq(args[12],'-ExpectedHash');eq(args[13],hash);eq(#args,13) else eq(#args,11) end
    history_json['helper reply']=reply
    command.done(true,{status=0,stdout='helper reply'})
end

function history_submit_revalidates_source_and_bytes()
    local set_raw, first, second=history_setup()
    bindings['select-history']();eq(request.kind,'history');eq(request.current_id,0)
    assert(request.state.empty_title:find('正在读取'));eq(#request.tracks,0)
    finish_history(1,'Read',{ok=true,content='first\n',hash=hash1})
    local original_id=request.tracks[1].id
    assert(request.state.can_clear);eq(request.tracks[1].history_path,first)
    set_raw('first\nsecond\n')
    local ok, reason=request.submit(original_id)
    eq(ok,false);assert(reason:find('已变化'));eq(#history_loads,0);eq(request.notice,'')
    finish_history(2,'Read',{ok=true,content='first\nsecond\n',hash=hash2})
    assert(request.notice:find('已变化'));eq(request.tracks[1].parent_text,'Two')
    eq(request.submit(original_id),false);eq(#history_loads,0)
    assert(request.submit(request.tracks[1].id));eq(history_loads[1],second)
    properties['watch-history-path']='另一份记录.jsonl'
    eq(request.submit(request.tracks[2].id),false);eq(#history_loads,1)
    finish_history(3,'Read',{ok=true,content='first\nsecond\n',hash=hash2})
    assert(request.submit(request.tracks[2].id));eq(history_loads[2],first)
end

function history_read_errors_retry_and_disabled_states_are_distinct()
    history_setup();properties['save-watch-history']=false
    bindings['select-history']()
    finish_history(1,'Read',{ok=false,code='io'})
    eq(request.state.empty_title,'未能读取播放历史');assert(request.state.can_retry)
    request.retry();request.retry();eq(#history_commands,2);eq(request.notice,'')
    finish_history(2,'Read',{ok=true,missing=true})
    eq(request.state.empty_title,'尚未启用播放历史');assert(request.state.can_retry)
    request.retry();properties['save-watch-history']=true
    finish_history(3,'Read',{ok=true,missing=true})
    eq(request.state.empty_title,'没有播放历史');eq(request.state.can_retry,false)
    bindings['select-history']();properties['save-watch-history']=false
    finish_history(4,'Read',{ok=true,content='first\n',hash=hash1})
    eq(#request.tracks,1);assert(request.state.can_clear)
    bindings['select-history']();local previous=properties['watch-history-path']
    properties['watch-history-path']='new location.jsonl'
    finish_history(5,'Read',{ok=true,content='first\n',hash=hash1},nil,previous)
    eq(#request.tracks,0);assert(request.state.empty_title:find('位置已变化'));assert(request.state.can_retry)
end

function history_clear_uses_the_snapshot_and_requires_another_confirmation_after_conflict()
    history_setup();bindings['select-history']()
    finish_history(1,'Read',{ok=true,content='first\n',hash=hash1})
    local original_id=request.tracks[1].id
    local completed={}
    local function done(ok, reason) completed[#completed+1]={ok,reason} end
    request.clear(done);request.clear(done);request.retry();eq(#history_commands,2)
    eq(request.submit(original_id),false)
    eq(completed[1][1],false)
    finish_history(2,'Clear',{ok=false,code='conflict'},hash1)
    eq(completed[2][1],false);assert(completed[2][2]:find('本次未清空'))
    finish_history(3,'Read',{ok=true,content='first\nsecond\n',hash=hash2})
    eq(#request.tracks,2);assert(request.tracks[1].id>original_id)
    request.clear(done)
    finish_history(4,'Clear',{ok=false,code='uncertain'},hash2)
    assert(completed[3][2]:find('未能确认'));assert(not completed[3][2]:find('已保留'))
    finish_history(5,'Read',{ok=true,content='first\nsecond\n',hash=hash2})
    request.clear(done)
    finish_history(6,'Clear',{ok=true},hash2)
    eq(completed[4][1],true);assert(opened)
    finish_history(7,'Read',{ok=true,content='',hash=hash1})
    eq(request.state.empty_title,'没有播放历史');assert(request.notice:find('已清空'))
    eq(#request.tracks,0);assert(not request.state.can_clear);eq(#history_loads,0)
end

function history_late_replies_do_not_revive_closed_or_replaced_panel()
    history_setup();bindings['select-history']();local old=request
    bindings['select-audio']();clear()
    finish_history(1,'Read',{ok=true,content='first\n',hash=hash1})
    eq(#calls,0);eq(request.kind,'audio');eq(old.submit(1),false)
    old.retry();eq(#history_commands,1);old.close();assert(opened)
    bindings['select-history']();finish_history(2,'Read',{ok=true,content='first\n',hash=hash1})
    local old_clear=request;local completed=false
    request.clear(function() completed=true end)
    events['start-file']();assert(not opened)
    bindings['select-audio']();clear()
    finish_history(3,'Clear',{ok=true},hash1)
    eq(#history_commands,3);eq(#calls,0);eq(completed,false);eq(request.kind,'audio')
    eq(old_clear.submit(1),false);eq(#history_loads,0)
end

function lazy_load_and_named_bindings()
    eq(loads,0);assert(bindings['select-subtitle']);assert(bindings['select-audio'])
    eq(observers['track-list']~=nil,true);eq(observers.aid~=nil,true);eq(observers.sid~=nil,true)
    bindings['select-audio']();eq(loads,1);eq(request.kind,'audio');eq(request.current_id,3)
    bindings['select-subtitle']();eq(loads,1);eq(request.kind,'subtitle')
    eq(calls[1],'close');eq(calls[2],'open');eq(calls[3],'close');eq(calls[4],'open')
end
function audio_metadata_and_filter_are_preserved()
    bindings['select-audio']();eq(#request.tracks,2);eq(request.tracks[1],audio)
    eq(request.tracks[1]['unknown-metadata'],audio['unknown-metadata'])
    eq(request.tracks[1]['demux-samplerate'],48000);eq(request.tracks[2].id,5)
    clear();local ok,error=request.submit(5);assert(ok,error);eq(properties.aid,'5')
    eq(#writes,1);eq(writes[1][1],'aid');eq(properties.sid,1);preserve_unrelated()
end
function current_audio_and_explicit_off_disable_audio()
    bindings['select-audio']();assert(request.submit(3));eq(properties.aid,'no')
    renderer.close();bindings['select-audio']();assert(request.submit('3'));eq(properties.aid,'3')
    renderer.close();bindings['select-audio']();assert(request.submit(0));eq(properties.aid,'no')
    preserve_unrelated();eq(properties.sid,1)
end
function subtitle_filter_and_toggle_regression()
    bindings['select-subtitle']();eq(#request.tracks,1);eq(request.tracks[1],subtitle)
    assert(request.submit(1));eq(properties.sid,'no')
    renderer.close();bindings['select-subtitle']();assert(request.submit(1));eq(properties.sid,'1')
    renderer.close();bindings['select-subtitle']();assert(request.submit(0));eq(properties.sid,'no')
    eq(properties.aid,3);preserve_unrelated()
end
function invalid_ids_recheck_live_tracks_without_observer_notification()
    for _,kind in ipairs({'audio','subtitle'}) do
        properties['track-list']={subtitle,audio,{type='sub',id=2,title='Bilibili Danmaku'}}
        bindings['select-'..kind]();clear()
        local foreign=kind=='audio' and 1 or 3
        local ok,error=request.submit(foreign);eq(ok,false);assert(error:find('已移除'))
        eq(#writes,0);eq(calls[1],'update')
        eq(request.submit(2),false);eq(request.submit('invalid'),false)
        properties['track-list']={}
        eq(request.submit(kind=='audio' and 3 or 1),false);eq(#writes,0);eq(#request.tracks,0)
        preserve_unrelated()
    end
end
function same_id_retyped_or_changed_to_danmaku_is_rejected()
    bindings['select-audio']();properties['track-list']={{type='sub',id=3}}
    eq(request.submit(3),false);eq(#writes,0)
    properties['track-list']={subtitle};bindings['select-subtitle']()
    properties['track-list']={{type='sub',id=1,title='Bilibili Danmaku'}}
    eq(request.submit(1),false);eq(#writes,0)
end
function current_selection_is_read_again_at_submit()
    bindings['select-audio']();properties.aid=5
    assert(request.submit(5));eq(properties.aid,'no')
    properties.sid='no';bindings['select-subtitle']();properties.sid=1
    assert(request.submit(1));eq(properties.sid,'no');preserve_unrelated()
end
function empty_lists_can_open_and_disable()
    properties['track-list']={}
    for _,kind in ipairs({'audio','subtitle'}) do
        bindings['select-'..kind]();assert(opened);eq(#request.tracks,0)
        eq(request.submit(99),false);assert(request.submit(0));preserve_unrelated()
    end
    eq(properties.aid,'no');eq(properties.sid,'no')
end
function relevant_observers_refresh_only_active_kind()
    for _,kind in ipairs({'audio','subtitle'}) do
        bindings['select-'..kind]();clear()
        local property=kind=='audio' and 'aid' or 'sid'
        local other=kind=='audio' and 'sid' or 'aid'
        observers[other]();eq(#calls,0)
        properties[property]='no';observers[property]();eq(#calls,1);eq(request.current_id,'no')
        properties['track-list']={};observers['track-list']();eq(#calls,2);eq(#request.tracks,0)
        eq(#writes,0);renderer.close();clear()
        observers['track-list']();observers[property]();eq(#calls,0)
        properties['track-list']={subtitle,audio}
    end
end
function close_retires_submit_and_writes_nothing()
    bindings['select-audio']();local old=request;clear();renderer.close()
    eq(old.submit(3),false);eq(old.submit(0),false);eq(#writes,0)
    old.close();observers['track-list']();eq(#calls,1);preserve_unrelated()
end
function repeated_open_retires_old_callback_before_synchronous_close()
    bindings['select-audio']();local old=request
    bindings['select-audio']();clear()
    eq(old.submit(0),false);eq(#writes,0)
    -- A delayed second close must not retire the new request.
    old.close();assert(request.submit(5));eq(properties.aid,'5');eq(#writes,1)
end
function cross_kind_callbacks_cannot_submit_or_close_new_panel()
    for _,kind in ipairs({'audio','subtitle','audio'}) do
        local old=request
        bindings['select-'..kind]();clear()
        if old then
            eq(old.submit(0),false);old.close();eq(#writes,0);assert(opened)
        end
        assert(request.submit(0));eq(#writes,1)
        eq(writes[1][1],kind=='audio' and 'aid' or 'sid');preserve_unrelated()
    end
end
function lifecycle_invalidates_same_id_and_closed_callbacks()
    for _,event in ipairs({'start-file','end-file','shutdown'}) do
        for _,kind in ipairs({'audio','subtitle'}) do
            bindings['select-'..kind]();local old=request;clear()
            events[event]();assert(not opened);eq(old.submit(0),false);eq(#writes,0)
            bindings['select-'..kind]();local current=request;old.close()
            eq(old.submit(kind=='audio' and 3 or 1),false)
            assert(current.submit(kind=='audio' and 3 or 1));preserve_unrelated()
        end
    end
end
function write_failure_keeps_request_usable()
    for _,kind in ipairs({'audio','subtitle'}) do
        bindings['select-'..kind]();clear();set_failure=true
        local ok,error=request.submit(0);eq(ok,false);assert(error:find('未能切换'))
        eq(#writes,0);assert(opened)
        set_failure=false;assert(request.submit(0));eq(#writes,1);preserve_unrelated()
    end
end
function missing_module_reports_failure_and_can_retry()
    load_failure=true;bindings['select-audio']();eq(loads,1);eq(#messages,1)
    assert(messages[1][1]:find('音轨'));eq(#calls,0);eq(#writes,0)
    load_failure=false;bindings['select-subtitle']();eq(loads,2);assert(opened)
    assert(request.submit(0));eq(properties.sid,'no')
end
function invalid_module_contract_is_rejected()
    renderer.update=nil;bindings['select-audio']();eq(#messages,1);eq(#calls,0);eq(#writes,0)
end
function open_failure_retires_request_and_cleans_partial_panel()
    open_failure=true;bindings['select-audio']();local failed=request
    eq(#messages,1);eq(messages[1][1],'renderer unavailable');assert(not opened)
    eq(failed.submit(0),false);eq(#writes,0)
    open_failure=false;bindings['select-subtitle']();failed.close()
    assert(request.submit(0));eq(properties.sid,'no');preserve_unrelated()
end

local function chapter_writes_only()
    eq(properties.aid,3);eq(properties.sid,1)
    eq(properties['secondary-sid'],2);eq(properties.mute,false);eq(properties.volume,83)
    eq(properties['audio-device'],'auto');eq(properties['sub-visibility'],true)
    for _,write in ipairs(writes) do eq(write[1],'chapter') end
end
function chapter_ids_keep_original_index_and_missing_title()
    properties['chapter-list']={{time=0,title='Opening'},{title='Unknown time'},
        {time=-1},{time=0/0},{time=math.huge},{time='83'},
        {time=83.99},{time=142,title=123}}
    bindings['select-chapter']();eq(request.kind,'chapter');eq(request.current_id,0)
    eq(#request.tracks,3);eq(request.tracks[1].id,1);eq(request.tracks[2].id,7);eq(request.tracks[3].id,8)
    eq(request.tracks[2].title,'');eq(request.tracks[2].time_text,'01:23');eq(request.tracks[3].title,'')
    for _,id in ipairs({0,-1,2,3,4,5,6,99,1.5,math.huge,0/0,'invalid'}) do
        eq(request.submit(id),false);eq(#writes,0)
    end
    assert(request.submit(7));eq(properties.chapter,'6');chapter_writes_only()
end
function chapter_time_format_uses_duration_or_largest_timestamp()
    bindings['select-chapter']();eq(request.tracks[2].time_text,'01:23')
    properties.duration=3600;observers.duration();eq(request.tracks[2].time_text,'00:01:23')
    properties.duration=nil;observers.duration();eq(request.tracks[2].time_text,'01:23')
    renderer.close();properties['chapter-list']={{time=1.9},{time=3661.5}}
    bindings['select-chapter']();eq(request.tracks[1].time_text,'00:00:01');eq(request.tracks[2].time_text,'01:01:01')
    eq(#writes,0);chapter_writes_only()
end
function current_chapter_reselection_writes_zero_based_chapter()
    properties.chapter=1;bindings['select-chapter']();eq(request.current_id,2)
    assert(request.submit(2));eq(properties.chapter,'1');eq(writes[1][2],'1')
    -- Re-selecting the same chapter remains a seek-to-start request.
    assert(request.submit('2'));eq(#writes,2);eq(writes[2][2],'1')
    properties.chapter=0;observers.chapter();eq(request.current_id,1)
    assert(request.submit(1));eq(properties.chapter,'0');chapter_writes_only()
end
function no_chapters_and_before_first_chapter_do_not_invent_selection()
    bindings['select-chapter']();eq(request.current_id,0);eq(#writes,0)
    properties.chapter=-1;observers.chapter();eq(request.current_id,0)
    renderer.close();properties['chapter-list']={};bindings['select-chapter']()
    assert(opened);eq(#request.tracks,0);eq(request.current_id,0)
    eq(request.submit(0),false);eq(request.submit(1),false);eq(#writes,0)
end
function chapter_reorder_observer_cannot_accept_pending_old_index()
    bindings['select-chapter']();local submit=request.submit
    properties['chapter-list']={{time=83,title='Middle'},{time=0,title='Opening'},{time=142.9}}
    observers['chapter-list']();eq(request.tracks[1].title,'Opening');eq(request.tracks[1].time_text,'00:00')
    properties.chapter=1;observers.chapter();eq(request.current_id,2)
    eq(request.tracks[1].title,'Opening')
    local ok,error=submit(1);eq(ok,false);assert(error:find('列表已变化'));eq(#writes,0)
    eq(request.tracks[1].title,'Middle');eq(request.tracks[1].time_text,'01:23')
    assert(request.submit(1));eq(properties.chapter,'0');chapter_writes_only()
end
function chapter_deletion_and_in_place_changes_require_new_choice()
    bindings['select-chapter']();properties['chapter-list'][2]=nil
    properties['chapter-list']={{time=0,title='Opening'},{time=142.9}}
    eq(request.submit(2),false);eq(#writes,0);eq(request.tracks[2].title,'')
    assert(request.submit(2));eq(properties.chapter,'1')
    clear();properties['chapter-list'][2].title='Renamed same timestamp'
    eq(request.submit(2),false);eq(#writes,0)
    assert(request.submit(2));eq(properties.chapter,'1')
    clear();properties['chapter-list'][2].time=143
    eq(request.submit(2),false);eq(#writes,0);eq(request.tracks[2].time_text,'02:23')
    assert(request.submit(2));chapter_writes_only()
end
function chapter_same_time_different_titles_cannot_silently_swap()
    properties['chapter-list']={{time=0,title='A'},{time=0,title='B'}}
    bindings['select-chapter']();properties['chapter-list']={{time=0,title='B'},{time=0,title='A'}}
    eq(request.submit(1),false);eq(#writes,0);eq(request.tracks[1].title,'B')
    assert(request.submit(2));eq(properties.chapter,'1');chapter_writes_only()
end
function chapter_observers_do_not_interfere_with_audio_or_subtitle()
    for _,kind in ipairs({'audio','subtitle'}) do
        bindings['select-'..kind]();clear()
        observers.chapter();observers['chapter-list']();observers.duration();eq(#calls,0);eq(#writes,0)
        assert(request.submit(kind=='audio' and 3 or 1))
    end
    bindings['select-chapter']();clear()
    observers.aid();observers.sid();observers['track-list']();eq(#calls,0);eq(#writes,0)
    observers.chapter();eq(calls[1],'update')
end
function chapter_stale_callbacks_cancel_and_write_failures_are_safe()
    for _,event in ipairs({'start-file','end-file','shutdown'}) do
        bindings['select-chapter']();local old=request;events[event]();clear()
        eq(old.submit(1),false);eq(#writes,0)
        bindings['select-chapter']();old.close();assert(request.submit(1));chapter_writes_only()
    end
    bindings['select-chapter']();local old=request;clear();renderer.close()
    eq(old.submit(1),false);eq(#writes,0)
    bindings['select-chapter']();set_failure=true
    local ok,error=request.submit(1);eq(ok,false);assert(error:find('未能切换章节'));eq(#writes,0);assert(opened)
    set_failure=false;assert(request.submit(1));chapter_writes_only()
end
function chapter_cross_kind_retirement_rejects_old_submissions()
    bindings['select-chapter']();local old=request
    bindings['select-audio']();clear();eq(old.submit(1),false);old.close()
    assert(request.submit(5));eq(properties.aid,'5')
    old=request;bindings['select-chapter']();clear();eq(old.submit(0),false);old.close()
    assert(request.submit(2));eq(properties.chapter,'1');eq(properties.sid,1)
end

local function device_fixture()
    properties['audio-device-list']={{name='auto',description='Automatic'},
        {name='wasapi/speakers',description='扬声器'}, {name='wasapi/headset',description='耳机'}}
    properties['audio-device']='auto'
    bindings['select-device']()
end
local function device_row(name)
    for _,row in ipairs(request.tracks) do if row.device_name==name then return row end end
end
local function device_preserves_other_settings()
    eq(properties.aid,3);eq(properties.sid,1);eq(properties['secondary-sid'],2)
    eq(properties.volume,83);eq(properties.mute,false);eq(properties['sub-visibility'],true)
    for _,write in ipairs(writes) do eq(write[1],'audio-device') end
end
function device_auto_repeat_and_identity_submission()
    device_fixture();eq(request.kind,'device');eq(device_row('auto').title,'自动选择')
    eq(request.current_id,device_row('auto').id);eq(request.notice,'')
    local id=device_row('wasapi/headset').id
    clear();assert(request.submit(id));eq(properties['audio-device'],'wasapi/headset')
    assert(request.submit(id));eq(writes[2][2],'wasapi/headset')
    assert(request.submit(device_row('auto').id));eq(properties['audio-device'],'auto')
    device_preserves_other_settings()
end
function device_reorder_remove_reinsert_never_reuses_identity()
    device_fixture();local a=device_row('wasapi/speakers').id;local b=device_row('wasapi/headset').id
    properties['audio-device-list']={{name='wasapi/headset',description='Headset renamed'}, {name='wasapi/new',description='New'}}
    observers['audio-device-list']();eq(device_row('wasapi/headset').id,b)
    local c=device_row('wasapi/new').id;assert(c~=a and c~=b);eq(request.current_id,0);assert(request.notice~='')
    clear();eq(request.submit(a),false);eq(#writes,0)
    assert(request.submit(b));eq(properties['audio-device'],'wasapi/headset')
    properties['audio-device-list']={{name='wasapi/new'},{name='wasapi/speakers'},{name='wasapi/headset'}}
    observers['audio-device-list']();eq(device_row('wasapi/speakers').id,a);eq(device_row('wasapi/new').id,c)
    -- A reordering without any notification still submits the original name.
    properties['audio-device-list']={{name='wasapi/headset'},{name='wasapi/new'},{name='wasapi/speakers'}}
    assert(request.submit(a));eq(properties['audio-device'],'wasapi/speakers');device_preserves_other_settings()
end
function device_empty_invalid_names_and_missing_selected_notice()
    properties['audio-device-list']={{name=''},{name='  '},{name=false},{name='bad\nname'},{description='no name'}}
    bindings['select-device']();eq(#request.tracks,0);eq(request.current_id,0);eq(request.notice,'')
    clear();eq(request.submit(0),false);eq(#writes,0)
    properties['audio-device-list']={{name='unique',description=''}, {name='unique',description='duplicate id'}}
    observers['audio-device-list']();eq(#request.tracks,1);eq(request.tracks[1].title,'unique');assert(request.notice~='')
    properties['audio-device']='unique';observers['audio-device']();eq(request.current_id,request.tracks[1].id);eq(request.notice,'')
end
function device_duplicate_descriptions_and_unicode_suffixes_are_distinct()
    local names={'wasapi/甲相同后缀abcdef','wasapi/乙相同后缀abcdef','wasapi/另一个abcdef'}
    properties['audio-device-list']={}
    for _,name in ipairs(names) do properties['audio-device-list'][#properties['audio-device-list']+1]={name=name,description='同名设备'} end
    properties['audio-device-list'][4]={name='literal',description='同名设备 · abcdef'}
    bindings['select-device']();local titles={}
    local function valid_utf8(text)
        local at=1
        while at<=#text do
            local b=text:byte(at);local size=b<128 and 1 or b>=194 and b<224 and 2 or b>=224 and b<240 and 3 or b>=240 and b<245 and 4
            assert(size,'orphan UTF8 continuation')
            for j=1,size-1 do local next=text:byte(at+j);assert(next and next>=128 and next<192,'truncated UTF8') end
            at=at+size
        end
    end
    for _,row in ipairs(request.tracks) do assert(not titles[row.title]);titles[row.title]=true;valid_utf8(row.title);assert(row.detail_title~='') end
    local target=device_row(names[2]);assert(request.submit(target.id));eq(properties['audio-device'],names[2])
    renderer.close()
    properties['audio-device-list']={{name='named-auto',description='自动选择'},{name='auto',description='Automatic'}}
    bindings['select-device']();eq(device_row('auto').title,'自动选择')
    assert(device_row('named-auto').title~=device_row('auto').title)
end
function device_failure_readback_mismatch_and_sync_observer_retry()
    device_fixture();local id=device_row('wasapi/headset').id;clear()
    set_failure=true;eq(request.submit(id),false);eq(#writes,0);assert(opened)
    set_failure=false;readback_override='auto';eq(request.submit(id),false);eq(properties['audio-device'],'auto');assert(opened)
    readback_override=nil;notify_device_write=true;assert(request.submit(id));eq(properties['audio-device'],'wasapi/headset')
    eq(request.current_id,id);eq(request.notice,'');device_preserves_other_settings()
end
function device_disappearing_without_notice_never_writes_fallback()
    device_fixture();local id=device_row('wasapi/headset').id;clear()
    properties['audio-device-list']={{name='auto'},{name='replacement'}}
    eq(request.submit(id),false);eq(#writes,0);eq(properties['audio-device'],'auto')
    eq(request.submit(0),false);eq(#writes,0);device_preserves_other_settings()
end
function device_observers_media_and_cross_kind_retire_callbacks()
    device_fixture();clear();observers['track-list']();observers.aid();observers.sid();observers.chapter();eq(#calls,0)
    local old=request;events['start-file']();clear();eq(old.submit(1),false);eq(#writes,0)
    bindings['select-device']();old=request;bindings['select-audio']();clear()
    observers['audio-device-list']();observers['audio-device']();eq(#calls,0)
    eq(old.submit(1),false);old.close();assert(opened);eq(request.kind,'audio');eq(#writes,0)
    assert(request.submit(5));eq(properties.aid,'5')
end

function video_selection_filters_and_retires_restore_revision()
    properties.vid=4
    properties['track-list'][#properties['track-list']+1]={type='video',id=8,title='Camera B',image=false,['demux-w']=1280}
    properties['track-list'][#properties['track-list']+1]={type='video',id=9,title='Cover',image=true,albumart=true}
    bindings['select-video']();eq(request.kind,'video');eq(#request.tracks,3)
    eq(request.current_id,4);eq(request.tracks[2]['demux-w'],1280)
    clear();assert(request.submit(8));eq(properties.vid,'8');eq(properties['user-data/mpvnet/video-selection-revision'],1)
    assert(request.submit(8));eq(properties.vid,'no');eq(properties['user-data/mpvnet/video-selection-revision'],2)
    assert(request.submit(0));eq(properties.vid,'no');eq(properties['user-data/mpvnet/video-selection-revision'],3)
    eq(properties.aid,3);eq(properties.sid,1);eq(properties['audio-device'],'auto');eq(properties.volume,83);eq(properties.mute,false)
    for _,write in ipairs(writes) do eq(write[1],'vid') end
end
function video_failure_and_stale_callbacks_do_not_invalidate_restore()
    properties.vid=4;bindings['select-video']();clear()
    eq(request.submit(3),false);eq(#writes,0);eq(properties['user-data/mpvnet/video-selection-revision'],nil)
    set_failure=true;eq(request.submit(4),false);eq(properties['user-data/mpvnet/video-selection-revision'],nil)
    set_failure=false;local old=request;bindings['select-audio']();clear();eq(old.submit(4),false);eq(#writes,0)
    old.close();assert(opened);assert(request.submit(5));eq(properties.aid,'5');eq(properties.vid,4)
    bindings['select-video']();old=request;events['start-file']();eq(old.submit(0),false)
end
function video_observers_only_refresh_active_video()
    properties.vid=4;bindings['select-video']();clear()
    observers.aid();observers.sid();eq(#calls,0)
    properties.vid='no';observers.vid();eq(#calls,1);eq(request.current_id,'no')
    properties['track-list']={};observers['track-list']();eq(#request.tracks,0)
    clear();bindings['select-subtitle']();clear();observers.vid();eq(#calls,0);eq(#writes,0)
end

local function edition_fixture()
    properties['edition-list']={{id=0,title='影院版'},{id=7,title=''}}
    properties['current-edition']=0;properties.edition='auto'
    bindings['select-edition']()
end
function editions_use_actual_current_and_submit_original_index()
    edition_fixture();eq(request.kind,'edition');eq(request.current_id,1);eq(request.tracks[2].id,2)
    eq(request.tracks[2].title,'版本 8');eq(request.tracks[2].number_text,'8')
    clear();assert(request.submit(2));eq(properties.edition,'1');eq(properties['current-edition'],0)
    assert(request.submit(1));eq(properties.edition,'0')
    assert(request.submit(1));eq(properties.edition,'0')
    eq(properties.aid,3);eq(properties.sid,1);eq(properties.volume,83);eq(properties.mute,false)
    for _,write in ipairs(writes) do eq(write[1],'edition') end
end
function editions_reorder_or_title_change_rejects_old_selection()
    edition_fixture();clear();local first=properties['edition-list'][1];local second=properties['edition-list'][2]
    properties['edition-list']={second,first};observers['edition-list']()
    eq(request.tracks[1].title,'影院版')
    eq(request.submit(1),false);eq(#writes,0);eq(request.tracks[1].title,'版本 8')
    assert(request.submit(1));eq(properties.edition,'0');clear()
    properties['edition-list'][1].title='Changed';eq(request.submit(1),false);eq(#writes,0)
    assert(request.submit(1));eq(properties.edition,'0')
end
function editions_missing_single_failure_and_media_invalidation()
    edition_fixture();clear();eq(request.submit(0),false);eq(#writes,0)
    set_failure=true;eq(request.submit(2),false);assert(opened);set_failure=false
    local old=request;events['start-file']();eq(old.submit(2),false);eq(#writes,0)
    properties['edition-list']={{id=0}};bindings['select-edition']();eq(#request.tracks,1);eq(request.submit(1),false)
    properties['edition-list']={};eq(request.submit(1),false);eq(#request.tracks,0)
    properties['edition-list']={{id=0},{id=1}};bindings['select-edition']()
    properties['current-edition']=1;observers['current-edition']();eq(request.current_id,2)
    properties['current-edition']=-1;observers['current-edition']();eq(request.current_id,0)
    old=request;bindings['select-audio']();clear();eq(old.submit(1),false);old.close();assert(opened)
    observers['current-edition']();eq(#calls,0);assert(request.submit(5));eq(properties.aid,'5')
end
function editions_set_can_synchronously_reload_without_reviving_old_session()
    edition_fixture();local old=request;local setter=mp.set_property
    mp.set_property=function(name,value)
        assert(name=='edition');events['start-file']();return setter(name,value)
    end
    assert(old.submit(2));eq(properties.edition,'1');assert(not opened)
    bindings['select-edition']();local current=request;old.close();eq(old.submit(1),false);assert(opened)
    mp.set_property=setter;assert(current.submit(1));eq(properties.edition,'0')
end

local function advanced_fixture()
    properties['track-list']={subtitle,{type='sub',id=2,title='Bilibili Danmaku'},
        {type='sub',id=3,title='English',lang='eng'},audio}
    properties.sid=1;properties['secondary-sid']=2
    properties['secondary-sub-visibility']=false;properties['secondary-sub-ass-override']=false
end
function advanced_slots_include_all_tracks_and_do_not_mutate_source()
    advanced_fixture();bindings['select-primary']();eq(#request.tracks,3);eq(request.current_id,1)
    eq(request.tracks[2].slot_label,'已用于次字幕');assert(request.tracks[2].blocked_reason~='')
    eq(properties['track-list'][2].slot_label,nil);eq(request.notice,'')
    clear();assert(request.submit(3));eq(properties.sid,'3');eq(properties['secondary-sid'],2);eq(#writes,1);eq(writes[1][1],'sid')
    assert(request.submit(3));eq(properties.sid,'no');assert(request.submit(0));eq(properties.sid,'no')
    bindings['select-subtitle']();eq(#request.tracks,2)
    for _,row in ipairs(request.tracks) do assert(row.title~='Bilibili Danmaku') end
end
function advanced_secondary_preserves_other_slot_visibility_and_danmaku_options()
    advanced_fixture();bindings['select-secondary']();eq(#request.tracks,3);eq(request.current_id,2)
    eq(request.tracks[1].slot_label,'已用于主字幕');assert(request.notice:find('弹幕',1,true))
    clear();assert(request.submit(3));eq(properties['secondary-sid'],'3');eq(properties.sid,1)
    eq(properties['secondary-sub-visibility'],false);eq(properties['secondary-sub-ass-override'],false)
    eq(properties['sub-visibility'],true);eq(properties.aid,3);eq(properties.volume,83)
    for _,write in ipairs(writes) do eq(write[1],'secondary-sid') end
    observers['secondary-sid']();assert(request.notice:find('当前隐藏',1,true))
    assert(request.submit(3));eq(properties['secondary-sid'],'no');eq(properties.sid,1)
end
function advanced_occupancy_is_checked_again_at_submit_and_observed()
    advanced_fixture();bindings['select-secondary']();clear();eq(request.submit(1),false);eq(#writes,0)
    properties.sid=3 -- no notification: the displayed English row was previously free
    eq(request.submit(3),false);eq(#writes,0);eq(properties['secondary-sid'],2)
    observers.sid();eq(request.tracks[3].slot_label,'已用于主字幕')
    properties.sid='no';observers.sid();eq(request.tracks[3].slot_label,nil)
    assert(request.submit(3));eq(properties['secondary-sid'],'3')
    properties.sid=1;bindings['select-subtitle']();clear();eq(request.submit(3),false);eq(#writes,0)
end
function advanced_auto_slots_failures_and_stale_sessions_are_safe()
    advanced_fixture();properties.sid='auto';properties['current-tracks/sub/id']=1
    properties['secondary-sid']='auto';properties['current-tracks/sub2/id']=2
    bindings['select-primary']();eq(request.current_id,1);eq(request.submit(2),false)
    clear();set_failure=true;eq(request.submit(3),false);eq(#writes,0)
    set_failure=false;readback_override='auto';eq(request.submit(3),false);assert(opened)
    readback_override=nil;assert(request.submit(3));eq(properties.sid,'3')
    local old=request;bindings['select-secondary']();clear();old.close();eq(old.submit(0),false);eq(#writes,0)
    assert(request.submit(0));eq(properties['secondary-sid'],'no');eq(properties.sid,'3')
    old=request;events['start-file']();clear();eq(old.submit(0),false);eq(#writes,0)
    bindings['select-primary']();properties['track-list']={};observers['track-list']();eq(#request.tracks,0)
    eq(request.submit(3),false);eq(#writes,0)
end


local function all_fixture()
    properties['track-list']={
        {type='sub',id=1,title='Same'}, {type='audio',id=1,title='Same',codec='aac'},
        {type='video',id=1,title='Same'}, {type='video',id=2,title='Camera'},
        {type='audio',id=2,title='English'}, {type='sub',id=2,title='Bilibili Danmaku'},
        {type='sub',id=3,title='English'}}
    properties.vid=1;properties.aid=1;properties.sid=1;properties['secondary-sid']=2
    bindings['select-tracks']()
end
local function all_row(kind,id)
    for _,row in ipairs(request.tracks) do
        if row.display_kind==kind and row.number_text==tostring(id) then return row end
    end
end
function all_tracks_use_composite_identity_and_independent_current_markers()
    all_fixture();eq(request.kind,'all');eq(#request.tracks,7);eq(request.current_id,0)
    local video,audio,sub=all_row('video',1),all_row('audio',1),all_row('primary',1)
    assert(video.id~=audio.id and video.id~=sub.id and audio.id~=sub.id)
    assert(video.current and audio.current and sub.current)
    eq(request.tracks[1].display_kind,'video');eq(request.tracks[3].display_kind,'audio');eq(request.tracks[5].display_kind,'primary')
    eq(all_row('primary',2).slot_label,'已用于次字幕')
    eq(properties['track-list'][1].display_kind,nil);eq(properties['track-list'][1].current,nil)
    clear();assert(request.submit(audio.id));eq(properties.aid,'no');eq(properties.sid,1);eq(properties.vid,1)
    assert(request.submit(sub.id));eq(properties.sid,'no');eq(properties.vid,1)
    assert(request.submit(video.id));eq(properties.vid,'no');eq(properties['user-data/mpvnet/video-selection-revision'],1)
    eq(writes[1][1],'aid');eq(writes[2][1],'sid');eq(writes[3][1],'vid')
    eq(properties['secondary-sid'],2);eq(properties.volume,83);eq(properties.mute,false);eq(properties['audio-device'],'auto')
end
function all_tracks_reorder_removal_and_retyping_preserve_identity()
    all_fixture();local video=all_row('video',2).id;local audio=all_row('audio',2).id
    local source=properties['track-list'];properties['track-list']={source[5],source[4],source[1]}
    observers['track-list']();eq(all_row('video',2).id,video);eq(all_row('audio',2).id,audio)
    clear();assert(request.submit(audio));eq(properties.aid,'2');eq(properties.vid,1)
    properties['track-list']={{type='video',id=2},{type='sub',id=2}}
    eq(request.submit(audio),false);eq(#writes,1)
    assert(all_row('primary',2).id~=audio);assert(request.submit(video));eq(properties.vid,'2')
    local removed=all_row('primary',2).id
    properties['track-list']={{type='video',id=2},{type='sub',id=4}};observers['track-list']()
    assert(all_row('primary',4).id~=removed);eq(request.submit(removed),false);eq(#writes,2)
end
function all_tracks_occupancy_race_failure_and_auto_current_are_rechecked()
    all_fixture();local sub=all_row('primary',3).id;local video=all_row('video',2).id
    clear();properties['secondary-sid']=3
    eq(request.submit(sub),false);eq(#writes,0);eq(all_row('primary',3).slot_label,'已用于次字幕')
    properties['secondary-sid']='no';observers['secondary-sid']();eq(all_row('primary',3).slot_label,nil)
    properties.sid='auto';properties['current-tracks/sub/id']=3;observers['current-tracks/sub/id']()
    assert(all_row('primary',3).current);assert(request.submit(sub));eq(properties.sid,'no')
    set_failure=true;eq(request.submit(video),false);eq(properties['user-data/mpvnet/video-selection-revision'],nil)
    set_failure=false;readback_override='no';eq(request.submit(video),false);eq(properties['user-data/mpvnet/video-selection-revision'],nil)
    readback_override=nil;properties.vid='auto';properties['current-tracks/video/id']=2
    observers['current-tracks/video/id']();assert(all_row('video',2).current)
    assert(request.submit(video));eq(properties.vid,'no');eq(properties['user-data/mpvnet/video-selection-revision'],1)
    properties.aid='auto';properties['current-tracks/audio/id']=2;observers['current-tracks/audio/id']()
    assert(all_row('audio',2).current)
    properties['sub-visibility']=false;observers['sub-visibility']();assert(request.notice:find('主字幕当前隐藏',1,true))
end
function all_tracks_observers_and_session_retirement_do_not_cross_instances()
    all_fixture();local old=request;local id=all_row('audio',2).id
    clear();observers.aid();observers.vid();observers.sid();eq(#calls,3)
    observers.chapter();observers['audio-device']();observers['current-edition']();eq(#calls,3)
    bindings['select-audio']();clear();old.close();eq(old.submit(id),false);eq(#writes,0);assert(opened)
    assert(request.submit(2));eq(properties.aid,'2')
    bindings['select-tracks']();old=request;id=all_row('video',2).id;events['start-file']();clear()
    eq(old.submit(id),false);eq(#writes,0)
    bindings['select-tracks']();old.close();assert(opened)
    clear();eq(request.submit(0),false);eq(request.submit(999),false);eq(#writes,0)
    properties['track-list']={};observers['track-list']();eq(#request.tracks,0)
end
