from pathlib import Path
import unittest

from lua_runtime import load_lua51

MODULE = Path(__file__).resolve().parents[1] / 'config/script-modules/web-resume.lua'


class WebResume(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lua = load_lua51()
        cls.source = MODULE.read_text(encoding='utf-8')

    def run_case(self, case):
        fixture = r'''
local bind, opened, fetched, events, messages, cancelled = nil, {}, {}, {}, {}, {}
local page = 'https://www.bilibili.com/video/BV1234567890/'
local src, cdn, cid, rows = page, false, nil, nil
local props = {path='initial', ['time-pos']=42.8, ['playlist-playing-pos']=0, ['playlist/0/id']=5, pause=false}
local function get(k,d) if props[k]~=nil then return props[k] end;return d end
local mp = {get_property=get,get_property_number=get,get_property_native=get,
    set_property_bool=function(k,v) props[k]=v end, get_opt=function() return cid end,
    add_key_binding=function(_,name,f) assert(name=='resume-webpage');bind=f end,
    register_event=function(name,f) events[name]=f end,
    command_native_async=function(command,cb) fetched[#fetched+1]={command,cb};return #fetched end,
    abort_async_command=function(h) cancelled[h]=true end}
local utils = {join_path=function(a,b)return a..'/'..b end, parse_json=function()return rows end}
local os = {getenv=function()return 'windows' end}
local api=(function()
''' + self.source + r'''
end)()
api.bind(mp,utils,{show=function(msg)messages[#messages+1]=msg end},function()return src,cdn end,
    function(url,kind,cb) assert(kind=='URL');opened[#opened+1]={url,cb};return 100+#opened end)
'''
        self.lua.execute(fixture + case, 'web-resume')

    def test_direct_page_time_and_successful_launch(self):
        self.run_case("""
src=page..'?p=3';bind();bind()
assert(#fetched==0 and #opened==1 and opened[1][1]==page..'?p=3&t=42' and not props.pause)
opened[1][2](true);assert(props.pause)
props.pause=false;props['time-pos']=0;src=page;bind()
assert(opened[2][1]==page..'?t=0');opened[2][2](false);assert(not props.pause)
""")

    def test_part_lookup_uses_matching_cid_and_click_time(self):
        self.run_case("""
cdn=true;cid='33';bind()
assert(#fetched==1 and #opened==0 and fetched[1][1].args[#fetched[1][1].args]=='https://api.bilibili.com/x/player/pagelist?bvid=BV1234567890')
props['time-pos']=48;rows={code=0,data={{cid=11,page=1},{cid=22,page=2},{cid=33,page=3}}}
fetched[1][2](true,{status=0,stdout='fixture'})
assert(opened[1][1]==page..'?p=3&t=42');opened[1][2](true);assert(props.pause)
""")

    def test_unknown_part_stays_in_player_and_single_part_without_cid_works(self):
        self.run_case("""
cdn=true;cid=nil;rows={code=0,data={{cid=11,page=1},{cid=22,page=2}}}
bind();fetched[1][2](true,{status=0,stdout='fixture'})
cid='55';bind();fetched[2][2](true,{status=0,stdout='fixture'})
bind();fetched[3][2](false,nil)
assert(#opened==0 and not props.pause)
cid=nil;rows={code=0,data={{cid=11,page=1}}}
bind();fetched[4][2](true,{status=0,stdout='fixture'});assert(opened[1][1]==page..'?p=1&t=42')
""")

    def test_stale_lookup_and_launch_cannot_affect_new_entry(self):
        self.run_case("""
cdn=true;cid='1';bind();events['end-file']();assert(cancelled[1])
rows={code=0,data={{cid=1,page=1}}};fetched[1][2](true,{status=0,stdout='late'})
assert(#opened==0)
cdn=false;bind();props['playlist/0/id']=6;opened[1][2](true);assert(not props.pause)
bind();events.shutdown();assert(cancelled[102]);opened[2][2](true);assert(not props.pause)
""")

    def test_unavailable_source_and_time(self):
        self.run_case("""
for _,other in ipairs({'https://video.test/stream.mp4','https://www.bilibili.com/bangumi/play/ss1'}) do
    src=other;bind()
end
src=nil;bind();src=page;props['time-pos']=nil;bind()
assert(#fetched==0 and #opened==0 and not props.pause and #messages==4)
""")
