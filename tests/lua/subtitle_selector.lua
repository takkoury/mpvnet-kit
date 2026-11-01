local properties={['input-ime']=false,['cursor-autohide']=1000,['window-dragging']=true,
    ['display-hidpi-scale']=1,['focused']=true,['user-data/mpv/console/open']=false,
    ['mouse-pos']={x=0,y=0,hover=true},['clipboard/text']='English'}
local width,height,time=1280,720,0
local named,sections,enabled,areas,observers,timers,overlays,events={}, {}, {}, {}, {}, {}, {}, {}
local define_count,flush_count,close_count=0,0,0
local submitted,sets={},{}
local fail_property
local defer_focused = false
local function emit(name,value)
    properties[name]=value
    local callbacks={};for _,fn in ipairs(observers[name] or {}) do callbacks[#callbacks+1]=fn end
    for _,fn in ipairs(callbacks) do fn(name,value) end
end
local mp={
    get_script_name=function() return 'subtitle_controls' end,
    get_time=function() return time end,
    get_osd_size=function() return width,height end,
    get_property_native=function(name,default) if properties[name]~=nil then return properties[name] end;return default,'property unavailable' end,
    get_property=function(name,default) if properties[name]~=nil then return tostring(properties[name]) end;return default end,
    set_property_native=function(name,value)
        assert(name~='sid' and name~='sub-visibility' and name~='secondary-sid','UI must not own subtitle properties')
        assert(name~='user-data/mpv/console/open','console state belongs to console')
        sets[#sets+1]={name,value};if name==fail_property then return false end;emit(name,value);return true
    end,
    command_native=function(args)
        assert(args[1]=='escape-ass','no player command or shell operation expected')
        assert(#args==2,'escape-ass must receive exactly one text argument')
        return args[2]:gsub('\n',' '):gsub('{','\\{'):gsub('}','\\}')
    end,
    add_key_binding=function(key,name,fn,flags)
        assert(key==nil,'all actual keys must belong to the exclusive section')
        assert(flags.complex and flags.repeatable,'use actual complex key event API')
        named[name]=fn
    end,
    remove_key_binding=function(name) named[name]=nil end,
    flush_keybindings=function() flush_count=flush_count+1 end,
    set_key_bindings=function(defs,section,flags)
        assert(flags=='force');define_count=define_count+1;sections[section]=defs
        for _,entry in ipairs(defs) do assert(type(entry[2])=='string','no accumulating anonymous dispatch closures') end
    end,
    enable_key_bindings=function(section,flags) assert(flags=='exclusive');enabled[section]=true end,
    disable_key_bindings=function(section) enabled[section]=nil end,
    set_mouse_area=function(x0,y0,x1,y1,section) areas[section]={x0,y0,x1,y1} end,
    observe_property=function(name,kind,fn)
        observers[name]=observers[name] or {};table.insert(observers[name],fn)
        if name~='focused' or not defer_focused then fn(name,properties[name]) end
    end,
    unobserve_property=function(fn)
        for name,list in pairs(observers) do for i=#list,1,-1 do if list[i]==fn then table.remove(list,i) end end end
    end,
    add_periodic_timer=function(interval,fn)
        local timer={callback=fn,live=true,interval=interval};function timer:kill() self.live=false end
        timers[#timers+1]=timer;return timer
    end,
    create_osd_overlay=function(format)
        assert(format=='ass-events')
        local overlay={data='',updates=0,removed=false}
        function overlay:update() assert(not self.removed);self.updates=self.updates+1;return nil end
        function overlay:remove() self.removed=true end
        overlays[#overlays+1]=overlay;return overlay
    end,
    register_event=function(name,fn) events[name]=fn end,
}
package.loaded.mp=mp
local M=(function()
-- MODULE SOURCE
end)()
local function eq(a,b,message) assert(a==b,(message or '')..' expected '..tostring(b)..', got '..tostring(a)) end
local function tracks(count)
    local list={{id=3,title='简体中文',lang='中文',codec='ASS',external=false},
        {id=4,title='繁体中文',lang='中文',codec='ASS',external=false},
        {id=5,title='English',lang='英语',codec='SRT',external=false},
        {id=9,title='A long subtitle filename with songs and translator commentary.ass',lang='中文',codec='ASS',external=true}}
    for i=10,(count or 4)+5 do list[#list+1]={id=i,title='Extra subtitle '..i,lang=i%2==0 and 'English' or '日本語',codec='SRT',external=true} end
    return list
end
local function open(list,current,callback)
    return M.open({tracks=list or tracks(),current_id=current or 3,
        submit=callback or function(id) submitted[#submitted+1]=id;return true end,
        close=function() close_count=close_count+1 end})
end
local function overlay()
    for i=#overlays,1,-1 do if not overlays[i].hidden and not overlays[i].removed then return overlays[i] end end
end
local function data() return overlay() and overlay().data or '' end
local function invoke(key,event)
    for section in pairs(enabled) do for _,binding in ipairs(sections[section]) do
        if binding[1]==key then
            local name=binding[2]:match('/([^/%s]+)$');assert(named[name],'missing active named callback')
            named[name](event or {event='press'});return
        end
    end end
    error('key unavailable '..key)
end
local function text(text,event)
    invoke('any_unicode',{event=event or 'press',key_text=text,key_name='ignored'})
end
local function tick(seconds)
    time=time+seconds
    for _,timer in ipairs(timers) do if timer.live then timer.callback() end end
end
local function idle_resources()
    assert(not M.is_open());assert(next(named)==nil);assert(next(enabled)==nil)
    for _,timer in ipairs(timers) do assert(not timer.live,'timer remains live') end
    for _,layer in ipairs(overlays) do assert(layer.removed,'overlay remains owned') end
    for _,area in pairs(areas) do eq(area[3],0);eq(area[4],0) end
end
local function text_point(needle, title_only)
    for line in data():gmatch('[^\n]+') do
        if line:sub(-#needle)==needle and (not title_only or line:find('\\fs16.00',1,true)) then
            local x,y=line:match('\\pos%(([%d%.%-]+),([%d%.%-]+)%)')
            if x then return tonumber(x),tonumber(y) end
        end
    end
    error('rendered text not found '..needle)
end
local function mouse(x,y,hover)
    properties['mouse-pos']={x=x,y=y,hover=hover~=false};invoke('MOUSE_MOVE')
end

function open_close_repeated_and_temporary_ownership()
    eq(define_count,0);assert(next(named)==nil and #overlays==0)
    assert(open());eq(properties['input-ime'],true);eq(properties['cursor-autohide'],'no');eq(properties['window-dragging'],false)
    assert(data():find('选择普通字幕',1,true));assert(data():find('不显示普通字幕',1,true))
    assert(not data():find('查找字幕',1,true),'focused placeholder must be hidden')
    local count=#overlays
    for _=1,8 do assert(open()) end
    eq(#overlays,count);eq(define_count,1)
    for _,area in pairs(areas) do eq(area[1],0);eq(area[3],width);eq(area[4],height) end
    M.close();M.close();idle_resources();eq(close_count,1)
    eq(properties['input-ime'],false);eq(properties['cursor-autohide'],1000);eq(properties['window-dragging'],true)
    eq(properties['user-data/mpvnet/subtitle-selector/open'],false)
    assert(open());M.close();eq(define_count,1);idle_resources()
end
function unicode_editing_and_ime_events_are_single_channel()
    assert(open())
    text('简体');assert(data():find('简体中文',1,true));assert(not data():find('English',1,true))
    text('重复','up');invoke('any_unicode',{event='press',key_name='E'});invoke('any_unicode',{event='press',key_text='重复',canceled=true})
    assert(data():find('简体中文',1,true));assert(not data():find('重复',1,true))
    invoke('LEFT');invoke('DEL');text('体');invoke('BS')
    assert(data():find('简体中文',1,true));assert(not data():find('繁体中文',1,true))
    invoke('HOME');text('繁');invoke('END');invoke('Ctrl+a');text('English')
    assert(data():find('English',1,true));assert(not data():find('简体中文',1,true))
    invoke('Ctrl+a');text('日😀本');invoke('BS');invoke('LEFT');invoke('DEL')
    invoke('Ctrl+u');invoke('Ctrl+v');invoke('ENTER');eq(submitted[1],5);idle_resources()
end
function keyboard_selection_off_current_and_filtered_empty()
    assert(open(nil,'no'));invoke('DOWN');invoke('ENTER');eq(submitted[1],0);idle_resources()
    assert(open(nil,'3'));invoke('ENTER');eq(submitted[2],3);idle_resources()
    assert(open());text('no match');invoke('ENTER');assert(M.is_open());eq(#submitted,2)
    assert(data():find('没有匹配的字幕',1,true));invoke('DOWN');invoke('ENTER');eq(submitted[3],0)
    assert(open());invoke('UP');invoke('ENTER');eq(submitted[4],9)
end
function errors_refresh_reentrant_submission_and_stale_callback()
    local first=tracks()
    assert(open(first,3,function(id)
        submitted[#submitted+1]=id;M.update({first[3]},5);return false,'该字幕已移除，请重新选择。'
    end))
    text('A long');invoke('ENTER')
    assert(M.is_open());assert(data():find('该字幕已移除，请重新选择。',1,true));assert(not data():find('A long subtitle',1,true))
    invoke('Ctrl+u');assert(open({first[3]},5));invoke('ENTER');eq(submitted[2],5);idle_resources()
    assert(open());local stale;for name,fn in pairs(named) do if name=='subtitle-selector-1' then stale=fn end end
    M.close();assert(open());stale({event='press',key_text='DO_NOT_APPEAR'});assert(not data():find('DO_NOT_APPEAR',1,true));M.close()
    assert(open(nil,3,function() M.close();return true end));invoke('ENTER');idle_resources()
end
function scrolling_mouse_click_hover_and_dynamic_resize()
    assert(open(tracks(30)));local original=data();invoke('WHEEL_DOWN');assert(data()~=original)
    invoke('END');invoke('UP');invoke('PGDWN');assert(M.is_open())
    invoke('Ctrl+f');text('English');local x,y=text_point('English',true);mouse(x+3,y+3);invoke('MBTN_LEFT',{event='down'});invoke('MBTN_LEFT',{event='up'})
    eq(submitted[1],5);idle_resources()
end
function outside_click_cancels_without_submit_or_drag_through()
    assert(open())
    mouse(1,1);invoke('MBTN_LEFT',{event='down'})
    assert(M.is_open(),'keep input captured until release')
    invoke('MBTN_LEFT',{event='up'});idle_resources();eq(#submitted,0)
    eq(properties['user-data/mpvnet/subtitle-selector/status'].detail,'outside-click')
    eq(properties['input-ime'],false);eq(properties['window-dragging'],true)

    assert(open());local x,y=text_point('English',true)
    mouse(x+3,y+3);invoke('MBTN_LEFT',{event='down'})
    mouse(1,1);invoke('MBTN_LEFT',{event='up'})
    assert(M.is_open(),'dragging out must not dismiss or select');eq(#submitted,0)
    mouse(1,1);invoke('MBTN_LEFT',{event='down'})
    mouse(x+3,y+3);invoke('MBTN_LEFT',{event='up'})
    assert(M.is_open(),'press outside and release inside must not select');eq(#submitted,0)
    mouse(1,1);invoke('MBTN_LEFT',{event='down'});invoke('MBTN_LEFT',{event='up',canceled=true})
    assert(M.is_open(),'canceled click must not dismiss')
    local tx,ty=text_point('选择普通字幕')
    mouse(tx+2,ty+2);invoke('MBTN_LEFT');assert(M.is_open(),'blank caption is inside panel')
    mouse(1,1,false);invoke('MBTN_LEFT');assert(M.is_open(),'outside the video is not an overlay click')
    mouse(1,1);invoke('MBTN_LEFT');idle_resources();eq(#submitted,0)
end
function tooltip_and_empty_panel()
    local long='字幕 '..string.rep('完整长标题',18)..'.ass'
    assert(open({{id=7,title=long,lang='中文',codec='ASS',external=true}}))
    invoke('DOWN') -- Stable list focus; cursor blink is independent of tooltip dwell.
    local x,y
    for line in data():gmatch('[^\n]+') do if line:find('…',1,true) then x,y=line:match('\\pos%(([%d%.%-]+),([%d%.%-]+)%)');break end end
    assert(x and y);mouse(tonumber(x)+3,tonumber(y)+3);local before=data();tick(0.54);assert(data()==before)
    tick(0.02);assert(data()~=before,'dwell did not show full title');tick(5.1);local expired=data();tick(1);eq(data(),expired)
    M.close();assert(open({},'no'));text('ignored');assert(data():find('没有普通字幕轨道',1,true));invoke('ENTER');eq(#submitted,0);idle_resources()
end
function fitting_empty_no_match_error_and_language_names()
    for _,size in ipairs({{320,200},{240,140},{100,80}}) do
        width,height=size[1],size[2]
        for _,mode in ipairs({'empty','no-match','error'}) do
            local list=mode=='empty' and {} or tracks()
            assert(open(list,3,function() return false,'该字幕已移除，请重新选择。' end))
            if mode~='empty' then text('unmatched');if mode=='error' then invoke('DOWN');invoke('ENTER') end end
            local first=data():match('([^\n]+)');local path=first:match('}(.-){\\p0}')
            assert(path,'panel ASS drawing missing')
            for x,y in path:gmatch('([%d%.%-]+) ([%d%.%-]+)') do
                x,y=tonumber(x),tonumber(y)
                assert(x>=-0.02 and y>=-0.02 and x<=width+0.02 and y<=height+0.02,'panel escaped OSD in '..mode)
            end
            M.close()
        end
    end
    width,height=1280,720
    assert(open({{id=1,lang='eng',codec='SRT',external=false},{id=2,lang='zh-Hant',codec='ASS',external=true},{id=3,lang='unlisted',external=false}},1))
    assert(data():find('英语',1,true));assert(data():find('繁体中文',1,true));assert(data():find('unlisted',1,true))
    text('繁体中文');invoke('ENTER');eq(submitted[#submitted],2);idle_resources()
end
function console_handoff_and_conditional_restoration()
    assert(open());emit('user-data/mpv/console/open',true);idle_resources()
    eq(properties['input-ime'],true,'do not disable console IME');eq(properties['cursor-autohide'],1000);eq(properties['window-dragging'],true)
    local ok=open();eq(ok,false)
    emit('user-data/mpv/console/open',false);eq(properties['input-ime'],false)
    assert(open());properties['cursor-autohide']=3000;properties['window-dragging']=true;properties['input-ime']=false
    M.close();eq(properties['cursor-autohide'],3000);eq(properties['window-dragging'],true);eq(properties['input-ime'],false)
    assert(open());emit('focused',false);idle_resources()
    emit('focused',true);assert(open());events.shutdown();idle_resources();eq(open(),false)
end
function failed_open_and_zero_osd_restore()
    fail_property='window-dragging';eq(open(),false);idle_resources();eq(properties['input-ime'],false);eq(properties['cursor-autohide'],1000)
    fail_property=nil;assert(open());local visible=data();width,height=0,0;emit('osd-dimensions',{w=0,h=0});eq(data(),'')
    width,height=320,240;emit('osd-dimensions',{w=width,h=height});assert(data()~='' and data()~=visible)
    for _,area in pairs(areas) do eq(area[3],320);eq(area[4],240) end
    M.close();properties.focused=false;assert(open());assert(M.is_open());M.close();idle_resources()
end
function missing_optional_property_error_does_not_become_number_base()
    properties['display-hidpi-scale']=nil
    assert(open(),'optional missing property must use first fallback return only')
    assert(data():find('选择普通字幕',1,true));invoke('ESC');idle_resources()
end
function thumb_drag_cancel_and_media_close_do_not_submit()
    assert(open(tracks(30)))
    local sx,sy
    for line in data():gmatch('[^\n]+') do
        if line:find('\\1c&H707070&',1,true) then sx,sy=line:match('}m ([%d%.%-]+) ([%d%.%-]+)');break end
    end
    assert(sx and sy,'scroll thumb drawing missing')
    mouse(tonumber(sx),tonumber(sy)+2);invoke('MBTN_LEFT',{event='down'})
    mouse(tonumber(sx),height-20);invoke('MBTN_LEFT',{event='up'})
    assert(data():find('Extra subtitle 35',1,true),'drag did not reach final track')
    eq(#submitted,0)
    -- The controller calls this at start-file; queued callbacks from the old
    -- input session must not apply a row in the replacement media's panel.
    local old
    for _,defs in pairs(sections) do for _,binding in ipairs(defs) do if binding[1]=='MBTN_LEFT' then old=named[binding[2]:match('/([^/%s]+)$')] end end end
    M.close();idle_resources();eq(properties['input-ime'],false)
    assert(open({{id=100,title='Replacement media subtitle',lang='eng',codec='SRT',external=false}},100))
    old({event='up'});eq(#submitted,0);assert(M.is_open());invoke('ESC');idle_resources()
end
function initial_unfocused_notification_requires_a_prior_true_before_close()
    properties.focused=false
    assert(open(),'an initially unfocused embedded VO must still show the selector')
    emit('focused',false);assert(M.is_open(),'initial/repeated false is not a focus-loss transition')
    emit('focused',true);assert(M.is_open())
    emit('focused',false);idle_resources()
    eq(properties['input-ime'],false);eq(properties['cursor-autohide'],1000);eq(properties['window-dragging'],true)

    -- mpv delivers initial observations on its event queue, after open returns.
    -- Match the reported embedded-window failure without relying on a GUI.
    defer_focused=true;properties.focused=false
    assert(open());assert(M.is_open())
    emit('focused',false);assert(M.is_open(),'deferred first false must not silently remove the overlay')
    emit('focused',true);emit('focused',false);idle_resources()
end
function invalid_hidpi_values_use_visible_unit_scale()
    for _,value in ipairs({0,-1,0/0,math.huge,-math.huge}) do
        properties['display-hidpi-scale']=value
        assert(open(),'invalid DPI should use 1 instead of failing to open')
        local layer=overlay();assert(layer and layer.res_x==width and layer.res_y==height)
        local first=assert(data():match('([^\n]+)'));local path=assert(first:match('}(.-){\\p0}'))
        local left,top,right,bottom=math.huge,math.huge,-math.huge,-math.huge
        for x,y in path:gmatch('([%d%.%-]+) ([%d%.%-]+)') do
            x,y=tonumber(x),tonumber(y);left=math.min(left,x);right=math.max(right,x);top=math.min(top,y);bottom=math.max(bottom,y)
        end
        assert(math.abs((right-left)-440)<0.02,'invalid DPI collapsed or enlarged the visible panel')
        assert(bottom-top>200 and left>=0 and top>=0 and right<=width and bottom<=height,'invalid DPI produced an invisible/out-of-frame panel')
        assert(not data():lower():find('nan',1,true) and not data():lower():find('inf',1,true),'non-finite geometry leaked into ASS')
        M.close();idle_resources()
    end
end
function metadata_columns_and_id_edges_stay_aligned()
    local list={{id=1,title='First',lang='zh-Hant',codec='subrip',external=false},
        {id=12,title='Second',lang='en',codec='ASS',external=true},
        {id=123,title='Third',lang='',codec='hdmv_pgs_subtitle',external=false}}
    assert(open(list,1))
    local first=text_point('subrip');local second=text_point('ASS');local third
    for line in data():gmatch('[^\n]+') do
        if line:find('hdmv',1,true) then
            third=tonumber(line:match('\\pos%(([%d%.%-]+),'))
            assert(line:find('…',1,true),'long codec should be elided within its column')
        end
    end
    eq(first,second,'codec centers differ');eq(first,third,'long codec must keep column center')
    local right=text_point('#1');eq(right,text_point('#12'));eq(right,text_point('#123'))
    for line in data():gmatch('[^\n]+') do
        if line:match('#%d+$') then assert(line:find('\\an9',1,true),'IDs must use actual right anchor') end
    end
    text('Second');eq(text_point('ASS'),first,'filtering must not shift columns')
    invoke('ESC');idle_resources()
end
function export_ass(output)
    local list=tracks(12)
    local function save(name,w,h,items,keyboard_focus)
        width,height=w,h;assert(open(items or list,3))
        if keyboard_focus then invoke('DOWN');invoke('DOWN') end
        local layer=overlay();local raw=layer.data
        local file=assert(io.open(output..'/'..name..'.overlay.txt','wb'));file:write(raw);file:close()
        file=assert(io.open(output..'/'..name..'.ass','wb'))
        file:write('[Script Info]\nScriptType: v4.00+\nPlayResX: '..layer.res_x..'\nPlayResY: '..layer.res_y..'\nWrapStyle: 2\nScaledBorderAndShadow: yes\n\n[V4+ Styles]\nFormat: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\nStyle: Default,Microsoft YaHei UI,14,&H00FFFFFF,&H00FFFFFF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,7,0,0,0,1\n\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n')
        for event in raw:gmatch('[^\n]+') do file:write('Dialogue: 0,0:00:00.00,0:00:10.00,Default,,0,0,0,,',event,'\n') end
        file:close();file=assert(io.open(output..'/'..name..'.size.txt','wb'));file:write(layer.res_x..' '..layer.res_y);file:close();M.close()
    end
    save('normal',1280,720);save('narrow',320,240)
    local long=tracks(12);long[1].title='山间的一天 — 简体中文与日语双语字幕（校对版，含歌曲与注释）.ass'
    save('current-long-title',1280,720,long)
    properties['display-hidpi-scale']=1.5
    save('feedback-size',1469,826,tracks())
    save('keyboard-focus',1469,826,tracks(),true)
    save('mixed-columns',1469,826,{
        {id=1,title='简体中文',lang='zh',codec='subrip',external=false},
        {id=12,title='English',lang='en',codec='ASS',external=true},
        {id=123,title='日本語',lang='ja',codec='hdmv_pgs_subtitle',external=false},
        {id=321,title='繁体中文字幕',lang='zh-Hant',codec='subrip',external=false}},true)
end
