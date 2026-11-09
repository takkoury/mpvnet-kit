"""Update controller scheduling and owned helper lifecycle (actual Lua 5.1)."""
from pathlib import Path
import unittest
from lua_runtime import load_lua51

ROOT = Path(__file__).resolve().parents[1]


class UpdateController(unittest.TestCase):
    def run_case(self, case, initial='nil'):
        model = (ROOT/'config/script-modules/user-settings.lua').read_text(encoding='utf-8')
        harness = r'''
local files, bindings, events, calls, messages, observers, timers, aborted = {}, {}, {}, {}, {}, {}, {}, {}
local payload, reply, fail_write, missing_helper
local snapshot = INITIAL
local properties = {}
local function each(list,...) for _,fn in ipairs(list or {}) do fn(...) end end
local function sync(value) snapshot=value;each(observers['user-data/mpvnet/settings-values'],nil,value) end
local function ready(value)
 local values={};if value~=nil then values['updates.auto-check']=value end
 sync({schema=1,startup={available=true,values=values},values=values,revision='1'})
end
local function expire() for _,timer in ipairs(timers) do if not timer.dead then timer.dead=true;timer.fn() end end end
package.loaded.mp = {
 get_property_number=function() return 123 end,get_time=function() return 1 end,
 get_script_name=function() return 'update_check' end,
 get_property_native=function(name) if name=='user-data/mpvnet/settings-values' then return snapshot end;return properties[name] end,
 set_property_native=function(name,value) properties[name]=value end,
 command_native=function(args) return 'C:/config/'..args[2]:sub(4) end,
 command_native_async=function(spec,callback) calls[#calls+1]={spec=spec,callback=callback};return #calls end,
 add_key_binding=function(_,name,fn) bindings[name]=fn end,
 register_script_message=function() end,
 register_event=function(name,fn) events[name]=events[name] or {};table.insert(events[name],fn) end,
 add_hook=function() end,
 observe_property=function(name,_,fn) observers[name]=observers[name] or {};table.insert(observers[name],fn) end,
 add_timeout=function(seconds,fn) local timer={seconds=seconds,fn=fn,kill=function(self) self.dead=true end};table.insert(timers,timer);return timer end,
 osd_message=function(text) messages[#messages+1]=text end,
 abort_async_command=function(id) aborted[#aborted+1]=id end,
}
package.loaded['mp.utils'] = {
 file_info=function(path) if path:find('KitUpdate.exe',1,true) then if missing_helper then return nil end;return {is_file=true} end;return {is_dir=true} end,
 join_path=function(a,b) return a..'/'..b end,
 format_json=function(value) payload=value;return 'json' end,parse_json=function() return reply end,
}
os.getenv=function() return 'C:/fixture' end
os.remove=function(path) files[path]=nil end
io.open=function(path)
 return {write=function(_,text) if fail_write then return nil end;files[path]=text;return true end,close=function() return true end}
end
dofile=function() return assert(loadstring([==[MODEL]==]))() end
'''.replace('INITIAL', initial).replace('MODEL', model)
        load_lua51().execute(harness + '\ndo\n' + (ROOT/'config/scripts/update-check.lua').read_text(encoding='utf-8') + '\nend\n' + case)

    def test_default_waits_for_ready_then_checks_once_without_fullscreen_gate(self):
        self.run_case("""assert(#timers==0 and #calls==0);ready()
assert(#timers==1 and timers[1].seconds==5);expire()
assert(#calls==1 and payload.automatic==true and payload.config_directory=='C:/config/')
assert(files[payload.activation_path]=='0' and calls[1].spec.playback_only==false)
each(events['start-file']);each(events['end-file']);ready();expire();assert(#calls==1)""")

    def test_initial_disabled_and_enable_later_does_not_check(self):
        self.run_case("""ready(false);assert(#timers==0);ready(true);expire();assert(#calls==0)
bindings.open();assert(#calls==1 and payload.automatic==false)""")

    def test_existing_ready_snapshot_schedules_and_obeys_override(self):
        self.run_case('assert(#timers==1);expire();assert(#calls==1)',
                      "{schema=1,startup={available=true,values={}},values={}}")
        self.run_case('assert(#timers==0 and #calls==0)',
                      "{schema=1,startup={available=true,values={['updates.auto-check']=false}},values={['updates.auto-check']=false}}")

    def test_manual_while_automatic_reuses_session_and_does_not_cancel_on_disable(self):
        self.run_case("""ready();expire();bindings.open();bindings.open()
assert(#calls==1 and files[payload.activation_path]=='2')
ready(false);assert(#aborted==0)
reply={ok=true,last_seen_serial=2};calls[1].callback(true,{status=0,stdout='reply'})
assert(next(files)==nil and #calls==1)""")

    def test_manual_before_ready_consumes_auto_opportunity(self):
        self.run_case("""bindings.open();ready();expire();assert(#calls==1 and #timers==0)
assert(payload.automatic==false and files[payload.activation_path]=='1')""")

    def test_disable_cancels_timer_or_automatic_subprocess_only(self):
        self.run_case('ready();ready(false);expire();assert(#calls==0)')
        self.run_case("""ready();expire();ready(false);assert(#aborted==1 and next(files)==nil)
reply={ok=true,last_seen_serial=0};calls[1].callback(true,{status=0,stdout='reply'});assert(#calls==1 and #messages==0)""")

    def test_late_manual_open_replays_once_after_helper_stops_reading(self):
        self.run_case("""ready();expire();bindings.open()
reply={ok=true,last_seen_serial=0};calls[1].callback(true,{status=0,stdout='reply'})
assert(#calls==2 and payload.automatic==false and files[payload.activation_path]=='1')
reply={ok=true,last_seen_serial=1};calls[2].callback(true,{status=0,stdout='reply'})
assert(#calls==2 and next(files)==nil)""")

    def test_failures_are_silent_for_auto_and_short_for_manual(self):
        self.run_case("""ready();expire();calls[1].callback(false,{status=1});assert(#messages==0 and next(files)==nil)
bindings.open();calls[2].callback(false,{status=1});assert(#messages==1 and next(files)==nil)
missing_helper=true;bindings.open();assert(#calls==2 and #messages==2)""")
        self.run_case("""fail_write=true;ready();expire();assert(#messages==0 and next(files)==nil)
bindings.open();assert(#messages==1 and next(files)==nil)""")

    def test_shutdown_aborts_owned_process_and_never_reopens(self):
        self.run_case("""ready();expire();bindings.open();files['unrelated']='keep';each(events.shutdown)
assert(#aborted==1 and files.unrelated=='keep');files.unrelated=nil;assert(next(files)==nil)
reply={ok=true,last_seen_serial=0};calls[1].callback(true,{status=0,stdout='reply'});bindings.open()
assert(#calls==1 and #messages==0)""")
        self.run_case('ready();each(events.shutdown);expire();assert(#calls==0)')

    def test_failed_launch_cleans_files_and_late_cancelled_callback_cannot_clear_new_manual_session(self):
        self.run_case("""package.loaded.mp.command_native_async=function() error('launch failed') end
ready();expire();assert(#messages==0 and next(files)==nil)
bindings.open();assert(#messages==1 and next(files)==nil)""")
        self.run_case("""ready();expire();ready(false);bindings.open();local activation=payload.activation_path
reply={ok=true,last_seen_serial=0};calls[1].callback(true,{status=0,stdout='reply'})
assert(files[activation]=='1' and #calls==2);bindings.open();assert(files[activation]=='2' and #calls==2)""")


if __name__ == '__main__':
    unittest.main()
