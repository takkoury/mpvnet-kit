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
        add_hook=function(k,p,fn) hooks[k]=fn end,register_event=function(k,fn) events[k]=fn end,
        osd_message=function() end, commandv=function(_,command,index)
            assert(command=='playlist-play-index' and index=='current')
            commands=commands+1;return true
        end}
    local state=M.new(mp,{parse_json=function()return data end})
    assert(state.switch('video',state.catalog().video[2].row_id))
    assert(commands==1)
    events['end-file']({reason='stop',playlist_entry_id=8})
    hooks.on_after_end_file()
    hooks.on_load()
    assert(props['file-local-options/ytdl-format']:find('[height=720]',1,true))
    props['file-local-options/start']='42'
    hooks.on_preloaded()
    assert(tonumber(props['file-local-options/start'])==130 and props.pause)
    events['end-file']({reason='error',playlist_entry_id=8})
    if user_moved then props['playlist/2/id']=20 end
    hooks.on_after_end_file()
    if user_moved then assert(commands==1);return end
    assert(commands==2)
    hooks.on_load()
    assert(props['file-local-options/ytdl-format']:find('[height=1080]',1,true))
    events['end-file']({reason='error',playlist_entry_id=8})
    hooks.on_after_end_file()
    assert(commands==2)
end
