"""Offline failure feedback through real Lua callbacks and PowerShell reason mapping."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

from lua_runtime import load_lua51

from support.lua_source import fragment

ROOT = Path(__file__).resolve().parents[1]
CAPTURE = ROOT / 'config/scripts/capture-controls.lua'
HELPER = ROOT / 'config/helpers/capture-media.ps1'
PLAYBACK = ROOT / 'config/scripts/playback-feedback.lua'
DANMAKU = ROOT / 'config/scripts/bilibiliAssert/main.lua'


class PlaybackEndFeedback(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = load_lua51()
        playback = PLAYBACK.read_text(encoding='utf-8')
        cls.show = fragment(playback, 'local function show(text, duration)', 'local paths =')
        cls.source = fragment(playback,
                              'mp.register_event("end-file", function(event)',
                              'mp.register_event("file-loaded", function()')

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
        self.lua.execute(prelude + self.show + self.source + body, 'playback/end-feedback')

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
'''

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

    def test_explicit_clipboard_url_rejection_and_success(self):
        source = (self.prelude + '\nmp.get_property_native=function() return false end\n'
                  + fragment(PLAYBACK.read_text(encoding='utf-8'), 'local function show(text, duration)', 'local paths =')
                  + self.clipboard_source)
        for value, message in ((None, '剪贴板中没有网址'), ('   ', '剪贴板中没有网址'),
                               ('file:///private/video.mkv', '剪贴板网址无效'),
                               ('https://example.test/a\nhttps://example.test/b', '剪贴板网址无效'),
                               ('not a URL', '剪贴板网址无效')):
            with self.subTest(value=value):
                self.lua.execute(source + '''
clipboard=%s; bindings['clipboard-url']()
eq(messages[#messages],%s); eq(#commands,0)
''' % ('nil' if value is None else json.dumps(value), json.dumps(message, ensure_ascii=False)))
        self.lua.execute(source + '''
clipboard='  https://example.test/video?x=1  '; bindings['clipboard-url']()
eq(#messages,0); eq(#commands,1); eq(commands[1][2],'loadfile')
eq(commands[1][3],'https://example.test/video?x=1'); eq(commands[1][4],'replace')
''')

    def test_complete_lua_syntax(self):
        self.lua.check_syntax(CAPTURE)
        self.lua.check_syntax(PLAYBACK)


class DanmakuFailureFeedback(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = load_lua51()
        cls.source = DANMAKU.read_text(encoding='utf-8')
        cls.prelude = r'''
local messages, logs, calls, removed = {}, {}, {}, {}
local callback = nil
local media_path = 'https://private.test/video?token=secret'
local mp = {
    get_property=function(name, default)
        if name=='path' then return media_path end
        if name=='pid' then return '123' end
        return default
    end,
    get_property_number=function(_, default) return default end,
    get_property_native=function(name) return name=='track-list' and {} or nil end,
    get_time=function() return 1 end,
    get_script_directory=function() return 'private-script-path' end,
    command_native=function() return 'paths.lua' end,
    command_native_async=function(command, fn) calls[#calls+1]=command;callback=fn;return {} end,
    abort_async_command=function() end,
    osd_message=function(text) messages[#messages+1]=text end,
    msg={info=function(text) logs[#logs+1]=text end},
    register_event=function() end, observe_property=function() end,
    register_script_message=function() end, add_key_binding=function() end,
}
package.loaded['mp']=mp
package.loaded['mp.utils']={join_path=function(a,b) return a..'/'..b end,
    file_info=function() return nil end}
package.loaded['mp.options']={read_options=function() end}
local dofile=function() return {options={python_path=''}} end
local os={time=function() return 1 end,getenv=function() return 'owned-temp' end,
    remove=function(path) removed[#removed+1]=path end}
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
'''

    def run_case(self, body):
        self.lua.execute(self.prelude + self.source + body, 'danmaku/failure-feedback')

    def test_only_explicit_spawn_failure_points_to_python_path(self):
        for success, result, expected in (
            ('true', "{status=-3,error_string='init'}", 'DANMAKU LOAD FAILED · PYTHON CANNOT START · CHECK PYTHON PATH'),
            ('true', "{status=1,error_string='',stdout='HTTP 403 private URL'}", 'DANMAKU LOAD FAILED'),
            ('true', "{status=2,error_string='',stdout='conversion failed'}", 'DANMAKU LOAD FAILED'),
            ('true', "{status=-2,error_string='killed'}", 'DANMAKU LOAD FAILED'),
            ('false', 'nil', 'DANMAKU LOAD FAILED'),
        ):
            with self.subTest(result=result):
                self.run_case('''
Danmaku_process('123');eq(#calls,1)
callback(%s,%s,'private-path https://private.test/?token=secret')
eq(messages[#messages],%s)
eq(#removed,1)
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

    def test_complete_lua_syntax(self):
        self.lua.check_syntax(DANMAKU)


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
