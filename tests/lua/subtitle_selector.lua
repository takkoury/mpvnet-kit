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
    eq(properties['user-data/mpvnet/track-selector/open'],false)
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
    assert(open());local stale;for name,fn in pairs(named) do if name=='track-selector-1' then stale=fn end end
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
    eq(properties['user-data/mpvnet/track-selector/status'].detail,'outside-click')
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
function audio_layout_details_and_single_input_owner()
    local list={{id=1,title='普通话',lang='zh',codec='aac',external=false,['demux-channel-count']=2,['demux-samplerate']=48000,['demux-bitrate']=192000,default=true},
        {id=123,title='English',lang='en',codec='eac3',external=true,['demux-channel-count']=6,['codec-profile']='Atmos',['visual-impaired']=true},
        {id=9,title='',lang='',codec='',external=false,['demux-channel-count']=0,['demux-samplerate']=0/0}}
    assert(M.open({kind='audio',tracks=list,current_id=1,submit=function(id) submitted[#submitted+1]=id;return true end}))
    assert(data():find('选择音轨',1,true));assert(data():find('关闭音轨',1,true))
    assert(data():find('2 声道',1,true));assert(data():find('6 声道',1,true));assert(data():find('音轨 #9',1,true))
    assert(not data():find('0 声道',1,true));assert(not data():find('192 kbps',1,true),'extra details should stay hidden initially')
    local dividers={}
    for line in data():gmatch('[^\n]+') do
        if line:find('\\1c&H555555&',1,true) then
            local x,y=line:match('}m ([%d%.%-]+) ([%d%.%-]+)');dividers[#dividers+1]={tonumber(x),tonumber(y)}
        end
    end
    eq(#dividers,9)
    for row=1,2 do for col=1,3 do eq(dividers[row*3+col][1],dividers[col][1],'cross-row separator drift') end end
    eq(text_point('中文'),text_point('普通话',true),'metadata must start at title edge')
    eq(text_point('aac'),(dividers[1][1]+1+dividers[2][1])/2,'codec center between dividers')
    eq(text_point('2 声道'),(dividers[2][1]+1+dividers[3][1])/2,'channel center between dividers')
    eq(text_point('内嵌')-dividers[3][1],9,'source left gutter')
    assert(dividers[3][1]-text_point('中文')<150,'columns spread across the panel')
    invoke('DOWN');invoke('DOWN');tick(.6)
    assert(data():find('采样率  48 kHz',1,true));assert(data():find('码率  192 kbps',1,true));assert(data():find('默认',1,true))
    invoke('Ctrl+f');text('视障');invoke('ENTER');eq(submitted[1],123);idle_resources()
    assert(open());local stale=named['track-selector-1']
    assert(M.open({kind='audio',tracks=list,current_id=1,submit=function() return true end}))
    stale({event='press',key_text='stale query'});assert(not data():find('stale query',1,true))
    local sections_count=0;for _ in pairs(enabled) do sections_count=sections_count+1 end;eq(sections_count,1)
    eq(properties['user-data/mpvnet/track-selector/status'].kind,'audio')
    M.close();idle_resources();eq(properties['input-ime'],false)
end
function audio_details_are_canceled_when_keyboard_focus_leaves_row()
    for _,action in ipairs({'Ctrl+f','Ctrl+a','TAB'}) do
        for _,shown in ipairs({false,true}) do
            assert(M.open({kind='audio',tracks={{id=1,title='Audio',codec='aac',['demux-samplerate']=48000}},current_id=1,submit=function() return true end}))
            invoke('DOWN');invoke('DOWN')
            if shown then tick(.6);assert(data():find('采样率  48 kHz',1,true)) end
            invoke(action);tick(.6)
            assert(not data():find('采样率  48 kHz',1,true),'details outlived focus: '..action)
            M.close();idle_resources()
        end
    end
end
function subtitle_and_audio_share_layout_geometry()
    local function signature()
        local s
        for i=1,10 do local name,value=debug.getupvalue(M.is_open,i);if name=='active' then s=value;break end end
        assert(s and s.layout)
        local l=s.layout;local values={s.capacity}
        local function append(r) for _,k in ipairs({'x','y','w','h'}) do values[#values+1]=r[k] end end
        append(l.panel);append(l.close);append(l.search)
        for _,r in ipairs(l.rows) do append(r) end
        local nx,ny=text_point('简体中文');values[#values+1]=nx;values[#values+1]=ny
        local ix,iy=text_point('#3');values[#values+1]=ix;values[#values+1]=iy
        local fx,fy=text_point('↑ ↓ 移动　Enter 选择　Esc 取消');values[#values+1]=fx;values[#values+1]=fy
        return table.concat(values,',')
    end
    for _,dpi in ipairs({1,1.5,2}) do
        for _,size in ipairs({{1469,826},{480,320}}) do
            width,height=size[1],size[2];properties['display-hidpi-scale']=dpi
            local list=tracks()
            assert(open(list,3));local before=signature();M.close()
            assert(M.open({kind='audio',tracks=list,current_id=3,submit=function() return true end}))
            eq(signature(),before,'subtitle/audio geometry drift');M.close();idle_resources()
        end
    end
end
function chapter_single_rows_search_navigation_and_no_off_action()
    local list={{id=2,title='Intro',time_text='00:01:30'},
        {id=3,title='山路与回声',time_text='00:20:40'},{id=12,title='',time_text='01:12:00'}}
    local function chapter_open()
        return M.open({kind='chapter',tracks=list,current_id=3,submit=function(id) submitted[#submitted+1]=id;return true end})
    end
    assert(chapter_open());assert(data():find('选择章节',1,true));assert(data():find('章节 12',1,true))
    assert(not data():find('关闭音轨',1,true) and not data():find('不显示普通字幕',1,true))
    invoke('DOWN');invoke('ENTER');eq(submitted[1],2);idle_resources()
    assert(chapter_open());invoke('UP');invoke('HOME');invoke('END');invoke('ENTER');eq(submitted[2],12)
    assert(chapter_open());text('20:40');invoke('ENTER');eq(submitted[3],3)
    assert(chapter_open());text('unmatched');invoke('DOWN');invoke('ENTER');eq(#submitted,3);assert(M.is_open())
    invoke('TAB');invoke('ENTER');idle_resources()
    assert(M.open({kind='chapter',tracks={},current_id=0,submit=function() error('empty cannot submit') end}))
    assert(data():find('没有可用章节',1,true));invoke('ENTER');idle_resources()
end
function device_rows_notice_identifier_search_and_tooltip()
    local list={{id=2,title='自动选择',device_name='auto'},
        {id=8,title='耳机',detail_title='耳机原始名称',device_name='wasapi/{abcdef}'}}
    assert(M.open({kind='device',tracks=list,current_id=0,notice='已选设备不在列表中，可重新选择。',submit=function(id) submitted[#submitted+1]=id;return true end}))
    assert(data():find('选择音频设备',1,true));assert(data():find('已选设备不在列表中',1,true))
    assert(not data():find('关闭音轨',1,true) and not data():find('不显示普通字幕',1,true))
    assert(not data():find('#8',1,true),'device should not display synthetic numeric IDs')
    invoke('DOWN');tick(.6);assert(data():find('不固定某个设备',1,true))
    invoke('DOWN');tick(.6);assert(data():find('耳机原始名称',1,true));assert(data():find('wasapi/',1,true))
    invoke('Ctrl+f');text('abcdef');invoke('ENTER');eq(submitted[1],8);idle_resources()
    assert(M.open({kind='device',tracks=list,current_id=2,submit=function(id) submitted[#submitted+1]=id;return true end}))
    invoke('DOWN');invoke('ENTER');eq(submitted[2],2,'current selection must remain same positive ID')
    assert(M.open({kind='device',tracks=list,current_id=0,notice='已选设备不在列表中，可重新选择。',submit=function() return true end}))
    M.update(list,2,'');assert(not data():find('已选设备不在列表中',1,true));M.close()
    assert(M.open({kind='device',tracks={},current_id=0,submit=function() error('no device cannot submit') end}))
    assert(data():find('没有可用音频设备',1,true));invoke('ENTER');idle_resources()
end
function video_metadata_image_fallback_search_and_shared_geometry()
    local list={{id=1,title='主画面',codec='hevc',external=false,['demux-w']=3840,['demux-h']=2160,['demux-fps']=23.976,['demux-bitrate']=18000000},
        {id=12,title='',codec='h264',lang='en',external=true,['demux-w']=1920,['demux-h']=1080,['demux-fps']=25},
        {id=123,title='封面',codec='mjpeg',image=true,albumart=true,['demux-w']=1200,['demux-h']=1200,['demux-fps']=1000},
        {id=321,title='Missing',codec='',external=false,['demux-w']=0,['demux-h']=0,['demux-fps']=0/0}}
    local function video_open()
        return M.open({kind='video',tracks=list,current_id=1,submit=function(id) submitted[#submitted+1]=id;return true end})
    end
    assert(video_open());assert(data():find('选择视频轨',1,true));assert(data():find('关闭视频画面',1,true))
    assert(data():find('3840×2160',1,true));assert(data():find('25 fps',1,true))
    assert(data():find('视频轨道 #12',1,true));assert(data():find('封面图',1,true))
    assert(not data():find('1000 fps',1,true) and not data():find('0×0',1,true))
    local separators={}
    for line in data():gmatch('[^\n]+') do
        if line:find('\\1c&H555555&',1,true) then
            local x=line:match('}m ([%d%.%-]+) ');separators[#separators+1]=tonumber(x)
        end
    end
    eq(#separators,12)
    for row=0,3 do
        local offset=row*3
        eq(separators[offset+2]-separators[offset+1],separators[offset+3]-separators[offset+2],'video interior columns differ')
        for col=1,3 do eq(separators[offset+col],separators[col],'video divider row alignment') end
    end
    eq(text_point('hevc'),(separators[1]+1+separators[2])/2)
    eq(text_point('25 fps'),(separators[2]+1+separators[3])/2)
    eq(text_point('3840×2160'),separators[1]-8-40,'resolution must be centered in its column')
    eq(text_point('内嵌'),separators[3]+9+26,'source must be centered in its column')
    eq(separators[2]-separators[1],73,'interior column spacing must remain compact')
    local snapshot=data();local first_geometry=snapshot:match('([^\n]+)')
    invoke('DOWN');invoke('DOWN');tick(.6);assert(data():find('码率  18000 kbps',1,true))
    invoke('Ctrl+f');text('1080');invoke('ENTER');eq(submitted[1],12);idle_resources()
    assert(video_open());invoke('DOWN');invoke('ENTER');eq(submitted[2],0)
    assert(video_open());invoke('ENTER');eq(submitted[3],1)
    assert(M.open({kind='audio',tracks=list,current_id=1,submit=function() return true end}))
    eq(data():match('([^\n]+)'),first_geometry,'video and audio panel extents must match')
    M.close();idle_resources()
end
function edition_selection_has_numbers_but_no_off_or_single_choice()
    local list={{id=1,title='影院版',number_text='1'},{id=2,title='版本 8',number_text='8'}}
    local function open_editions(items)
        return M.open({kind='edition',tracks=items,current_id=1,submit=function(id) submitted[#submitted+1]=id;return true end})
    end
    assert(open_editions(list));assert(data():find('选择媒体版本',1,true));assert(data():find('2 个版本',1,true))
    assert(not data():find('关闭视频画面',1,true));local positions={}
    for line in data():gmatch('[^\n]+') do
        if line:find('\\an6',1,true) then positions[#positions+1]=line:match('\\pos%(([%d%.%-]+),') end
    end
    eq(#positions,2);eq(positions[1],positions[2])
    invoke('DOWN');invoke('ENTER');eq(submitted[1],1);idle_resources()
    assert(open_editions(list));text('8');invoke('ENTER');eq(submitted[2],2)
    assert(open_editions({list[1]}));assert(data():find('当前媒体只有一个版本',1,true))
    invoke('DOWN');text('ignored');assert(not data():find('ignored',1,true));invoke('ENTER');eq(#submitted,2);idle_resources()
    assert(open_editions({}));assert(data():find('没有可用的媒体版本',1,true));invoke('ESC');idle_resources()
end
function advanced_subtitle_blocked_rows_and_target_slot_layout()
    local list={{id=1,title='简体中文',lang='zh',codec='subrip',external=false,slot_label='已用于主字幕',blocked_reason='该轨道已用于主字幕，不能同时用于次字幕。'},
        {id=2,title='English',lang='en',codec='ass',external=false},{id=9,title='Bilibili Danmaku',codec='ass',external=true}}
    local function show()
        return M.open({kind='secondary',tracks=list,current_id=2,notice='次字幕槽正用于弹幕，改选可能影响弹幕。',submit=function(id) submitted[#submitted+1]=id;return true end})
    end
    assert(show());assert(data():find('选择次字幕轨',1,true));assert(data():find('已用于主字幕',1,true));assert(data():find('Bilibili Danmaku',1,true))
    invoke('DOWN');invoke('DOWN');invoke('ENTER');eq(#submitted,0);assert(M.is_open());assert(data():find('不能同时用于次字幕',1,true))
    invoke('Ctrl+f');text('简体');invoke('ENTER');eq(#submitted,0);assert(M.is_open(),'search must not submit only blocked match')
    invoke('Ctrl+u');invoke('ENTER');eq(submitted[1],2);idle_resources()
    assert(show());invoke('DOWN');invoke('ENTER');eq(submitted[2],0);idle_resources()
    assert(show());local unblocked={{id=1,title='简体中文',lang='zh',codec='subrip',external=false}}
    M.update(unblocked,0,'');invoke('ENTER');eq(submitted[3],1);idle_resources()
    assert(M.open({kind='primary',tracks=unblocked,current_id=1,submit=function(id) submitted[#submitted+1]=id;return true end}))
    assert(data():find('选择主字幕轨',1,true));assert(data():find('不使用主字幕',1,true));invoke('ESC');idle_resources()
end
function export_ass(output)
    local list=tracks(12)
    local function save(name,w,h,items,keyboard_focus,kind)
        width,height=w,h
        assert(M.open({kind=kind,tracks=items or list,current_id=3,submit=function() return true end}))
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
    save('audio',1469,826,{
        {id=3,title='普通话',lang='zh',codec='aac',external=false,['demux-channel-count']=2},
        {id=12,title='English',lang='en',codec='eac3',external=false,['demux-channel-count']=6},
        {id=123,title='导演评论音轨',lang='ja',codec='flac',external=true,['demux-channel-count']=2},
        {id=321,title='',lang='',codec='',external=false}},false,'audio')
    local comparison={
        {id=3,title='中文轨道',lang='zh',codec='aac',external=false,['demux-channel-count']=2},
        {id=12,title='English',lang='en',codec='flac',external=false,['demux-channel-count']=6},
        {id=123,title='日本語',lang='ja',codec='eac3',external=true,['demux-channel-count']=1}}
    save('compare-audio',1469,826,comparison,false,'audio')
    comparison[1].codec='subrip';comparison[2].codec='ass';comparison[3].codec='subrip'
    save('compare-subtitle',1469,826,comparison,false,'subtitle')
    save('device',1469,826,{
        {id=3,title='自动选择',device_name='auto'},
        {id=4,title='扬声器（Realtek(R) Audio）',device_name='wasapi/{demo-speakers}'},
        {id=5,title='耳机（USB Audio Device）',device_name='wasapi/{demo-headset}'},
        {id=6,title='显示器音频（NVIDIA High Definition Audio）',device_name='wasapi/{demo-display}'}},false,'device')
    save('video',1469,826,{
        {id=3,title='主画面',codec='hevc',external=false,['demux-w']=3840,['demux-h']=2160,['demux-fps']=23.976},
        {id=12,title='备用机位',codec='h264',external=false,['demux-w']=1920,['demux-h']=1080,['demux-fps']=25},
        {id=123,title='解说画面',codec='h264',external=true,['demux-w']=1280,['demux-h']=720,['demux-fps']=29.97}},false,'video')
    save('edition',1469,826,{{id=3,title='影院版',number_text='1'},{id=4,title='加长版',number_text='2'}},false,'edition')
    save('secondary',1469,826,{
        {id=1,title='简体中文',lang='zh',codec='subrip',external=false,slot_label='已用于主字幕',blocked_reason='该轨道已用于主字幕，不能同时用于次字幕。'},
        {id=3,title='English',lang='en',codec='ass',external=false},
        {id=9,title='Bilibili Danmaku',codec='ass',external=true}},false,'secondary')
end

local function active_state()
    for i=1,10 do local name,value=debug.getupvalue(M.is_open,i);if name=='active' then return value end end
end
local function dense_tracks()
    local list={}
    for group,kind in ipairs({'video','audio','primary'}) do
        for id=1,12 do
            list[#list+1]={id=(group-1)*12+id,number_text=tostring(id),display_kind=kind,
                title=({video='画面 ',audio='音轨 ',primary='字幕 '})[kind]..id,
                current=id==2,lang='zh',codec=kind=='video' and 'h264' or kind=='audio' and 'aac' or 'subrip',external=false,
                ['demux-channel-count']=2,['demux-w']=1920,['demux-h']=1080,['demux-fps']=24,
                blocked_reason=(group==3 and id==3) and '该轨道已用于次字幕。' or '',
                slot_label=(group==3 and id==3) and '已用于次字幕' or ''}
        end
    end
    return list
end
function all_tracks_groups_filters_and_contained_scrolling()
    local list=dense_tracks()
    assert(M.open({kind='all',tracks=list,submit=function(id) submitted[#submitted+1]=id;return true end}))
    local s=active_state();eq(#s.matches,36);eq(s.viewport,340)
    local fixed=s.layout.search.y;local panel=s.layout.panel.h
    assert(not data():find('关闭视频画面',1,true));assert(data():find('画面 2',1,true))
    invoke('WHEEL_DOWN');eq(s.scroll,162);eq(s.layout.search.y,fixed);eq(s.layout.panel.h,panel)
    assert(s.layout.group_header and s.layout.group_header.h==28)
    local header=s.layout.group_header
    mouse(header.x+100,header.y+10);invoke('MBTN_LEFT');eq(#submitted,0,'sticky header is not selectable')
    invoke('TAB');eq(s.focus,'filter');invoke('RIGHT');eq(s.filter,'video');eq(s.scroll,0);eq(#s.matches,12)
    invoke('RIGHT');eq(s.filter,'audio');eq(#s.matches,12);assert(data():find('音轨 1',1,true));assert(not data():find('画面 1',1,true))
    invoke('TAB');invoke('END');eq(s.focus_id,24);assert(s.scroll>0);assert(data():find('音轨 12',1,true))
    local last=s.layout.rows[#s.layout.rows];assert(last.y+last.h<=s.layout.panel.y+s.layout.panel.h-34)
    invoke('Ctrl+f');text('音轨 2');eq(s.scroll,0);eq(#s.matches,1);eq(s.matches[1].id,14)
    invoke('ENTER');eq(submitted[1],14);idle_resources()
    assert(M.open({kind='all',tracks=list,submit=function() return true end}));s=active_state()
    eq(s.filter,'all');eq(s.scroll,0);eq(#s.matches,36);M.close();idle_resources()
end
function all_tracks_markers_occupancy_thumb_and_small_viewports()
    for _,dpi in ipairs({1,1.5,2}) do
        for _,size in ipairs({{1469,826},{480,320}}) do
            width,height=size[1],size[2];properties['display-hidpi-scale']=dpi
            assert(M.open({kind='all',tracks=dense_tracks(),submit=function(id) submitted[#submitted+1]=id;return true end}))
            local s=active_state();local l=s.layout
            assert(l.panel.x>=0 and l.panel.y>=0 and l.panel.y+l.panel.h<=height)
            invoke('TAB');invoke('RIGHT');invoke('RIGHT');invoke('RIGHT');eq(s.filter,'primary')
            invoke('TAB');invoke('DOWN');eq(s.focus_id,26)
            local current_line
            for line in data():gmatch('[^\n]+') do if line:sub(-#'字幕 2')=='字幕 2' then current_line=line end end
            assert(current_line and current_line:find('\\b1',1,true),'per-type current must be bold')
            invoke('DOWN');eq(s.focus_id,27);invoke('ENTER');eq(#submitted,0);assert(data():find('该轨道已用于次字幕。',1,true))
            local thumb=s.layout.thumb;assert(thumb)
            mouse(thumb.x+thumb.w/2,thumb.y+thumb.h/2);invoke('MBTN_LEFT',{event='down'})
            local bar=s.layout.scrollbar;mouse(thumb.x+thumb.w/2,bar.y+bar.h);invoke('MBTN_LEFT',{event='up'})
            eq(s.scroll,s.max_scroll);eq(#submitted,0)
            M.update({},0);assert(M.is_open());eq(s.scroll,0);M.close();idle_resources()
        end
    end
end

function export_all_ass(output)
    width,height=1469,826;properties['display-hidpi-scale']=1.5
    local function save(name)
        local layer=overlay();local raw=layer.data
        local file=assert(io.open(output..'/'..name..'.overlay.txt','wb'));file:write(raw);file:close()
        file=assert(io.open(output..'/'..name..'.ass','wb'))
        file:write('[Script Info]\nScriptType: v4.00+\nPlayResX: '..layer.res_x..'\nPlayResY: '..layer.res_y..'\nWrapStyle: 2\nScaledBorderAndShadow: yes\n\n[V4+ Styles]\nFormat: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\nStyle: Default,Microsoft YaHei UI,14,&H00FFFFFF,&H00FFFFFF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,7,0,0,0,1\n\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n')
        for event in raw:gmatch('[^\n]+') do file:write('Dialogue: 0,0:00:00.00,0:00:10.00,Default,,0,0,0,,',event,'\n') end
        file:close();file=assert(io.open(output..'/'..name..'.size.txt','wb'));file:write(layer.res_x..' '..layer.res_y);file:close()
    end
    assert(M.open({kind='all',tracks=dense_tracks(),submit=function() return false end}))
    save('all-dense')
    for i=1,9 do invoke('WHEEL_DOWN') end
    save('all-scrolled')
    invoke('TAB');invoke('RIGHT');invoke('RIGHT');save('all-audio')
    M.close()
end
