"""About controller lifecycle and hidden WPF/launcher checks."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from lua_runtime import load_lua51

ROOT = Path(__file__).resolve().parents[1]


class AboutController(unittest.TestCase):
    def run_case(self, case):
        harness = r'''
local files, bindings, events, calls, messages = {}, {}, {}, {}, {}
local payload, reply, fail_write, aborted
package.loaded.mp = {
 get_property_number=function() return 123 end, get_time=function() return 1 end,
 get_property=function() return '"quoted textual property"' end,
 get_property_native=function(name) return ({['user-data/frontend/version']='7.1.2.0',['mpv-version']='mpv actual',['ffmpeg-version']='ffmpeg actual'})[name] end,
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
        load_lua51().execute(harness + (ROOT/'config/scripts/about-window.lua').read_text(encoding='utf-8') + '\n' + case)

    def test_repeated_open_reuses_one_helper_and_actual_versions(self):
        self.run_case("""bindings.open();bindings.open();bindings.open()
assert(#calls==1 and files[payload.activation_path]=='3')
assert(payload.host_version=='7.1.2.0' and payload.mpv_version=='mpv actual' and payload.ffmpeg_version=='ffmpeg actual')
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


@unittest.skipUnless(os.name == 'nt', 'Requires Windows WPF')
class AboutWindowTests(unittest.TestCase):
    def launch(self, update=None, receipt=None):
        with tempfile.TemporaryDirectory(prefix='mpvnet-about-test-') as temp:
            request = Path(temp)/'request.json'
            data = dict(schema=1, token='fixture', parent_pid=os.getpid(), activation_path=str(request)+'.activate',
                        host_version='7.1.2.0', mpv_version='mpv fixture', ffmpeg_version='ffmpeg fixture')
            data.update(update or {})
            if receipt is not None:
                data['config_directory'] = temp
                value = dict(schema=1, owner='mpvnet-kit', kind='receipt', target=temp, packageVersion='0.5.0-m3.5-preview')
                value.update(receipt)
                (Path(temp)/'.mpvnet-kit-install.json').write_text(json.dumps(value), encoding='utf-8')
            request.write_text(json.dumps(data), encoding='utf-8')
            result = subprocess.run(['powershell.exe','-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',
                str(ROOT/'config/helpers/about-window.ps1'),'-RequestPath',str(request),'-ValidateOnly'], capture_output=True, timeout=30)
            value = json.loads(result.stdout.decode('utf-8-sig'))
            return result.returncode, value

    def test_readonly_content_and_no_window_in_validation(self):
        code, data = self.launch()
        self.assertEqual(code, 0, data)
        self.assertEqual(data['host_version'], '7.1.2.0')
        self.assertEqual(data['mpv_version'], 'mpv fixture')
        self.assertEqual(data['ffmpeg_version'], 'ffmpeg fixture')
        self.assertEqual(data['package_version'], '未能读取')
        for key in ('handle_created','timer_running','show_in_taskbar','topmost','details_expanded'):
            self.assertFalse(data[key], (key, data))
        self.assertIn('GPL v2', data['license'])
        self.assertIn('mpv.net/mpv/mplayer', data['copyright'])
        for key in ('host_modified','mpv_modified','mediainfo_modified','mediainfo_version'):
            self.assertTrue(data[key])

    def test_rejects_unrelated_activation_file(self):
        code, data = self.launch({'activation_path':'C:/unrelated.txt'})
        self.assertNotEqual(code, 0)
        self.assertFalse(data['ok'])

    def test_package_version_comes_from_receipt_without_backup_chain(self):
        code, data = self.launch(receipt={})
        self.assertEqual(code, 0, data)
        self.assertEqual(data['package_version'], '0.5.0-m3.5-preview')

    def test_invalid_receipt_identity_or_version_preserves_host_information(self):
        for receipt in ({'owner':'other'}, {'schema':True}, {'target':'C:/unrelated'}, {'packageVersion':'bad\nversion'}, {'padding':'x'*1048576}):
            with self.subTest(receipt=receipt):
                code, data = self.launch(receipt=receipt)
                self.assertEqual(code, 0, data)
                self.assertEqual(data['package_version'], '未能读取')
                self.assertEqual(data['host_version'], '7.1.2.0')
