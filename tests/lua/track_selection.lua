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
    ['audio-device']='auto', ['sub-visibility']=true}
local function get(name, default)
    if properties[name] ~= nil then return properties[name] end
    return default
end
local set_failure, load_failure, open_failure
local loads = 0
local mp = {
    get_property_native=get,
    set_property=function(name, value)
        if set_failure then return nil,'rejected' end
        writes[#writes+1]={name,value};properties[name]=value;return true
    end,
    command_native=function(args)
        assert(args[1]=='expand-path' and args[2]=='~~/script-modules/track-selector.lua')
        return 'expanded/track-selector.lua'
    end,
    add_key_binding=function(key,name,fn) assert(key==nil);bindings[name]=fn end,
    observe_property=function(name,kind,fn) assert(kind=='native');observers[name]=fn end,
    register_event=function(name,fn) events[name]=fn end,
    osd_message=function(text,duration) messages[#messages+1]={text,duration} end,
}
package.loaded['mp']=mp
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
    update=function(tracks,current)
        calls[#calls+1]='update';request.tracks=tracks;request.current_id=current
    end,
}
local dofile=function(path)
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
