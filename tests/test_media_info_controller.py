"""About controller lifecycle and hidden WPF/launcher checks."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from lua_runtime import load_lua51

ROOT = Path(__file__).resolve().parents[1]


class MediaInfoController(unittest.TestCase):
    def run_case(self, case):
        harness = r'''
local files, bindings, events, calls, messages = {}, {}, {}, {}, {}
local payload, reply, fail_write, aborted
local props={path='https://example.test/video?token=secret', ['media-title']='https://example.test/video?token=secret', ['track-list']={{id=1,type='audio',lang='ja',codec='aac',['external-filename']='https://secret'}}}
package.loaded.mp = {
 get_property_number=function() return 123 end, get_time=function() return 1 end,
 get_property=function() return '"quoted textual property"' end,
 get_property_native=function(name,default) if props[name]~=nil then return props[name] end; return default end,
 command_native=function(args) return args[2] end,
 command_native_async=function(spec, callback) calls[#calls+1]={spec=spec,callback=callback}; return #calls end,
 add_key_binding=function(_,name,fn) bindings[name]=fn end,
 register_script_message=function() end, register_event=function(name,fn) events[name]=fn end,
 osd_message=function(text) messages[#messages+1]=text end,
 abort_async_command=function(id) aborted=id end,
}
package.loaded['mp.utils'] = {
 file_info=function() return {is_dir=true} end, join_path=function(a,b) return a..'/'..b end,
 format_json=function(value) payload=value; return 'json' end, parse_json=function() return reply end,
}
dofile=function() return {powershell=function() return 'powershell.exe' end} end
os.getenv=function() return 'C:/fixture' end
os.remove=function(path) files[path]=nil end
io.open=function(path)
 return {write=function(_,text) if fail_write then return nil end;files[path]=text;return true end,close=function() return true end}
end
'''
        load_lua51().execute(harness + (ROOT/'config/scripts/media-info.lua').read_text(encoding='utf-8') + '\n' + case)

    def test_repeated_open_reuses_one_helper_and_excludes_network_secrets(self):
        self.run_case("""bindings.open();bindings.open();bindings.open()
assert(#calls==1 and files[payload.activation_path]=='3')
assert(payload.title=='网络媒体' and payload.local_path=='' and payload.has_media)
assert(payload.properties.tracks[1].codec=='aac' and not payload.properties.tracks[1]['external-filename'])
assert(calls[1].spec.playback_only==false and not calls[1].spec.stdin_data)
reply={ok=true,last_seen_serial=3};calls[1].callback(true,{status=0,stdout='reply'})
assert(next(files)==nil and #calls==1)""")

    def test_late_open_after_close_is_replayed_once(self):
        self.run_case("""bindings.open();bindings.open()
reply={ok=true,last_seen_serial=1};calls[1].callback(true,{status=0,stdout='reply'})
assert(#calls==2 and files[payload.activation_path]=='1')
reply={ok=true,last_seen_serial=1};calls[2].callback(true,{status=0,stdout='reply'})
assert(#calls==2 and next(files)==nil)""")

    def test_failed_start_and_failed_write_clean_owned_files(self):
        self.run_case("""bindings.open();calls[1].callback(false,{status=1})
assert(next(files)==nil and #messages==1)
fail_write=true;bindings.open();assert(#calls==1 and next(files)==nil and #messages==2)""")

    def test_launch_exception_releases_the_session(self):
        self.run_case("""package.loaded.mp.command_native_async=function() error('launch failed') end
bindings.open();assert(next(files)==nil and #messages==1)
bindings.open();assert(next(files)==nil and #messages==2)""")

    def test_shutdown_aborts_only_owned_helper_and_does_not_reopen(self):
        self.run_case("""bindings.open();bindings.open();events.shutdown()
assert(aborted==1 and next(files)==nil)
reply={ok=true,last_seen_serial=1};calls[1].callback(true,{status=0,stdout='reply'});bindings.open()
assert(#calls==1 and #messages==0)""")


    def test_empty_player_still_opens_empty_information_window(self):
        self.run_case("""props.path='';props['media-title']='previous file title';bindings.open()
assert(#calls==1 and not payload.has_media and payload.title=='尚未打开媒体' and payload.local_path=='')""")

    def test_explicit_open_after_media_change_waits_for_old_helper(self):
        self.run_case("""bindings.open();props.path='https://example.test/next';bindings.open();bindings.open()
assert(#calls==1 and aborted==1)
calls[1].callback(false,{status=-1});assert(#calls==2 and #messages==0)
reply={ok=true,last_seen_serial=1};calls[2].callback(true,{status=0,stdout='reply'})
assert(next(files)==nil)""")

    def test_local_path_resolves_without_probing_on_the_playback_thread(self):
        self.run_case("""props.path='missing.mkv';props['working-directory']='D:/Videos';props['media-title']='missing.mkv'
package.loaded['mp.utils'].file_info=function(path) assert(path=='C:/fixture');return {is_dir=true} end
bindings.open();assert(payload.local_path=='D:/Videos/missing.mkv' and payload.has_media)""")

    def test_network_filename_title_omits_query_credentials(self):
        self.run_case("""props['media-title']='movie.mp4?token=secret#part';props.filename=props['media-title']
bindings.open();assert(payload.title=='movie.mp4' and payload.local_path=='')""")


@unittest.skipUnless(os.name == 'nt', 'Requires Windows WPF')
class MediaInfoLauncher(unittest.TestCase):
    def invoke(self, update=None):
        with tempfile.TemporaryDirectory(prefix='mpvnet-media-launch-') as temp:
            request = Path(temp)/'request.json'
            data = dict(schema=1, token='fixture', parent_pid=os.getpid(),
                        activation_path=str(request)+'.activate', has_media=True,
                        local_path='', title='网络演示', properties=dict(width=1920,height=1080,video_format='hevc'))
            data.update(update or {})
            request.write_text(json.dumps(data, ensure_ascii=False), encoding='utf-8')
            result = subprocess.run(['powershell.exe','-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',
                str(ROOT/'config/helpers/media-info-window.ps1'),'-RequestPath',str(request),'-ValidateOnly'],
                capture_output=True, timeout=30)
            return result.returncode, json.loads(result.stdout.decode('utf-8-sig'))

    def test_real_launcher_composes_data_and_view_without_window(self):
        code, value = self.invoke()
        self.assertEqual(code, 0, value)
        self.assertEqual(value['kind'], 'network')
        self.assertEqual(value['overview']['resolution'], '1920 × 1080')
        self.assertEqual(value['report'], '')
        self.assertFalse(value['handle_created'] or value['timer_created'])

    def test_empty_media_and_unrelated_activation_are_distinct(self):
        code, value = self.invoke({'has_media':False})
        self.assertEqual(code, 0, value)
        self.assertEqual(value['kind'], 'empty')
        code, value = self.invoke({'activation_path':'C:/unrelated.activate'})
        self.assertNotEqual(code, 0)
        self.assertFalse(value['ok'])

