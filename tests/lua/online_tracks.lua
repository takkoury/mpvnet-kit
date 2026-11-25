local function video(id, height, protocol)
    return {format_id=id, height=height, vcodec='av1', acodec='none', protocol=protocol or 'https'}
end
local function audio(id, lang, note)
    return {format_id=id, language=lang, format_note=note, acodec='opus', vcodec='none', protocol='https'}
end
local hd, sd = video('a',1080), video('b',720)
local en, ja = audio('1-en','en-US','English original'), audio('2-ja','ja','Japanese')
local data = {extractor_key='Youtube', requested_formats={hd,en},
    formats={hd,sd,video('hls',720,'m3u8_native'),en,ja,audio('3-ja','ja','Japanese medium'),
        audio('4-ja','ja','Japanese commentary')}}

function check_catalog()
    local c = assert(M.catalog(data))
    assert(#c.video==2 and #c.audio==3)
    assert(c.video[2].id=='b' and c.audio[1].title:find('原声',1,true))
    local orig={id=14,type='video',external=false,['demux-h']=1080,codec='h264'}
    local rows=M.rows(c,'video',{orig})
    assert(rows[1].id==14 and rows[1].title=='1080p' and rows[1].codec=='h264')
    assert(rows[2].id>2^32 and rows[2].title=='720p' and not orig.title)
    local extra={orig,{id=15,type='video'}}
    assert(M.rows(c,'video',extra)==extra)
    local expression=M.format({video=c.video[2],audio=c.selected.audio})
    assert(expression:find('b[height=720]',1,true) and expression:find('1-en[language=en-US]',1,true))
    assert(M.audio_label(c,{{type='audio', selected=true, lang='und'}}):find('英语',1,true))
    assert(not M.audio_label(c,{{type='audio', selected=true, external=true}}))
    local voices={extractor_key='Youtube',requested_formats={hd,en},formats={hd,en,audio('dub','en-US','dubbed')}}
    assert(#M.catalog(voices).audio==2)
    assert(not M.catalog({is_live=true,extractor_key='Youtube', formats=data.formats,requested_formats={hd,en}}))
    assert(not M.catalog({extractor_key='Youtube',formats=data.formats}))
end

function check_reload(user_moved)
    local hooks, events, commands = {}, {}, 0
    local props={['user-data/mpv/ytdl/json-subprocess-result/stdout']='fixture',
        ['playlist-pos']=2, ['playlist/2/id']=8, ['playlist/2/filename']='page', path='page',
        ['time-pos']=130, seekable=true, pause=true, vid='auto', aid='auto'}
    local function get(name,default) if props[name]~=nil then return props[name] end;return default end
    local mp={get_property=get,get_property_number=get,get_property_native=get,
        set_property=function(k,v) props[k]=v;return true end,
        add_hook=function(k,p,fn) hooks[k..p]=fn end,register_event=function(k,fn) events[k]=fn end,
        osd_message=function() end, commandv=function(_,command,index)
            assert(command=='playlist-play-index' and index=='current')
            commands=commands+1;return true
        end}
    local state=M.new(mp,{parse_json=function()return data end})
    local sub={type='sub', id=3, external=true, title='Bilibili Danmaku', ['external-filename']='extra.ass'}
    props['track-list']={sub}
    assert(not state.switch('video',state.catalog().video[2].row_id) and commands==0,
        'a matching subtitle title must not authorize losing an external file')
    props['user-data/mpvnet/danmaku/reloadable-track']=sub.id
    assert(state.switch('video',state.catalog().video[2].row_id))
    assert(commands==1)
    events['end-file']({reason='stop',playlist_entry_id=8})
    hooks.on_after_end_file60()
    hooks.on_load9()
    assert(props['file-local-options/ytdl-format']:find('[height=720]',1,true))
    props['file-local-options/start']='42'
    hooks.on_preloaded45()
    assert(tonumber(props['file-local-options/start'])==130 and props.pause)
    events['end-file']({reason='error',playlist_entry_id=8})
    if user_moved then props['playlist/2/id']=20 end
    hooks.on_after_end_file60()
    if user_moved then assert(commands==1);return end
    assert(commands==2)
    hooks.on_load9()
    assert(props['file-local-options/ytdl-format']:find('[height=1080]',1,true))
    events['end-file']({reason='error',playlist_entry_id=8})
    hooks.on_after_end_file60()
    assert(commands==2)
end

function check_continuation()
    local hooks, events, commands = {}, {}, 0
    local items = {{id=7,filename='one'},{id=31,filename='two'},{id=29,filename='three'}}
    local props = {playlist=items, ['time-pos']=130, seekable=true, vid='auto', aid='auto',
        ['audio-params/samplerate']=48000,['user-data/mpv/ytdl/json-subprocess-result/stdout']='fixture'}
    local episode
    local function get(k,default) if props[k]~=nil then return props[k] end;return default end
    local mp={get_property=get,get_property_number=get,get_property_native=get,
        set_property=function(k,v) props[k]=v;return true end,
        add_hook=function(k,p,f) hooks[k..p]=f end,register_event=function(k,f) events[k]=f end,
        osd_message=function() end,commandv=function(_,cmd,where)
            assert(cmd=='playlist-play-index' and where=='current');commands=commands+1;return true
        end}
    local state=M.new(mp,{parse_json=function() return episode end})
    local function set_entry(i,formats,selected_video,selected_audio)
        local pos=i-1
        props['playlist-pos'],props['playlist-playing-pos']=pos,pos
        props.path=items[i].filename
        props['playlist/'..pos..'/id'],props['playlist/'..pos..'/filename']=items[i].id,props.path
        episode={id=props.path,extractor_key='Youtube', formats=formats,
            requested_formats={selected_video,selected_audio}}
        props['video-params/h']=selected_video.height
        props['file-local-options/start']='9'
        props['file-local-options/ytdl-format']='user-default'
        hooks.on_load9()
    end
    local function replay(i,formats,v,a)
        events['end-file']({reason='stop',playlist_entry_id=items[i].id})
        set_entry(i,formats,v,a)
        hooks.on_load45()
        hooks.on_preloaded45()
        events['playback-restart']()
    end
    local fs={hd,sd,en,ja}
    set_entry(1,fs,hd,en)
    assert(state.switch('video',state.catalog().video[2].row_id))
    replay(1,fs,sd,en)
    -- A video-only choice preserves the following episode's own default audio.
    local de=audio('de','de-DE','German')
    set_entry(2,{hd,sd,ja,de},hd,de)
    hooks.on_load45()
    assert(commands==2)
    replay(2,{hd,sd,ja,de},sd,de)
    assert(props['file-local-options/ytdl-format']:find('de[language=de-DE]',1,true))
    assert(props['file-local-options/start']=='9')
    local japanese
    for _,d in ipairs(state.catalog().audio) do if d.lang=='ja' then japanese=d end end
    assert(state.switch('audio',japanese.row_id))
    replay(2,{hd,sd,ja,de},sd,ja)
    -- Different format IDs, missing language. Keep the voice for a later item.
    local other_sd=video('new-sd',720)
    set_entry(3,{hd,other_sd,en},hd,en)
    hooks.on_load_fail45()
    assert(commands==4)
    replay(3,{hd,other_sd,en},other_sd,en)
    assert(props['file-local-options/ytdl-format']:find('new-sd[height=720]',1,true))
    assert(props['file-local-options/start']=='9')
    -- Missing height, available language. No resolution cap or carried seek.
    set_entry(1,{hd,en,ja},hd,en)
    hooks.on_load45()
    assert(commands==5)
    replay(1,{hd,en,ja},hd,ja)
    assert(props['file-local-options/ytdl-format']:find('2-ja[language=ja]',1,true))
    -- Reordering and appending entries keep identity. A default which already
    -- matches both choices should play in one pass.
    items[1],items[3]=items[3],items[1]
    set_entry(3,fs,sd,ja)
    hooks.on_load45();hooks.on_preloaded45()
    assert(commands==5 and props['file-local-options/ytdl-format']=='user-default')
    state.forget('audio')
    set_entry(2,fs,sd,en)
    hooks.on_load45()
    assert(commands==5)
    set_entry(1,fs,hd,en);hooks.on_load45()
    assert(commands==6)
    events['end-file']({reason='stop',playlist_entry_id=items[1].id})
    set_entry(1,fs,hd,en)
    events['end-file']({reason='error',playlist_entry_id=items[1].id})
    hooks.on_after_end_file60()
    assert(commands==7)
    set_entry(1,fs,hd,en);hooks.on_load45();events['playback-restart']()
    assert(props['file-local-options/ytdl-format']=='user-default')
    set_entry(2,fs,hd,en);hooks.on_load45()
    assert(commands==8)
    replay(2,fs,sd,en)
    -- A separate load of an identical URL gets a new ID and normal defaults.
    items={{id=99,filename=items[2].filename}};props.playlist=items
    set_entry(1,fs,hd,en);hooks.on_load45()
    assert(commands==8 and props['file-local-options/ytdl-format']=='user-default')
end
