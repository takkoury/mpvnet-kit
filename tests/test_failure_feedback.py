"""Offline failure feedback through real Lua callbacks and PowerShell reason mapping."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

from lua_runtime import load_lua51

from support.lua_source import feedback_module, fragment

ROOT = Path(__file__).resolve().parents[1]
CAPTURE = ROOT / 'config/scripts/capture-controls.lua'
HELPER = ROOT / 'config/helpers/capture-media.ps1'
PLAYBACK = ROOT / 'config/scripts/playback-feedback.lua'
DANMAKU = ROOT / 'config/scripts/bilibiliAssert/main.lua'
THUMBFAST = ROOT / 'config/scripts/thumbfast.lua'


class PlaybackEndFeedback(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = load_lua51()
        playback = PLAYBACK.read_text(encoding='utf-8')
        cls.source = "local network_resume = {ended=function() end}\n" + fragment(playback,
                              'mp.register_event("end-file", function(event)',
                              'mp.register_event("file-loaded", function()')
        cls.origin = fragment(playback, 'local origin_path, origin_page, origin_active',
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
    function() changed=changed+1 end)
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
identity='BV14J4114768_p4'
hooks.on_preloaded()
assert(props['file-local-options/start']=='8' and changed==1)
''', 'playback/network-resume')

    def test_live_room_status_belongs_to_the_current_playback(self):
        module = json.dumps((ROOT / 'config/script-modules/bilibili-live.lua').as_posix())
        self.lua.execute('local live = dofile(' + module + ')\n' + r'''
local events, hooks, pending, props, notices = {}, {}, {}, {}, {}
os.getenv=function(k) if k=='SystemRoot' then return 'C:/Windows' end end
local mp = {
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
local room=live.new(mp, utils, {show=function(text) notices[#notices+1]=text end})
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
open(); events['file-loaded'](); events['eof-reached'](nil,true); room.finish('eof')
assert(#pending==1)
result(1,19,0); assert(notices[#notices]=='直播已结束')
open(); events['file-loaded'](); room.finish('error')
result(2,19,1); assert(notices[#notices]:match('^直播连接中断'))
open(); events['file-loaded'](); room.finish('eof')
result(3,20,0); assert(notices[#notices]:match('^直播连接中断'))
open(); events['file-loaded'](); events['eof-reached'](nil,true)
events['playback-restart'](); assert(pending[4].cancelled)
events['eof-reached'](nil,true)
local before=#notices
result(4,19,0); assert(#notices==before)
room.finish('stop'); assert(pending[5].cancelled)
open(); result(5,19,0); assert(#notices==before)
props['end']='15'; events['file-loaded'](); events['eof-reached'](nil,true);room.finish('eof')
assert(#pending==5 and #notices==before)
''', 'playback/live-room')

    def check_share_link(self, cases):
        web_resume = (ROOT / 'config/script-modules/web-resume.lua').read_text(encoding='utf-8')
        fixture = '''
local props, hooks = {}, {}
local pending, deferred, continued
local mp = {
    get_property=function(name, default) return props[name] or default end,
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
        module = 'local web_resume = (function()\n' + web_resume + '\nend)()\n'
        self.lua.execute(fixture + module + self.origin + self.start + setup + cases, 'playback/share-link')

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
'''
        self.lua.execute(prelude + self.origin + self.start + self.source + cases, 'playback/network-failure')


class VideoRestore(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = load_lua51()
        cls.source = fragment(PLAYBACK.read_text(encoding='utf-8'),
                              'mp.add_key_binding(nil, "audio-only", function()',
                              'mp.register_script_message("seek",')

    def test_restore_tracks_follow_explicit_selection_and_current_visible_video(self):
        prelude = '''
local saved_video, saved_video_revision, callback
local props={vid=1,revision=0,tracks={{type='video',id=1},{type='video',id=2}}}
local commands={}
local mp={
 add_key_binding=function(_,name,fn) assert(name=='audio-only');callback=fn end,
 get_property_native=function(name,default)
  if name=='vid' then return props.vid end
  if name=='user-data/mpvnet/video-selection-revision' then return props.revision end
  if name=='current-tracks/video' then return props.vid~='no' and props.vid~=false and {id=props.vid} or nil end
  if name=='track-list' then return props.tracks end
  return default
 end,
 commandv=function(prefix,verb,key,value)
  assert(prefix=='no-osd' and verb=='set' and key=='vid')
  commands[#commands+1]=value;props.vid=value
 end,
}
'''
        cases = '''
callback();assert(props.vid=='no');callback();assert(props.vid==1)
callback();assert(props.vid=='no')
props.vid=2;props.revision=1 -- explicit picker selection invalidates old restore
callback();assert(props.vid=='no');callback();assert(props.vid==2)
callback();assert(props.vid=='no')
props.revision=2 -- explicit picker closes video, not audio-only's saved request
callback();assert(props.vid=='auto')
props.vid=1;callback();props.vid=2 -- external native selection also takes priority
callback();assert(props.vid=='no');callback();assert(props.vid==2)
props.vid='no';saved_video=nil;props.tracks={};local count=#commands
callback();assert(#commands==count)
'''
        self.lua.execute(prelude + self.source + cases, 'playback/video-restore')


class FailureFeedback(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = load_lua51()
        capture = CAPTURE.read_text(encoding='utf-8')
        playback = PLAYBACK.read_text(encoding='utf-8')
        cls.capture_source = (
            fragment(capture, 'local function feedback(', 'local function clock(')
            + fragment(capture, 'local function run(', '-- Directory opening owns')
            + fragment(capture, 'local function open_folder()', 'local function screenshot()')
        )
        cls.clipboard_source = fragment(playback, 'mp.add_key_binding(nil, "clipboard-url"', 'mp.add_key_binding(nil, "save-mark"')
        cls.prelude = r'''
local busy, shutting_down = false, false
local pending_png, pending_job, pending_payload
local messages, warnings, removed, bindings, commands = {}, {}, {}, {}, {}
local reply, callback, callback_ok = nil, nil, false
local helper, powershell = 'helper', 'powershell'
local payload_available = true
local clipboard
local statuses={}
local mp = {
    get_property_native=function() return nil end,
    set_property_native = function(k,v) statuses[k]=v;return true end,
    osd_message = function(text) messages[#messages+1] = text end,
    msg = {warn = function(text) warnings[#warnings+1] = text end},
    get_property_number = function() return 123 end,
    get_property = function() return clipboard end,
    add_key_binding = function(_, name, fn) bindings[name] = fn end,
    commandv = function(...) commands[#commands+1] = {...} end,
    command_native_async = function(_, fn) callback = fn end,
}
local utils = {parse_json = function() return reply end}
local os = {remove = function(path) removed[#removed+1] = path end}
local function publish() end
local function token() return '123-1-1' end
local function write_payload() return payload_available and 'owned-payload.json' or nil end
local function eq(a,b) assert(a==b, tostring(a)..' ~= '..tostring(b)) end
''' + 'local feedback_client = ' + feedback_module() + '.new(mp)\n'

    def run_capture(self, body):
        self.lua.execute(self.prelude + self.capture_source + body, 'capture/feedback')

    def test_capture_reason_messages_and_cleanup(self):
        cases = {
            'ffmpeg-missing': '未找到 FFmpeg', 'access-denied': '权限不足',
            'clipboard': '复制失败', 'save': '无法保存文件',
            'encode-mp4': 'MP4 生成失败', 'encode-webp': 'WebP 生成失败',
            'encode-gif': 'GIF 生成失败', 'cancelled': '操作已取消',
            'file-missing': '找不到文件', 'invalid-range': '片段范围无效',
            'invalid-path': '输出路径无效', 'directory': '文件夹不可用',
            'temporary-file': '请检查临时文件夹',
            'no-video': '请先打开视频',
            'stream-unavailable': '此视频无法导出片段\n请换一个视频',
        }
        for reason, message in cases.items():
            with self.subTest(reason=reason):
                self.run_capture('''
run({action='clip'}, 'SUCCESS', '导出失败', function() error('failure called done') end)
eq(busy, true)
reply = {ok=false, reason=%s, phase='mp4'}
callback(false, {status=1,stdout='mock'})
eq(messages[#messages], %s)
eq(busy, false); eq(pending_payload,nil); eq(pending_job,nil)
eq(removed[1], 'owned-payload.json'); eq(#removed,1)
''' % (json.dumps(reason), json.dumps(message if reason in ('clipboard','cancelled','encode-mp4','encode-webp','encode-gif','stream-unavailable') else ('无法导出' if reason=='ffmpeg-missing' else '导出失败')+('：' if reason=='access-denied' else '\n')+message, ensure_ascii=False)))

    def test_unknown_or_malformed_failure_does_not_echo_details(self):
        for data in ('{ok=false,reason="https://private.test/?token=secret",phase="private-path"}', 'true', 'nil'):
            with self.subTest(reply=data):
                self.run_capture('''
run({action='clip'}, 'SUCCESS', '导出失败')
reply = %s
callback(false, {status=1,stdout='private'})
eq(messages[#messages], '导出失败'); eq(warnings[1], 'Capture failed: worker')
eq(busy,false); eq(pending_payload,nil)
''' % data)

    def test_success_and_old_helper_fallback(self):
        self.run_capture('''
local done=false
run({action='clip'}, 'CLIP SAVED', '导出失败', function() done=true end)
reply={ok=true}; callback(true, {status=0,stdout='mock'})
eq(done,true); eq(messages[#messages],'CLIP SAVED'); eq(#warnings,0); eq(busy,false)
run({action='clip'}, 'CLIP SAVED', '导出失败')
reply={ok=false,phase='ffmpeg'}; callback(false,{status=1,stdout='mock'})
eq(messages[#messages],'无法导出\\n未找到 FFmpeg')
''')

    def test_temp_failure_and_folder_state_isolation(self):
        self.run_capture('''
payload_available=false; pending_png='owned.png'
run({action='screenshot'}, 'SUCCESS', '无法截图')
eq(messages[#messages],'无法截图\\n请检查临时文件夹'); eq(busy,false)
eq(removed[1],'owned.png'); eq(callback,nil)
payload_available=true; busy=true; pending_job='existing-job'
open_folder(); reply={ok=false,reason='directory'}; callback(false,{status=1,stdout='mock'})
eq(messages[#messages],'无法打开输出文件夹\\n文件夹不可用')
eq(busy,true); eq(pending_job,'existing-job')
''')

    def test_explicit_clipboard_url_delegates_to_playlist_input(self):
        self.lua.execute(self.prelude + self.clipboard_source + '''
bindings['clipboard-url']()
eq(#commands,1);eq(commands[1][1],'script-message-to')
eq(commands[1][2],'playlist_controls');eq(commands[1][3],'open-clipboard-url')
''')

    def test_complete_lua_syntax(self):
        self.lua.check_syntax(CAPTURE)
        self.lua.check_syntax(PLAYBACK)


class DanmakuFailureFeedback(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = load_lua51()
        cls.source = DANMAKU.read_text(encoding='utf-8')
        cls.prelude = 'local feedback_module = ' + feedback_module() + r'''
local messages, logs, calls, removed, durations, commands = {}, {}, {}, {}, {}, {}
local properties, events = {}, {}
local tracks, file_meta = {}, nil
local callback = nil
local media_path = 'https://private.test/video?token=secret'
local mp = {
    get_property=function(name, default)
        if name=='path' then return media_path end
        if name=='pid' then return '123' end
        if properties[name]~=nil then return properties[name] end
        return default
    end,
    get_property_number=function(_, default) return default end,
    get_property_native=function(name) if name=='track-list' then return tracks end;return properties[name] end,
    set_property=function(name,value) properties[name]=value;return true end,
    set_property_native=function(name,value) properties[name]=value;return true end,
    commandv=function(...) local args={...};commands[#commands+1]=args;if args[1]=='sub-add' then tracks[#tracks+1]={type='sub',id=7,title='Bilibili Danmaku'} end;return true end,
    get_opt=function() return nil end,
    get_time=function() return 1 end,
    get_script_directory=function() return 'private-script-path' end,
    command_native=function(args) assert(args[1]=='expand-path'); return args[2] end,
    command_native_async=function(command, fn) calls[#calls+1]=command;callback=fn;return {} end,
    abort_async_command=function() end,
    osd_message=function(text,duration) messages[#messages+1]=text;durations[#durations+1]=duration end,
    msg={info=function(text) logs[#logs+1]=text end},
    register_event=function(name,fn) events[name]=fn end, observe_property=function() end,
    register_script_message=function() end, add_key_binding=function() end,
}
package.loaded['mp']=mp
package.loaded['mp.utils']={join_path=function(a,b) return a..'/'..b end,
    file_info=function() return file_meta end}
package.loaded['mp.options']={read_options=function() end}
local dofile=function(path)
    if path == '~~/script-modules/feedback.lua' then return feedback_module end
    assert(path == '~~/script-modules/mpvnet-paths.lua', 'unexpected dofile '..path)
    return {options={python_path=''}}
end
local os={time=function() return 1 end,getenv=function() return 'owned-temp' end,
    remove=function(path) removed[#removed+1]=path end}
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
'''

    def run_case(self, body):
        self.lua.execute(self.prelude + self.source + body, 'danmaku/failure-feedback')

    def test_only_explicit_spawn_failure_points_to_python_path(self):
        for success, result, expected in (
            ('true', "{status=-3,error_string='init'}", '弹幕加载失败\n请检查 Python 路径'),
            ('true', "{status=1,error_string='',stdout='HTTP 403 private URL'}", '弹幕加载失败'),
            ('true', "{status=2,error_string='',stdout='conversion failed'}", '弹幕加载失败'),
            ('true', "{status=-2,error_string='killed'}", '弹幕加载失败'),
            ('false', 'nil', '弹幕加载失败'),
        ):
            with self.subTest(result=result):
                self.run_case('''
Danmaku_process('123');eq(#calls,1)
callback(%s,%s,'private-path https://private.test/?token=secret')
eq(messages[#messages],%s);eq(durations[#durations],4)
eq(properties['user-data/mpvnet/feedback/danmaku'],'');eq(#removed,1)
for _,text in ipairs(messages) do assert(not text:find('private',1,true)) end
for _,text in ipairs(logs) do assert(not text:find('private',1,true)) end
''' % (success, result, json.dumps(expected, ensure_ascii=False)))

    def test_stale_failure_remains_silent_and_cleans_only_owned_output(self):
        self.run_case('''
Danmaku_process('123');local old_callback=callback
Danmaku_terminate();local count=#messages
old_callback(true,{status=-3,error_string='init'})
eq(#messages,count);eq(#logs,0);eq(#removed,1)
assert(removed[1]:find('owned-temp/bilibili-',1,true)==1)
''')

    def test_replacement_callback_cannot_clear_current_loading(self):
        self.run_case("""
Danmaku_process('123');local old=callback
Danmaku_process('456');local newest=callback
local count=#messages
old(true,{status=-3,error_string='init'})
eq(#messages,count);eq(properties['user-data/mpvnet/feedback/danmaku'],'正在加载弹幕…')
newest(false,{status=1});eq(properties['user-data/mpvnet/feedback/danmaku'],'')
eq(messages[#messages],'弹幕加载失败');eq(durations[#durations],4)
""")

    def test_success_log_osd_never_exposes_path_and_toggle_is_short(self):
        self.run_case("""
o.log_osd=true;file_meta={is_file=true,size=2400}
properties.sid='1';properties['secondary-sid']='no'
Danmaku_process('123');eq(messages[1],'正在加载弹幕…');eq(durations[1],1.5)
callback(true,{status=0})
eq(properties['user-data/mpvnet/feedback/danmaku'],'')
eq(messages[#messages],'弹幕已加载');eq(durations[#durations],2)
eq(properties.sid,'1');eq(properties['secondary-sid'],7)
local count=#messages;Danmaku_toggle();eq(#messages,count+1)
eq(messages[#messages],'弹幕已关闭');eq(durations[#durations],1.5)
for _,text in ipairs(messages) do assert(not text:find('owned-temp',1,true));assert(not text:find('private',1,true)) end
""")

    def test_end_file_shutdown_and_media_mismatch_end_only_owned_status(self):
        self.run_case("""
Danmaku_process('123');local old=callback
media_path='new-media';old(true,{status=0})
eq(properties['user-data/mpvnet/feedback/danmaku'],'');eq(#commands,0)
Danmaku_process('456');old=callback;events['end-file']()
eq(properties['user-data/mpvnet/feedback/danmaku'],'')
old(false,nil);eq(properties['user-data/mpvnet/feedback/danmaku'],'')
Danmaku_process('789');old=callback;events.shutdown();local count=#messages
old(false,nil);eq(#messages,count);eq(properties['user-data/mpvnet/feedback/danmaku'],'')
""")

    def test_ready_coordinator_and_occupied_slot_do_not_start_worker(self):
        self.run_case("""
properties['user-data/mpvnet/feedback/ready']=true;properties['secondary-sid']='3'
Danmaku_process('123');eq(#calls,0);eq(#messages,0)
eq(commands[1][2],'feedback_osd');eq(commands[1][4],'次字幕已占用，无法加载弹幕');eq(commands[1][5],'4')
""")

    def test_ready_loading_is_only_state_and_clears_on_media_end(self):
        self.run_case("""
properties['user-data/mpvnet/feedback/ready']=true
Danmaku_process('123');eq(#messages,0);eq(#commands,0)
eq(properties['user-data/mpvnet/feedback/danmaku'],'正在加载弹幕…')
events['end-file']();eq(properties['user-data/mpvnet/feedback/danmaku'],'')
eq(#commands,0);eq(#messages,0)
""")

    def test_worker_completion_rechecks_new_subtitle_slot_owner(self):
        self.run_case("""
file_meta={is_file=true,size=2400};Danmaku_process('123')
properties['secondary-sid']='3';properties['secondary-sub-visibility']=true
properties['secondary-sub-ass-override']='force'
callback(true,{status=0})
eq(#commands,0);eq(properties['secondary-sid'],'3')
eq(properties['secondary-sub-visibility'],true);eq(properties['secondary-sub-ass-override'],'force')
eq(messages[#messages],'次字幕已占用，无法加载弹幕');eq(durations[#durations],4)
""")

    def test_detection_skips_incomplete_and_non_subtitle_track_metadata(self):
        self.run_case("""
file_meta={is_file=true,size=2400}
local source='https://example.test/123.xml'
tracks={{type='audio',id=1,lang='danmaku',['external-filename']=source},
        {type='sub',id=2,lang='danmaku'},
        {type='sub',id=3,lang='danmaku',['external-filename']='unrelated'},
        {type='sub',id=4,lang='danmaku',['external-filename']=source}}
events['file-loaded']()
eq(#calls,1);eq(calls[1].args[#calls[1].args],'123')
eq(commands[1][1],'sub-remove');eq(commands[1][2],4)
""")

    def test_rejected_subtitle_assignment_does_not_report_success(self):
        self.run_case("""
file_meta={is_file=true,size=2400};properties['secondary-sid']='no'
properties['secondary-sub-visibility']=true;properties['secondary-sub-ass-override']='force'
local set=mp.set_property_native
mp.set_property_native=function(name,value) if name=='secondary-sid' then return false end;return set(name,value) end
Danmaku_process('123');callback(true,{status=0})
eq(messages[#messages],'弹幕加载失败');eq(durations[#durations],4)
eq(properties['user-data/mpvnet/feedback/danmaku'],'')
eq(properties['secondary-sub-visibility'],true);eq(properties['secondary-sub-ass-override'],'force')
eq(commands[#commands][1],'sub-remove');eq(commands[#commands][2],7);eq(#removed,1)
for _,text in ipairs(messages) do assert(text~='弹幕已加载') end
""")

    def test_complete_lua_syntax(self):
        self.lua.check_syntax(DANMAKU)


class ThumbnailFeedback(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = load_lua51()
        cls.source = THUMBFAST.read_text(encoding='utf-8')
        cls.callback = fragment(cls.source, '    subprocess(args, true,', '\nend\n\nlocal function run(command)')

    def run_startup_failure(self, body, *, ready, frontend_path='nil'):
        prelude = '''
local options={mpv_path='mpv'}
local properties={['current-vo']='gpu-next'}
local spawn_waiting,spawn_working=true,false
local os_name,frontend_path='windows',%s
local called,commands,messages=nil,{},{}
local mp={get_property_native=function() return %s end,
 osd_message=function(text,duration) messages[#messages+1]={text,duration} end,
 commandv=function(...) commands[#commands+1]={...} end,
 msg={error=function() end}}
local function subprocess(_,_,cb) called=cb end
''' % (frontend_path, 'true' if ready else 'false')
        client = 'local feedback_client = ' + feedback_module() + '.new(mp)\n'
        self.lua.execute(prelude + client + self.callback + '\ncalled(false,{status=1})\n' + body,
                         'thumbnail/startup-failure')

    def test_windows_compatibility_messages_keep_failure_context(self):
        self.run_startup_failure('''
assert(#messages==0)
assert(#commands==3)
assert(commands[1][2]=='feedback_osd' and commands[1][5]=='4')
for i=2,3 do
 assert(commands[i][4]=='缩略图启动失败\\n请检查进度预览程序路径')
 assert(commands[i][5]==4000 and commands[i][6]==20)
end
''', ready=True)

    def test_startup_failure_routes_safe_text_and_preserves_fallback(self):
        self.run_startup_failure('''
assert(#messages==1 and #commands==0)
assert(messages[1][1]=='缩略图启动失败\\n请检查进度预览程序路径' and messages[1][2]==4)
''', ready=False, frontend_path="'fixture.exe'")
        self.lua.check_syntax(THUMBFAST)
        self.assertNotIn('thumbfast: ERROR!', self.source)


@unittest.skipUnless(os.name == 'nt', 'Windows PowerShell helper checks')
class CaptureHelperReasons(unittest.TestCase):
    powershell = str(Path(os.environ.get('SystemRoot', 'C:/Windows')) / 'System32/WindowsPowerShell/v1.0/powershell.exe')

    def test_reason_mapping_uses_fixed_codes(self):
        source_path = str(HELPER).replace("'", "''")
        script = r'''
$errors=$null; $tokens=$null
$ast=[Management.Automation.Language.Parser]::ParseFile('__SOURCE__',[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors | Out-String)}
$fn=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-CaptureFailureReason'},$true)
if(-not $fn){throw 'Missing reason mapper'}
. ([ScriptBlock]::Create($fn.Extent.Text))
$items=@(@('cancelled','mp4'),@('ffmpeg-missing','ffmpeg'),@('missing','clipboard'),@('range','clip-input'),@('path-setting','input'),@('private URL','webp'),@('private path','commit'),@('test','clipboard'),@('test','staging'),@('secret','unknown'))
$results=@(foreach($item in $items){
  $errorRecord=New-Object Management.Automation.ErrorRecord ([Exception]::new($item[0])),'test',([Management.Automation.ErrorCategory]::NotSpecified),$null
  Get-CaptureFailureReason $errorRecord $item[1]
})
$denied=New-Object Management.Automation.ErrorRecord ([UnauthorizedAccessException]::new('private path')),'test',([Management.Automation.ErrorCategory]::NotSpecified),$null
$results+=Get-CaptureFailureReason $denied 'commit'
$results | ConvertTo-Json -Compress
'''.replace('__SOURCE__', source_path)
        result = subprocess.run([self.powershell, '-NoProfile', '-Command', script], capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), ['cancelled','ffmpeg-missing','file-missing','invalid-range','invalid-path','encode-webp','save','clipboard','temporary-file','worker','access-denied'])

    def test_real_helper_failure_json_and_rollback_without_clipboard(self):
        with tempfile.TemporaryDirectory() as temporary:
            sandbox=Path(temporary)
            png=Path(tempfile.gettempdir()) / ('mpvnet-capture-%d-%d.png' % (os.getpid(), time.time_ns()))
            png.write_bytes(b'fixture: image parsing is bypassed by injected failure')
            self.addCleanup(lambda: png.unlink(missing_ok=True))
            payload={'action':'screenshot','title':'https://example.test/video?token=secret','temp_png':str(png)}
            result=subprocess.run([self.powershell,'-NoProfile','-ExecutionPolicy','Bypass','-File',str(HELPER),'-NoClipboard','-TestOutputRoot',str(sandbox/'output'),'-TestFailPhase','clipboard'],input=json.dumps(payload),capture_output=True,encoding='utf-8-sig',timeout=20)
            self.assertEqual(result.returncode,1,result.stderr)
            report=json.loads(result.stdout)
            self.assertFalse(report['ok'])
            self.assertEqual(report['phase'],'clipboard')
            self.assertEqual(report['reason'],'clipboard')
            self.assertNotIn('secret',result.stdout)
            self.assertNotIn('example.test',result.stdout)
            self.assertFalse(any(p.is_file() for p in sandbox.rglob('*')))
            self.assertFalse(png.exists())


if __name__ == '__main__':
    unittest.main()
