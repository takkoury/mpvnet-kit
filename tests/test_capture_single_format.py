"""Selected-format exports: real Lua routing and optional local FFmpeg outputs."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import uuid

from lua_runtime import load_lua51

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'config/helpers/capture-media.ps1'


class CaptureRouting(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = load_lua51()
        cls.source = (ROOT / 'config/scripts/capture-controls.lua').read_text(encoding='utf-8')
        cls.prelude = r'''
local bindings, messages, events, calls, removed, states = {}, {}, {}, {}, {}, {}
local reply, callback, payload, state, time = nil, nil, nil, nil, 1
local payload_failure, on_parse_reply = nil, nil
local native = {vid=1, aid=2, ['video-out-params']={}}
local tracks = {{type='video',id=1,['ff-index']=0}}
local temp, screenshot_calls = 'TEMP', 0
local mp = {
    get_property_number=function(name, default)
        if name=='time-pos' then return time end
        if name=='pid' then return 123 end
        return default
    end,
    get_property=function(name) return name=='working-directory' and 'X:/' or 'fixture.mkv' end,
    get_property_native=function(name)
        if name=='track-list' then return tracks end
        return native[name]
    end,
    get_time=function() return time end,
    command_native=function(command)
        if command[1]=='screenshot-to-file' then screenshot_calls=screenshot_calls+1 end
        return 'paths.lua'
    end,
    command_native_async=function(_, fn) calls[#calls+1]=payload; callback=fn end,
    set_property_native=function(_, value) state=value; states[#states+1]=value end,
    osd_message=function(text) messages[#messages+1]=text end,
    add_key_binding=function(_, name, fn) bindings[name]=fn end,
    register_script_message=function(name, fn) messages[name]=fn end,
    register_event=function(name, fn) events[name]=fn end,
    msg={warn=function() end},
}
package.loaded['mp']=mp
package.loaded['mp.utils']={
    join_path=function(a,b) return a..'/'..b end,
    file_info=function() return {is_file=true} end,
    format_json=function(value) payload=value; return '{}' end,
    parse_json=function()
        if on_parse_reply then local fn=on_parse_reply; on_parse_reply=nil; fn() end
        return reply
    end,
}
local dofile=function() return {powershell=function() return 'powershell' end, capture_payload=function() end} end
local os={getenv=function() return temp end,remove=function(path) removed[#removed+1]=path end}
local io={open=function()
    if payload_failure=='open' then return nil end
    return {write=function() return payload_failure~='write' end,
            close=function() return payload_failure~='close' end}
end}
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function clip(format)
    messages['set-default-format'](format)
    time=1;bindings['clip-point']();time=2;bindings['clip-point']()
end
local function finish(format, path)
    reply={ok=true,files={[format]=path},clipboard_format=format}
    callback(true,{status=0,stdout='reply'})
end
'''

    def run_case(self, body):
        self.lua.execute(self.prelude + '\n' + self.source + '\n' + body, 'capture/single-format')

    def test_selected_format_is_frozen_and_latest_copy_is_independent(self):
        self.run_case('''
clip('gif');eq(calls[1].clipboard_format,'gif');eq(state.busy,true)
eq(state.a,nil);eq(state.pending_clip.start,1);eq(state.pending_clip.finish,2)
eq(state.pending_clip.media_generation,state.media_generation)
messages['set-default-format']('mp4');eq(state.clipboard_format,'mp4')
eq(state.pending_clip.start,1);eq(state.pending_clip.finish,2)
finish('gif','output.gif');eq(state.latest_format,'gif');eq(state.busy,false)
eq(state.pending_clip,nil)
eq(messages[#messages],'CLIP SAVED · GIF COPIED')
bindings['copy-latest']();eq(calls[2].action,'copy');eq(calls[2].file,'output.gif')
finish('gif','output.gif');eq(messages[#messages],'GIF COPIED')
eq(bindings['copy-webp'],nil);eq(bindings['copy-gif'],nil);eq(bindings['copy-mp4'],nil)
''')

    def test_failure_preserves_previous_export_and_releases_busy(self):
        self.run_case('''
clip('webp');finish('webp','old.webp');clip('mp4')
reply={ok=false,reason='encode-mp4'};callback(false,{status=1,stdout='reply'})
eq(state.busy,false);eq(state.latest_format,'webp');eq(state.pending_clip,nil)
bindings['copy-latest']();eq(calls[3].file,'old.webp')
''')

    def test_copy_without_output_or_while_busy_does_not_start_worker(self):
        self.run_case('''
bindings['copy-latest']();eq(messages[#messages],'NO CLIP');eq(#calls,0)
clip('webp');bindings['copy-latest']();eq(messages[#messages],'CAPTURE BUSY');eq(#calls,1)
''')

    def test_zero_start_and_invalid_b_preserve_visible_a(self):
        self.run_case('''
eq(state.media_generation,0);eq(state.pending_clip,nil)
time=0;bindings['clip-point']();eq(state.a,0);eq(state.pending_clip,nil)
time=0;bindings['clip-point']();eq(state.a,0);eq(#calls,0)
eq(messages[#messages],'CLIP B MUST BE AFTER A')
time=-1;bindings['clip-point']();eq(state.a,0);eq(#calls,0)
time=2;bindings['clip-point']();eq(state.a,nil);eq(state.pending_clip.start,0)
eq(state.pending_clip.finish,2);eq(state.pending_clip.media_generation,0)
time=3;bindings['clip-point']();eq(#calls,1);eq(messages[#messages],'CAPTURE BUSY')
eq(state.pending_clip.start,0);eq(state.pending_clip.finish,2)
finish('webp','zero.webp');eq(state.pending_clip,nil);eq(state.busy,false)
events['start-file']();time=2;bindings['clip-point']()
time=1;bindings['clip-point']();eq(state.a,2);eq(#calls,1)
eq(messages[#messages],'CLIP B MUST BE AFTER A')
''')

    def test_payload_failures_clear_frozen_range_and_release_busy(self):
        for failure in ('open', 'write', 'close'):
            with self.subTest(failure=failure):
                self.run_case('''
clip('webp');finish('webp','old.webp')
payload_failure='%s';clip('gif')
eq(#calls,1);eq(state.busy,false);eq(state.a,nil);eq(state.pending_clip,nil)
eq(state.latest_format,'webp');eq(state.has_clip,true)
local exporting=states[#states-1]
eq(exporting.busy,true);eq(exporting.pending_clip.start,1)
eq(exporting.pending_clip.finish,2)
eq(messages[#messages],'CLIP FAILED · TEMP UNAVAILABLE · CHECK TEMP FOLDER')
payload_failure=nil;clip('mp4');eq(#calls,2);eq(state.busy,true)
finish('mp4','new.mp4');eq(state.pending_clip,nil)
''' % failure)

    def test_screenshot_without_video_or_temp_has_actionable_reason(self):
        self.run_case('''
native['video-out-params']=nil
bindings['screenshot']()
eq(messages[#messages],'SCREENSHOT FAILED · NO VIDEO · OPEN A VIDEO')
eq(#calls,0);eq(screenshot_calls,0);eq(state.busy,false)
native['video-out-params']={}
temp=nil;bindings['screenshot']()
eq(messages[#messages],'SCREENSHOT FAILED · TEMP UNAVAILABLE · CHECK TEMP FOLDER')
eq(#calls,0);eq(screenshot_calls,0);eq(state.busy,false)
temp='TEMP';bindings['screenshot']()
eq(screenshot_calls,1);eq(#calls,1);eq(state.busy,true)
reply={ok=true};callback(true,{status=0,stdout='reply'})
eq(messages[#messages],'SCREENSHOT SAVED');eq(state.busy,false)
''')

    def test_idle_window_with_video_output_params_does_not_attempt_screenshot(self):
        # A real force-window idle instance retains video-out-params, so that
        # property alone does not prove an active video is available.
        self.run_case('''
native['idle-active']=true;native['video-out-params']={}
bindings['screenshot']()
eq(messages[#messages],'SCREENSHOT FAILED · NO VIDEO · OPEN A VIDEO')
eq(#calls,0);eq(screenshot_calls,0);eq(state.busy,false)
native['idle-active']=false;bindings['screenshot']()
eq(screenshot_calls,1);eq(#calls,1);eq(state.busy,true)
''')

    def test_unexportable_video_or_audio_preserves_a_and_can_retry(self):
        for tracks, message in (
            ('{}', 'NO VIDEO · OPEN A VIDEO'),
            ("{{type='video',id=1}}", 'STREAM NOT EXPORTABLE · TRY ANOTHER VIDEO'),
            ("{{type='video',id=1,['ff-index']=-1}}", 'STREAM NOT EXPORTABLE · TRY ANOTHER VIDEO'),
            ("{{type='video',id=1,['ff-index']=0},{type='audio',id=2}}", 'STREAM NOT EXPORTABLE · TRY ANOTHER VIDEO'),
        ):
            with self.subTest(tracks=tracks):
                self.run_case('''
tracks=%s;clip('gif')
eq(messages[#messages],%s)
eq(#calls,0);eq(state.a,1);eq(state.busy,false);eq(state.pending_clip,nil)
tracks={{type='video',id=1,['ff-index']=0}}
bindings['clip-point']();eq(#calls,1);eq(state.a,nil);eq(state.busy,true)
''' % (tracks, json.dumps('CLIP FAILED · ' + message, ensure_ascii=False)))

    def test_media_changes_hide_ranges_without_interrupting_worker(self):
        self.run_case('''
time=0;bindings['clip-point']();events['end-file']()
eq(state.a,nil);eq(state.pending_clip,nil);eq(state.media_generation,1)
events['start-file']();eq(state.media_generation,2)
clip('gif');eq(state.pending_clip.media_generation,2)
local old_callback=callback
events['end-file']();eq(state.media_generation,3)
eq(state.a,nil);eq(state.pending_clip,nil);eq(state.busy,true)
events['start-file']();eq(state.media_generation,4);eq(state.busy,true)
bindings['clip-point']();eq(#calls,1);eq(state.a,nil)
eq(messages[#messages],'CAPTURE BUSY')
reply={ok=true,files={gif='previous-media.gif'}}
old_callback(true,{status=0,stdout='reply'})
eq(state.busy,false);eq(state.pending_clip,nil);eq(state.media_generation,4)
eq(state.latest_format,'gif');eq(state.has_clip,true)
time=0;bindings['clip-point']();eq(state.a,0)
bindings['copy-latest']();eq(calls[2].file,'previous-media.gif')
finish('gif','previous-media.gif');eq(state.a,0);eq(state.pending_clip,nil)
events['end-file']();eq(state.a,nil);eq(state.has_clip,true)
''')

    def test_old_callback_does_not_clear_new_media_a(self):
        for success in (True, False):
            with self.subTest(success=success):
                # Reenter at the reply boundary after busy is released. This
                # catches callback cleanup accidentally resetting a newer A.
                self.run_case('''
clip('gif');finish('gif','old.gif');clip('mp4')
on_parse_reply=function()
    events['end-file']();events['start-file']()
    time=0;bindings['clip-point']()
end
reply={ok=%s,reason='encode-mp4',files={mp4='previous-media.mp4'}}
callback(%s,{status=%d,stdout='reply'})
eq(state.a,0);eq(state.pending_clip,nil);eq(state.media_generation,2)
eq(state.busy,false);eq(state.latest_format,'%s')
''' % ('true' if success else 'false', 'true' if success else 'false',
       0 if success else 1, 'mp4' if success else 'gif'))


@unittest.skipUnless(os.name == 'nt', 'Capture helper uses Windows PowerShell')
class CaptureOutputs(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.output = self.base / 'output'
        self.environment = dict(os.environ, TEMP=str(self.base), TMP=str(self.base))

    def invoke(self, format, *extra, source=None):
        payload = {'action':'clip', 'title':'fixture.mkv', 'start':0, 'finish':0.3,
                   'clipboard_format':format, 'job_id':str(uuid.uuid4().int),
                   'video':{'path':str(source or self.base/'fixture.mkv'), 'index':0}}
        if os.environ.get('MPVNET_TEST_FFMPEG'):
            payload['ffmpeg_path'] = os.environ['MPVNET_TEST_FFMPEG']
        result = subprocess.run(['powershell.exe','-NoProfile','-STA','-ExecutionPolicy','Bypass',
                                 '-File',str(HELPER),'-NoClipboard','-TestOutputRoot',str(self.output),*extra],
                                input=json.dumps(payload),capture_output=True,encoding='utf-8-sig',
                                env=self.environment,timeout=30)
        return result, json.loads(result.stdout)

    def test_preview_only_plans_selected_format(self):
        for format in ('mp4','webp','gif'):
            with self.subTest(format=format):
                result, report = self.invoke(format, '-ValidateOnly')
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertEqual(set(report['files']),{format})
                self.assertEqual(report['clipboard_format'],format)
                self.assertFalse(self.output.exists())

    def fixture(self):
        ffmpeg = os.environ.get('MPVNET_TEST_FFMPEG')
        if not ffmpeg:
            self.skipTest('Set MPVNET_TEST_FFMPEG to an existing local ffmpeg.exe for real encoding')
        self.assertTrue(Path(ffmpeg).is_file())
        source = self.base/'fixture.mkv'
        subprocess.run([ffmpeg,'-hide_banner','-loglevel','error','-f','lavfi','-i',
                        'testsrc2=size=96x64:rate=12','-t','0.5','-c:v','ffv1',str(source)],
                       check=True,capture_output=True,timeout=15)
        return source

    def test_real_encoders_save_only_selected_file_and_remove_intermediate(self):
        source = self.fixture()
        for format in ('mp4','webp','gif'):
            with self.subTest(format=format):
                before = set(self.output.rglob('*')) if self.output.exists() else set()
                result, report = self.invoke(format, source=source)
                self.assertEqual(result.returncode,0,result.stderr+result.stdout)
                self.assertEqual(set(report['files']),{format})
                final = Path(report['files'][format])
                self.assertGreater(final.stat().st_size,0)
                self.assertEqual({p for p in self.output.rglob('*') if p.is_file()} - before,{final})
                self.assertFalse(list(self.base.glob('mpvnet-capture-job-*')))

    def test_commit_and_clipboard_failure_leave_existing_files_untouched(self):
        source = self.fixture()
        self.output.mkdir()
        existing = self.output/'existing.mp4'
        existing.write_bytes(b'keep existing output')
        for phase in ('commit','clipboard'):
            with self.subTest(phase=phase):
                result, report = self.invoke('webp','-TestFailPhase',phase,source=source)
                self.assertEqual(result.returncode,1)
                self.assertEqual(report['phase'],phase)
                self.assertEqual({p for p in self.output.rglob('*') if p.is_file()},{existing})
                self.assertEqual(existing.read_bytes(),b'keep existing output')
                self.assertFalse(list(self.base.glob('mpvnet-capture-job-*')))


if __name__ == '__main__':
    unittest.main()
