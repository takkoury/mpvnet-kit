"""Offline playback hooks, queue identity, buffering recovery and broadcast status."""
import json
from pathlib import Path
import unittest

from lua_runtime import load_lua51
from support.lua_source import feedback_module, fragment

ROOT = Path(__file__).resolve().parents[1]
PLAYBACK = ROOT / 'config/scripts/playback-feedback.lua'


class NetworkPlayback(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = load_lua51()
        playback = PLAYBACK.read_text(encoding='utf-8')
        module = json.dumps((ROOT / 'config/script-modules/ytdl-result.lua').as_posix())
        cls.ytdl = 'local ytdl_result = dofile(' + module + ')\n'
        cls.source = "local network_resume = {ended=function() end}\n" + fragment(playback,
                              'mp.register_event("end-file", function(event)',
                              'mp.register_event("file-loaded", function()')
        web_source = json.dumps((ROOT / 'config/script-modules/web-source.lua').as_posix())
        cls.origin = 'local web_source = dofile(' + web_source + ')\n' + fragment(playback, 'local origin_path, origin_page, origin_active',
                              'local function media_address()')
        cls.start = "local live_room = {open=function(id) assert(id == nil) end}\n" + fragment(playback, "mp.add_hook('on_before_start_file', 50, function()",
                             'mp.register_event("end-file", function(event)')

    def check_event(self, event, expected):
        prelude = '''
local callback, messages = nil, {}
local origin_active, frame_pending, reload_pending = true, true, true
local reload_marks = {mark=5}
local releases = 0
local function release_hold() releases = releases + 1 end
local mp = {
 get_property_native=function() return false end,
 register_event=function(name,fn) assert(name=='end-file');callback=fn end,
 osd_message=function(text,duration) assert(duration==4);messages[#messages+1]=text end,
}
'''
        body = '\ncallback(%s)\n' % event
        body += 'assert(not origin_active and not frame_pending and releases==1)\n'
        body += ('assert(#messages==0)\n' if expected is None else
                 'assert(#messages==1 and messages[1]==%s)\n' % json.dumps(expected, ensure_ascii=False))
        if "reason='stop'" in event:
            body += 'assert(reload_pending and reload_marks.mark==5)\n'
        else:
            body += 'assert(not reload_pending and reload_marks==nil)\n'
        client = 'local feedback_client = ' + feedback_module() + '.new(mp)\n'
        self.lua.execute(prelude + client + self.source + body, 'playback/end-feedback')

    def test_error_feedback_is_actionable_without_echoing_backend_data(self):
        self.check_event("{reason='error',error='unrecognized file format'}",
                         '不支持此格式\n请换一个文件')
        self.check_event("{reason='error',file_error='unrecognized file format'}",
                         '不支持此格式\n请换一个文件')
        self.check_event("{reason='error',error='https://private.test/video?token=secret'}",
                         '播放失败\n请检查文件或网址')

    def test_normal_stop_eof_and_quit_remain_silent(self):
        for reason in ('stop', 'eof', 'quit', 'redirect'):
            with self.subTest(reason=reason):
                self.check_event("{reason='%s'}" % reason, None)

    def test_web_resume_requires_matching_extracted_bilibili_part(self):
        playback = PLAYBACK.read_text(encoding='utf-8')
        identify = fragment(playback, 'local function network_resume_source()', 'local network_resume = dofile')
        module = json.dumps((ROOT / 'config/script-modules/ytdl-result.lua').as_posix())
        self.lua.execute('local ytdl_result = dofile(' + module + ')\n' + '''
local url, data
local mp = {
    get_property=function(k) assert(k=='path'); return url end,
    get_property_native=function(k) assert(k=='user-data/mpv/ytdl/json-subprocess-result/stdout'); return 'input' end,
}
local utils = {parse_json=function() return data end}
''' + self.origin + identify + '''
local bv = 'BV14J4114768'
local page = 'https://www.bilibili.com/video/'..bv..'/'
failure_source, url, data = 'page', page..'?p=3&t=8', {extractor_key='BiliBili', id=bv..'_p3'}
assert(network_resume_source()==bv..'_p3')
data.id=bv..'_p4'; assert(not network_resume_source())
url=page; data.id=bv; assert(network_resume_source()==bv..'_p1')
data._type='playlist'; data.entries={}; assert(not network_resume_source())
data._type='video'; data.entries=nil; assert(network_resume_source()==bv..'_p1')
data.is_live=true; assert(not network_resume_source()); data.is_live=false
url='https://stream.bilivideo.com/media'; assert(not network_resume_source())
url='https://www.bilibili.com/bangumi/play/ep1'; assert(not network_resume_source())
url='https://b23.tv/sample'; expanded_short_page=page..'?p=3'; data.id=bv..'_p3'
assert(network_resume_source()==bv..'_p3')
data.extractor_key='Generic'; assert(not network_resume_source())
data=nil; assert(not network_resume_source())
''', 'playback/bilibili-resume-source')

    def test_network_resume_respects_play_ranges_and_queue_identity(self):
        module = (ROOT / 'config/script-modules/network-resume.lua').as_posix()
        self.lua.execute('local resume = dofile(' + json.dumps(module) + ')\n' + '''
local url = 'http://example.test/v.mp4'
local props = {path=url, ['playlist/0/id']=1, ['playlist/0/filename']=url,
    ['playlist-pos']=0, ['playlist-playing-pos']=0, ['playlist-count']=1,
    ['time-pos']=12, duration=60, ['eof-reached']=true, seekable=true,
    ['demuxer-via-network']=true, ['rebase-start-time']=true,
    ['end']='none', length='none', frames='all', ['play-direction']='forward'}
local hooks, events, observers = {}, {}, {}
local function get(k, default) if props[k] ~= nil then return props[k] end; return default end
local mp = {get_property=get, get_property_native=get, get_property_number=get, get_property_bool=get,
    set_property=function(k,v) props[k]=v end,
    add_hook=function(k,_,fn) hooks[k]=fn end, register_event=function(k,fn) events[k]=fn end,
    observe_property=function(k,_,fn) observers[k]=fn end}
local hints = 0
local identity, changed = true, 0
local control = resume.new(mp,function() return identity end,function() hints=hints+1 end,
    function() changed=changed+1 end,function() return false end)
for k,v in pairs({['end']='15',length='4',frames='30',['play-direction']='backward',
        seekable=false,['demuxer-via-network']=false,['rebase-start-time']=false,['time-pos']=59.9}) do
    local original=props[k]; props[k]=v
    observers['eof-reached'](nil,true)
    assert(not control.prepare_reload(), k)
    props[k]=original
end
assert(hints==0)
observers['eof-reached'](nil,true)
assert(hints==1 and control.prepare_reload()==0 and control.prepare_reload()==false)
events['start-file']({playlist_entry_id=1})
-- A replacement with the identical URL is still a different queue entry.
props['playlist/0/id']=2
hooks.on_preloaded()
assert(not props['file-local-options/start'])
events['start-file']({playlist_entry_id=2})
props['eof-reached']=false
assert(not control.prepare_reload())
-- A stop or explicit switch must not leave an idle restart point.
hooks.on_unload()
assert(not control.ended({reason='stop',playlist_entry_id=2}))
props['idle-active']=true
assert(not control.prepare_reload())
-- A fresh extraction of the same queue entry must resolve the original part.
props['idle-active']=false; props['eof-reached']=true
identity='BV14J4114768_p3'
assert(control.prepare_reload()==0)
events['start-file']({playlist_entry_id=2})
props['file-local-options/start']='8'
-- Online track selection can reopen the same entry before the recovered stream plays.
control.ended({reason='stop',playlist_entry_id=2})
events['start-file']({playlist_entry_id=2})
hooks.on_preloaded()
assert(tonumber(props['file-local-options/start'])==12, 'lost position while applying online tracks')
-- Its single fallback to the default format must also retain the resume point.
control.ended({reason='error',playlist_entry_id=2})
events['start-file']({playlist_entry_id=2})
props['file-local-options/start']='8'
hooks.on_preloaded()
assert(tonumber(props['file-local-options/start'])==12, 'lost position during format fallback')
-- If the user stops instead, a later open from idle must use its own start.
control.ended({reason='stop',playlist_entry_id=2})
observers['idle-active'](nil,true)
events['start-file']({playlist_entry_id=2})
props['file-local-options/start']='8'
hooks.on_preloaded()
assert(props['file-local-options/start']=='8')
assert(control.prepare_reload()==0)
events['start-file']({playlist_entry_id=2})
identity='BV14J4114768_p4'
hooks.on_preloaded()
assert(props['file-local-options/start']=='8' and changed==1)
''', 'playback/network-resume')

    def test_idle_reload_rejoins_only_the_same_live_entry_without_seeking(self):
        module = json.dumps((ROOT / 'config/script-modules/network-resume.lua').as_posix())
        self.lua.execute('local resume=dofile(' + module + ')\n' + '''
local hooks,events,observers={},{},{}
local url='https://live.bilibili.com/19'
local props={['playlist/0/id']=7,['playlist/0/filename']=url,['playlist-count']=1,playlist={{id=7}}}
local function get(k,d) if props[k]~=nil then return props[k] end;return d end
local mp={get_property=get,get_property_native=get,get_property_number=get,get_property_bool=get,
    set_property=function() error('live reload must not set a start time') end,
    add_hook=function(k,_,f) hooks[k]=f end,register_event=function(k,f) events[k]=f end,
    observe_property=function(k,_,f) observers[k]=f end}
local playing=false
local ctl=resume.new(mp,function() return nil end,function() error('live has no position hint') end,
    function() error('unexpected VOD identity check') end,function() return playing end)
local function active()
    events['start-file']({playlist_entry_id=7})
    props.path=url;props['idle-active']=false;props['playlist-pos']=0;props['playlist-playing-pos']=0
    playing=true
end
local function unload(reason)
    hooks.on_unload();playing=false;props.path=nil
    props['idle-active']=true;props['playlist-pos']=-1;props['playlist-playing-pos']=-1
    return ctl.ended({reason=reason,playlist_entry_id=7})
end
-- Network failure that unloads the media directly.
active();local pos,live=unload('error');assert(not pos and live and ctl.prepare_reload()==0)
-- The replacement open itself fails. Repeated explicit retries keep the target.
events['start-file']({playlist_entry_id=7});pos,live=unload('error')
assert(not pos and live and ctl.prepare_reload()==0 and ctl.prepare_reload()==false)
active();hooks.on_preloaded();events['playback-restart']()
-- Explicit retry from an active or frozen frame, before transport has recovered.
assert(ctl.prepare_reload()==0);unload('stop');events['start-file']({playlist_entry_id=7})
pos,live=unload('error');assert(not pos and live)
-- The same URL in a replacement entry must not be reopened.
props['playlist/0/id']=8;props.playlist={{id=8}};assert(not ctl.prepare_reload())
props['playlist/0/id']=7;props.playlist={{id=7}}
active();unload('stop');assert(not ctl.prepare_reload())
active();unload('eof');props['playlist/0/filename']='other.mp4';assert(not ctl.prepare_reload())
props['playlist/0/filename']=url;props['playlist-count']=2
active();unload('error') -- A surviving idle item need not be the last one.
props.playlist={{id=8},{id=7}};props['playlist/0/id']=8;props['playlist/1/id']=7;props['playlist/1/filename']=url
assert(ctl.prepare_reload()==1)
events['start-file']({playlist_entry_id=8});assert(not ctl.prepare_reload())
''','playback/idle-live-reload')

    def test_live_room_status_belongs_to_the_current_playback(self):
        modules = ROOT / 'config/script-modules'
        module = json.dumps((modules / 'live-playback.lua').as_posix())
        provider = json.dumps((modules / 'bilibili-live.lua').as_posix())
        self.lua.execute(self.ytdl + 'local bili_path = ' + provider + '\nlocal live = dofile(' + module + ')\n' + r'''
local events, hooks, pending, props, notices = {}, {}, {}, {}, {}
os.getenv=function(k) if k=='SystemRoot' then return 'C:/Windows' end end
local mp = {
    command_native=function() return bili_path end,
    register_event=function(k, f) events[k]=f end,
    add_hook=function(k, _, f) hooks[k]=f end,
    observe_property=function(k, _, f) events[k]=f end,
    get_property=function(k, fallback) return props[k] or fallback end,
    get_property_bool=function(k) return props[k] end,
    get_property_number=function(k, fallback) return props[k] or fallback end,
    get_property_native=function(k) return props[k] end,
    command_native_async=function(cmd, done)
        assert(not cmd.playback_only and cmd.args[#cmd.args]:match('id=19$'))
        pending[#pending+1]={done=done}
        return #pending
    end,
    abort_async_command=function(id) pending[id].cancelled=true end,
}
local utils={join_path=function(a,b) return a..'/'..b end, parse_json=function(v) return v end}
local room=live.new(mp, utils, {show=function(text) notices[#notices+1]=text end}, ytdl_result)
local key='user-data/mpv/ytdl/json-subprocess-result/'
local function open()
    events['start-file']()
    room.open('19')
    props={['end']='none',length='none',frames='all'}
end
local function error_with(status, text)
    open(); props[key..'status']=status; props[key..'stderr']=text
    hooks.on_unload(); room.finish('error')
    return notices[#notices]
end
local offline='ERROR: [BiliLive] 19: Streamer is not live'
assert(error_with(1,'WARNING: transient\r\n'..offline..'\r\n')=='直播间当前未开播')
assert(error_with(1,offline:gsub('19','18')):match('^暂时无法打开直播间'))
assert(error_with(0,offline):match('^暂时无法打开直播间'))
assert(error_with(1,'timeout'):match('^暂时无法打开直播间') and #pending==0)
local function result(i,id,live)
    pending[i].done(true,{status=0,stdout={code=0,data={room_id=id,live_status=live}}})
end
open(); room.loaded(); events['eof-reached'](nil,true); room.finish('eof')
assert(#pending==1)
result(1,19,0); assert(notices[#notices]=='直播已结束')
open(); room.loaded(); room.finish('error')
result(2,19,1); assert(notices[#notices]:match('^直播连接中断'))
open(); room.loaded(); room.finish('eof')
result(3,20,0); assert(notices[#notices]:match('^直播连接中断'))
open(); room.loaded(); events['eof-reached'](nil,true)
events['playback-restart'](); assert(pending[4].cancelled)
events['eof-reached'](nil,true)
local before=#notices
result(4,19,0); assert(#notices==before)
room.finish('stop'); assert(pending[5].cancelled)
open(); result(5,19,0); assert(#notices==before)
props['end']='15'; room.loaded(); events['eof-reached'](nil,true);room.finish('eof')
assert(#pending==5 and #notices==before)
''', 'playback/live-room')

    def test_youtube_end_query_is_bound_to_the_playing_broadcast(self):
        modules = ROOT / 'config/script-modules'
        fixture = self.ytdl + '\n'.join(
            'local ' + name + ' = ' + json.dumps((modules / file).as_posix())
            for name, file in [('live_path', 'live-playback.lua'), ('bili_path', 'bilibili-live.lua'),
                               ('catalog_path', 'youtube-catalog.lua')])
        self.lua.execute(fixture + r'''
local events, requests, timers = {}, {}, {}
local visible, ready, fallback = '', true, nil
local id = 'rFZHOHl-L8A'
local meta, last, proxy = {}, {}, 'http://127.0.0.1:1234'
local mp = {
    command_native=function() return bili_path end,
    register_event=function(k,f) events[k]=f end, add_hook=function() end,
    observe_property=function(k,_,f) events[k]=f end,
    get_property=function(k) return k=='frames' and 'all' or 'none' end,
    get_property_bool=function() return false end,
    set_property_native=function(k, v) assert(k=='user-data/mpvnet/feedback/live'); visible=v end,
    get_property_native=function(k)
        if k=='user-data/mpv/ytdl/json-subprocess-result/stdout' then return 'fixture' end
        if k=='user-data/mpv/ytdl/path' then return 'fixture/yt-dlp.exe' end
        if k=='file-local-options/ytdl-raw-options' then return {proxy=proxy} end
    end,
    command_native_async=function(cmd,done)
        last={cmd=cmd,done=done}; requests[#requests+1]=last; return #requests
    end,
    abort_async_command=function(handle) requests[handle].cancelled=true end,
    add_timeout=function(n,fn)
        assert(n==12);local timer={kill=function(self) self.killed=true end,fire=fn}
        timers[#timers+1]=timer;return timer
    end,
}
local catalog=dofile(catalog_path)
local room=dofile(live_path).new(mp,{parse_json=function() return meta end},
    {is_ready=function() return ready end,show=function(text) assert(not ready);fallback=text end},ytdl_result)
local function open(status,video)
    events['start-file'](); room.open(nil)
    meta={extractor_key='Youtube',id=video or id,live_status=status}
    return room.loaded(id,catalog)
end
local function stop_stream()
    events['eof-reached'](nil,true);room.finish('eof')
end
for _,status in ipairs({'was_live','not_live','post_live','is_upcoming'}) do
    assert(not open(status)); stop_stream()
end
assert(not open('is_live','another_id_'));stop_stream()
assert(#requests==0 and visible=='')
assert(open('is_live')); room.finish('stop');assert(#requests==0)
assert(open('is_live'))
proxy='http://127.0.0.1:4321'
stop_stream();assert(#requests==1 and not last.cmd.playback_only and visible=='正在确认直播状态…')
local args=last.cmd.args
assert(args[1]=='fixture/yt-dlp.exe' and args[#args]=='https://www.youtube.com/watch?v='..id)
assert(args[#args-2]=='http://127.0.0.1:1234')
last.done(true,{status=0,stdout=id..' is_live\r\n'})
assert(visible=='直播连接中断\n可重新打开直播链接' and timers[1].killed)
events['playback-restart'](); assert(visible=='')
for _,status in ipairs({'post_live','was_live'}) do
    open('is_live');room.finish('error');last.done(true,{status=0,stdout=id..' '..status..'\n'})
    assert(visible=='直播已结束')
    room.finish('stop'); assert(visible=='')
end
open('is_live');stop_stream();last.done(true,{status=0,stdout='other_video was_live\n'})
assert(visible:match('^暂时无法确认直播状态'))
open('is_live');assert(visible=='');stop_stream();local old=last
events['playback-restart']();assert(old.cancelled and visible=='')
old.done(true,{status=0,stdout=id..' was_live\n'});assert(visible=='')
stop_stream();local timed_out=last;timers[#timers].fire()
assert(timed_out.cancelled and visible:match('^暂时无法确认直播状态'))
timed_out.done(true,{status=0,stdout=id..' was_live\n'});assert(visible:match('^暂时无法确认直播状态'))
open('is_live');stop_stream();local ended=last;events['start-file']()
ended.done(true,{status=0,stdout=id..' was_live\n'});assert(ended.cancelled and visible=='')
open('is_live');stop_stream();last.done(true,{status=0,stdout=id..' was_live\n'})
assert(visible=='直播已结束');events.shutdown();assert(visible=='')
ready=false;open('is_live');stop_stream();last.done(true,{status=0,stdout=id..' was_live\n'})
assert(visible=='直播已结束' and fallback==visible)
''', 'playback/youtube-end')

    def check_share_link(self, cases):
        catalog = json.dumps((ROOT / 'config/script-modules/youtube-catalog.lua').as_posix())
        fixture = '''
local props, hooks = {}, {}
local pending, deferred, continued
local mp = {
    get_property=function(name, default) return props[name] or default end,
    get_property_number=function(name, default) return props[name] or default end,
    get_property_native=function(name, default) if props[name] == nil then return default end; return props[name] end,
    set_property=function(name, value) props[name]=value; return true end,
    set_property_native=function(name, value) props[name]=value; return true end,
    command_native=function(command) assert(command[1]=='expand-path'); return command[2] end,
    register_event=function() end,
    add_hook=function(name, priority, callback) hooks[priority]=callback end,
    command_native_async=function(command, callback) pending={command=command, done=callback}; return 7 end,
    add_timeout=function(_, fn) pending.timeout=fn; return {kill=function() pending.stopped=true end} end,
    abort_async_command=function(handle) assert(handle==7); pending.aborted=true end,
}
local paths = {powershell=function() return 'powershell.exe' end}
local os = {getenv=function() return 'Windows' end}
local utils = {join_path=function(a,b) return a..'/'..b end}
'''
        setup = '''
local start = 'file-local-options/start'
local stream = 'stream-open-filename'
local short = 'https://b23.tv/Short12'
local page = 'https://www.bilibili.com/video/BV1Qgyfz1ERa/'
local episode = 'https://www.bilibili.com/bangumi/play/ep2687638'
local season = 'https://www.bilibili.com/bangumi/play/ss129142'

local function open(url, enabled, options)
    props = options or {} -- mpv restores per-file options when a file ends.
    props[stream], props['options/ytdl'] = url, enabled
    pending, deferred, continued = nil, 0, 0
    hooks[5]({
        defer=function() deferred=deferred+1 end,
        cont=function() continued=continued+1 end,
    })
    assert(deferred == (pending and 1 or 0) and continued == 0)
end

local function finish(redirect)
    assert(pending.command.playback_only)
    assert(pending.command.args[#pending.command.args] == short)
    pending.done(redirect ~= nil, redirect and {status=0, stdout=redirect})
    assert(continued == 1)
end
'''
        self.lua.execute('local youtube_catalog = dofile(' + catalog + ')\n' + fixture
                         + self.origin + self.start + setup + cases, 'playback/share-link')

    def test_catalog_hook_preserves_explicit_playlists_and_expands_standalone_pages(self):
        self.check_share_link('''
local key = 'user-data/mpvnet/web-queue-source'
local function classify(url, list_path)
    open(url, true, {path=url, ['playlist-count']=1, ['playlist/0/id']=15,
        ['playlist/0/playlist-path']=list_path, ['file-local-options/ytdl-raw-options']={proxy=''}})
    hooks[7]()
    return props[key]
end
local video = 'YE7VzlLtp-4'
local watch = 'https://www.youtube.com/watch?v='..video..'&list=PLtest&t=42'
local entry = classify(watch)
assert(entry.provider=='youtube' and entry.content_id==video and entry.playlist_id=='PLtest' and entry.id==15)
assert(props[stream]=='https://www.youtube.com/watch?v='..video..'&t=42')
assert(not classify(watch,'explicit-list') and props[stream]=='https://www.youtube.com/watch?v='..video..'&t=42')
entry=classify(page..'?p=3&t=90')
assert(entry.provider=='bilibili' and entry.id==15 and entry.part==3 and props[start]=='90')
assert(not classify(episode,'explicit-list') and not classify(season))
assert(not classify('https://www.youtube.com/live/'..video))
''')

    def test_youtube_uses_the_current_items_proxy_and_preserves_other_extractor_options(self):
        self.check_share_link('''
local http, raw = 'file-local-options/http-proxy', 'file-local-options/ytdl-raw-options'
local url = 'https://youtu.be/YE7VzlLtp-4?t=42'
local full = 'https://www.youtube.com/watch?list=RDabc&v=YE7VzlLtp-4&t=42s'
local live = 'https://www.youtube.com/live/ss12_-AbCdE?si=share'
for _,link in ipairs({url,full,live,'https://m.youtube.com/live/ss12_-AbCdE/#share'}) do
    open(link, true, {[raw]={['sub-langs']='en'}})
    assert(pending.command.playback_only and pending.command.args[#pending.command.args]==link)
    pending.done(true, {status=0, stdout='http://127.0.0.1:5180'})
    assert(pending.stopped and continued==1 and props[http]=='http://127.0.0.1:5180')
    assert(props[raw].proxy==props[http] and props[raw]['sub-langs']=='en' and not props[start])
end
for _,options in ipairs({{[http]='http://custom:8080'}, {[raw]={proxy=''}},
    {['option-info/http-proxy/set-locally']=true}}) do
    open(full, true, options); assert(not pending)
end
for _,other in ipairs({page,'local.mp4','http://192.168.1.2/clip.mp4',
    'https://youtu.be.example/YE7VzlLtp-4','https://www.youtube.com/playlist?list=abc',
    'https://youtube.com/watch?list=abc#?v=YE7VzlLtp-4','https://youtu.be/no-id',
    'https://youtube.com/live/bad','https://youtube.com/live/ss12_-AbCdE/more',
    'https://youtube.com.example/live/ss12_-AbCdE','https://www.youtube.com/@channel/live'}) do
    open(other,true); assert(not pending and not props[http], other)
end
open(full,false); assert(not pending)
''')

    def test_youtube_direct_failed_timed_out_and_stale_proxy_queries_leave_options_alone(self):
        self.check_share_link('''
local url='https://youtube.com/watch?v=YE7VzlLtp-4'
local http, raw='file-local-options/http-proxy', 'file-local-options/ytdl-raw-options'
for _,output in ipairs({'','https://example.test:443','http://user@proxy:80'}) do
    open(url,true); pending.done(true,{status=0,stdout=output})
    assert(continued==1 and not props[http] and not props[raw])
end
open(url,true); pending.timeout(); assert(pending.aborted)
pending.done(false,nil); assert(continued==1 and not props[http])
open(url,true); props[stream]='http://lan/video.mp4'
pending.done(true,{status=0,stdout='http://localhost:8080'})
assert(continued==1 and not props[http] and not props[raw])
''')

    def test_share_time_applies_only_to_an_eligible_page_without_an_explicit_start(self):
        self.check_share_link('''
open(episode..'?t=90', true)
assert(props[start]=='90' and not pending)
open(page..'?p=3&t=4.25', true)
assert(props[start]=='4.25' and not pending)
open(episode..'?t=0', true)
assert(props[start]=='0')
for _,url in ipairs({season..'?t=90', episode, episode..'?t=-3', episode..'#?t=90',
                     'https://other.test/video?t=3'}) do
    open(url, true)
    assert(not props[start] and not pending, url)
end
open(episode..'?t=90', false)
assert(not props[start] and not pending)
open(episode..'?t=90', true, {[start]='12'})
assert(props[start]=='12')
for _,flag in ipairs({'set-locally','set-from-commandline'}) do
    open(episode..'?t=90', true, {['option-info/start/'..flag]=true})
    assert(not props[start], flag)
end
''')

    def test_short_link_resolves_part_and_time_independently(self):
        self.check_share_link('''
local redirect = 'https://www.bilibili.com/zh-Hans/video/BV1Qgyfz1ERa?p=1&t=11&share_tag=test'
open(short..'?p=3&t=42', true)
finish(redirect)
assert(props[stream]==page..'?p=3&t=42' and props[start]=='42')
assert(expanded_short_page==page..'?p=3')

open(short..'?p=3', true)
finish(redirect)
assert(props[stream]==page..'?p=3&t=11' and props[start]=='11')
open(short..'?t=42', true)
finish(redirect)
assert(props[stream]==page..'?p=1&t=42' and props[start]=='42')

open(short..'?t=90', true)
finish(episode..'?t=11')
assert(props[stream]==episode..'?t=90' and props[start]=='90' and expanded_short_page==episode)
open(short, true)
finish(episode..'?t=6.5')
assert(props[start]=='6.5')
open(short..'?t=90', true)
finish(season..'?t=17')
assert(props[stream]==season and not props[start])
''')

    def test_unavailable_or_stale_redirect_keeps_the_current_input_and_start(self):
        self.check_share_link('''
local url = short..'?t=90'
open(url, false)
assert(not pending and not props[start])
open(url, true)
finish('https://other.test/video/BV1Qgyfz1ERa/')
assert(props[stream]==url and not props[start])
open(url, true)
finish(nil)
assert(props[stream]==url and not props[start])

open(url, true)
props[stream] = 'next.mp4'
finish(episode..'?t=11')
assert(props[stream]=='next.mp4' and not props[start])
''')

    def test_cdn_cid_belongs_to_its_input_not_a_later_queue_entry(self):
        prelude = '''
local props, hooks, events = {}, {}, {}
local mp = {
    register_event=function(k,f) events[k]=f end,
    add_hook=function(k,priority,f) hooks[k]=f end,
    get_opt=function(k) return props[k] end,
    get_property=function(k) return props[k] end,
    get_property_native=function(k,default) return props[k] or default end,
    get_property_bool=function(k,default) return props[k] or default end,
    commandv=function() end,
}
local seek_timer={kill=function() end}
local function release_hold() end
'''
        cases = '''
local season='https://www.bilibili.com/bangumi/play/ss129142'
local cdn='https://v.bilivideo.com/'
local function start(i,file,referer,local_cid)
    props={cid='111'}
    hooks.on_before_start_file()
    events['start-file']({playlist_entry_id=i})
    props.path=cdn..file
    props['file-local-options/referrer']=referer
    if local_cid then
        props.cid=local_cid
        props['option-info/script-opts/set-locally']=true
        props['option-info/referrer/set-locally']=true
    end
    hooks.on_load();capture_media_origin(true)
end
local function stop(i) events['end-file']({reason='stop',playlist_entry_id=i}) end
start(1,'a',season);assert(origin_active and origin_cid=='111');stop(1)
start(2,'b',season);assert(not origin_active);stop(2)
start(3,'c',season,'222');assert(origin_active and origin_cid=='222');stop(3)
start(4,'d','https://www.bilibili.com/bangumi/play/ss55')
assert(origin_active and origin_cid==nil)
'''
        self.lua.execute(prelude + self.origin + self.start + self.source + cases, 'playback/cid-association')

    def test_network_failure_uses_only_the_failed_entry_and_its_source(self):
        prelude = '''
local events, hooks, props, messages = {}, {}, {}, {}
local mp = {
    register_event=function(name, fn) events[name]=fn end,
    add_hook=function(name, priority, fn) hooks[name]=fn end,
    get_opt=function() return nil end,
    get_property=function(key) return props[key] end,
    get_property_number=function(key, fallback) return props[key] or fallback end,
    get_property_native=function(key, fallback) return props[key] or fallback end,
    commandv=function() end,
}
local seek_timer = {kill=function() end}
local function release_hold() end
local feedback_client = {show=function(text, kind)
    assert(kind=='error'); messages[#messages+1]=text
end}
'''
        cases = r'''
local function load(id, path, referrer, headers)
    props = {path=path, ['file-local-options/referrer']=referrer,
             ['file-local-options/http-header-fields']=headers}
    events['start-file']({playlist_entry_id=id})
    hooks.on_load()
end
local function finish(id, expected)
    local count = #messages
    props = {} -- Core properties may already be cleared when end-file is delivered.
    events['end-file']({reason='error', playlist_entry_id=id, file_error='loading failed'})
    assert(#messages==count+1 and messages[#messages]==expected, messages[#messages])
end
local page = 'https://www.bilibili.com/video/BV1234567890/'
local cdn = 'https://v.bilivideo.com/'
local webpage = '播放失败\n请回到原网页，再用外部播放器播放'
local direct = '无法播放此网址\n请重新获取媒体直链后打开'
local generic = '播放失败\n请检查文件或网址'
load(1, cdn..'a', nil, {'Referer: '..page}); finish(1, webpage)
load(2, cdn..'b', page); finish(2, direct) -- Stale per-process Referer.
load(3, page); finish(3, webpage)
load(4, 'https://media.test/stream?private=1'); finish(4, direct)
load(5, 'local.mp4'); finish(5, generic)
load(6, cdn..'c', 'https://www.bilibili.com.invalid/video/BV1234567890/')
finish(6, direct)
load(7, page); finish(8, generic)
finish(7, generic) -- No saved hint survives end-file.
load(9, 'https://youtu.be/YE7VzlLtp-4?t=42')
finish(9, '无法播放此 YouTube 视频\n请检查 yt-dlp 和网络代理')
load(16, 'https://www.youtube.com/live/ss12_-AbCdE?si=share')
finish(16, '无法播放此 YouTube 视频\n请检查 yt-dlp 和网络代理')
local room
live_room.open=function(id) room=id end
live_room.finish=function(reason) assert(room=='19' and reason=='error');messages[#messages+1]='live error' end
load(10, 'https://live.bilibili.com/blanc/19/?source=share'); finish(10, 'live error')
load(11, 'https://live.bilibili.com/19#player'); finish(11, 'live error')
load(12, 'https://live.bilibili.com.invalid/19'); finish(12, direct)
load(13, 'https://live.bilibili.com/19/another'); finish(13, direct)
load(14, 'https://live.bilibili.com/19'); finish(15, generic)
local id = 'ss12_-AbCdE'
local url = 'https://www.youtube.com/live/'..id
local key = 'user-data/mpv/ytdl/json-subprocess-result/'
local function youtube_error(status, diagnostic, ended_id, expected)
    load(20, url)
    props[key..'status'],props[key..'stderr']=status,diagnostic
    hooks.on_unload()
    finish(ended_id, expected)
end
local prefix='ERROR: [youtube] '..id..': This live event will begin in '
local title='这场 YouTube 直播尚未开始\n'
local unavailable='无法播放此 YouTube 视频\n请检查 yt-dlp 和网络代理'
youtube_error(1,'WARNING: retry\r\n'..prefix..'3 days.\r\n',20,title..'约 3 天后开播')
youtube_error(1,prefix..'1 hour.',20,title..'约 1 小时后开播')
youtube_error(1,prefix..'a few moments.',20,title..'即将开播，请稍后再打开')
youtube_error(1,prefix..'unexpected text.',20,title..'请按原网页的预告时间再打开')
youtube_error(1,prefix..'7 minutes.',21,generic)
youtube_error(0,prefix..'4 hours.',20,unavailable)
youtube_error(1,'ERROR: [youtube] OtherID_123: This live event will begin in 1 day.',20,unavailable)
youtube_error(1,'ERROR: [youtube] '..id..': Private video',20,unavailable)
youtube_error(1,prefix..'3 days.',20,title..'约 3 天后开播')
load(21,url); finish(21,unavailable)
local replay='ERROR: [youtube] '..id..': This live stream recording is not available.'
youtube_error(1,replay,20,'这场 YouTube 直播的回放暂不可用')
youtube_error(0,replay,20,unavailable)
youtube_error(1,'ERROR: [youtube] OtherID_123: This live stream recording is not available.',20,unavailable)
youtube_error(1,replay,21,generic)
youtube_error(1,'ERROR: [youtube] '..id..': Video unavailable',20,unavailable)
'''
        self.lua.execute(self.ytdl + prelude + self.origin + self.start + self.source + cases, 'playback/network-failure')
