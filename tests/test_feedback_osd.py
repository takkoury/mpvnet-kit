"""OSD coordination must not clear or repeatedly overwrite native messages."""
from pathlib import Path
import unittest
from lua_runtime import load_lua51

ROOT = Path(__file__).resolve().parents[1]


class FeedbackOSD(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = load_lua51()
        cls.source = (ROOT / 'config/scripts/feedback-osd.lua').read_text(encoding='utf-8')

    def run_case(self, body):
        prelude = r'''
local props={['osd-msg1']='', ['osd-level']=1}
local observers, events, handlers, timers, messages, writes = {},{},{},{},{},{}
local fail=false
local function get(k,d) if props[k]~=nil then return props[k] end;return d end
local mp={get_property=get,get_property_native=get,get_property_number=get,
 set_property=function(k,v) if fail then return false end;props[k]=v;writes[#writes+1]={k,v};return true end,
 set_property_native=function(k,v) props[k]=v;return true end,
 observe_property=function(k,_,f) observers[k]=f end,
 register_script_message=function(k,f) handlers[k]=f end,
 register_event=function(k,f) events[k]=f end,
 osd_message=function(t,d) messages[#messages+1]={t,d} end,
 add_timeout=function(d,f) local t={duration=d,fn=f,kill=function(self) self.killed=true end};timers[#timers+1]=t;return t end}
package.loaded.mp=mp
local function property(k,v) props[k]=v;observers[k](k,v) end
local function status(k,v) property('user-data/mpvnet/feedback/'..k,v) end
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
'''
        self.lua.execute(prelude + self.source + '\n' + body, 'feedback-osd')

    def test_short_replacement_and_stale_timer_cannot_restore_early(self):
        self.run_case('''
status('capture','正在导出片段…');eq(props['osd-msg1'],'正在导出片段…')
handlers.show('倍速 ×1.25','1.5');eq(props['osd-msg1'],'');eq(messages[1][2],1.5)
handlers.show('复制失败','4');eq(timers[1].killed,true)
timers[1].fn();eq(props['osd-msg1'],'')
timers[2].fn();eq(props['osd-msg1'],'正在导出片段…');eq(#messages,2)
''')

    def test_task_completion_and_concurrent_mode_survive_independently(self):
        self.run_case('''
status('capture','导出中');status('subtitle','字幕调整');eq(props['osd-msg1'],'导出中\\n字幕调整')
handlers.show('成功','2');status('capture','');timers[1].fn()
eq(props['osd-msg1'],'字幕调整');status('subtitle','');eq(props['osd-msg1'],'')
''')

    def test_danmaku_loading_has_its_own_slot(self):
        self.run_case('''
status('capture','导出中');status('danmaku','正在加载弹幕…');status('subtitle','字幕调整')
eq(props['osd-msg1'],'导出中\\n正在加载弹幕…\\n字幕调整')
handlers.show('倍速','1.5');status('danmaku','');timers[1].fn()
eq(props['osd-msg1'],'导出中\\n字幕调整')
''')

    def test_external_native_message_is_never_cleared_or_replayed(self):
        self.run_case('''
status('capture','导出中');handlers.show('倍速','1.5')
mp.osd_message('外部属性详情',20);timers[1].fn()
eq(#messages,2);eq(messages[2][1],'外部属性详情');eq(messages[2][2],20)
eq(props['osd-msg1'],'导出中')
''')

    def test_user_prefix_and_external_override_ownership(self):
        self.run_case('''
props['osd-msg1']='用户 ${filename}'
status('capture','导出中');eq(props['osd-msg1'],'用户 ${filename}\\n导出中')
handlers.show('速度','1.5');eq(props['osd-msg1'],'用户 ${filename}')
property('osd-msg1','外部值');timers[1].fn();eq(props['osd-msg1'],'外部值')
status('subtitle','调整中');eq(props['osd-msg1'],'外部值')
status('capture','');status('subtitle','');eq(props['osd-msg1'],'外部值')
status('capture','新任务');eq(props['osd-msg1'],'外部值\\n新任务')
events.shutdown();eq(props['osd-msg1'],'外部值')
''')

    def test_console_selector_and_osd_level_suspend_without_changing_preferences(self):
        self.run_case('''
status('capture','导出中')
property('user-data/mpv/console/open',true);eq(props['osd-msg1'],'')
property('user-data/mpvnet/track-selector/open',true)
property('user-data/mpv/console/open',false);eq(props['osd-msg1'],'')
property('user-data/mpvnet/track-selector/open',false);eq(props['osd-msg1'],'导出中')
property('osd-level',0);eq(props['osd-msg1'],'');eq(props['osd-level'],0)
property('osd-level',1);eq(props['osd-msg1'],'导出中')
''')

    def test_shutdown_old_callbacks_and_rejected_write(self):
        self.run_case('''
status('capture','导出中');handlers.show('速度','1.5');events.shutdown()
timers[1].fn();handlers.show('迟到消息','2');status('capture','迟到状态')
eq(props['osd-msg1'],'');eq(#messages,1);eq(props['user-data/mpvnet/feedback/ready'],false)
''')
        self.run_case('''
fail=true;status('capture','导出中');fail=false
status('subtitle','调整');eq(props['osd-msg1'],'')
status('capture','');status('subtitle','');status('capture','新任务');eq(props['osd-msg1'],'新任务')
''')

    def test_invalid_duration_and_text_cannot_break_coordinator(self):
        self.run_case('''
handlers.show('bad','inf');handlers.show('bad','0');eq(#messages,0)
status('capture',{});eq(props['osd-msg1'],'')
status('capture','${path}');eq(props['osd-msg1'],'$${path}')
''')
