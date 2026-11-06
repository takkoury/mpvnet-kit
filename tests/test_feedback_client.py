"""Exercise the complete feedback client through its supported host interface."""
import json
from pathlib import Path
import unittest

from lua_runtime import load_lua51

ROOT = Path(__file__).resolve().parents[1]


class FeedbackClient(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = load_lua51()
        cls.path = ROOT / 'config/script-modules/feedback.lua'

    def run_case(self, body):
        prelude = '''
local ready
local native, commands = {}, {}
local mp = {
    get_property_native = function(name)
        assert(name == 'user-data/mpvnet/feedback/ready')
        return ready
    end,
    osd_message = function(text, seconds)
        native[#native + 1] = {text, seconds}
        return 'native'
    end,
    commandv = function(...)
        commands[#commands + 1] = {...}
        return 'coordinator'
    end,
}
local policy = dofile(__MODULE_PATH__)
local client = policy.new(mp)
'''.replace('__MODULE_PATH__', json.dumps(self.path.as_posix()))
        self.lua.execute(prelude + body, 'feedback-client')

    def test_action_success_and_error_have_the_accepted_durations(self):
        self.run_case('''
client.show('动作', 'action')
client.show('完成', 'success')
client.show('失败', 'error')
client.show('正在处理，请稍候', 'notice')
assert(native[1][2] == 1.5 and native[2][2] == 2 and native[3][2] == 4)
assert(native[4][2] == 2)
assert(#commands == 0)
''')

    def test_readiness_is_checked_for_each_message_with_native_fallback(self):
        self.run_case('''
assert(not client.is_ready())
assert(client.show('第一条', 'action') == 'native')
ready = true
assert(client.is_ready())
assert(client.show('第二条', 'success') == 'coordinator')
local call = commands[1]
assert(#call == 5 and call[1] == 'script-message-to' and call[2] == 'feedback_osd')
assert(call[3] == 'show' and call[4] == '第二条' and call[5] == '2')
ready = false
assert(client.show('第三条', 'error') == 'native')
assert(#commands == 1 and #native == 2)
ready = 'true'
assert(not client.is_ready())
''')

    def test_text_and_return_values_are_not_rewritten(self):
        self.run_case(r'''
local text = '字幕位置 90%\n字号 ×1.20'
client.show(text, 'action')
ready = true
client.show(text, 'action')
assert(native[1][1] == text and commands[1][4] == text)
''')

    def test_invalid_kind_is_a_programming_error_without_sending(self):
        self.run_case('''
for _, kind in ipairs({'unknown', '1.5', 1.5}) do
    assert(not pcall(client.show, '错误调用', kind))
end
assert(#native == 0 and #commands == 0)
''')

    def test_policy_keeps_existing_wire_durations_and_finite_owner_order(self):
        self.run_case('''
assert(policy.accepts_duration(1.5) and policy.accepts_duration(2) and policy.accepts_duration(4))
for _, value in ipairs({0, 3, 20, '2', math.huge}) do assert(not policy.accepts_duration(value)) end
assert(not policy.accepts_duration(nil) and not policy.accepts_duration(0/0))
assert(table.concat(policy.owners, ',') == 'capture,danmaku,subtitle')
''')
