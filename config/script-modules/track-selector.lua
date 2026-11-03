-- Shared subtitle/audio/chapter picker. Rendering and temporary input only; the caller owns
-- selection, media generations and item discovery. Input APIs match mpv's console,
-- but this editor uses its own character-array state (no console implementation).
local mp = require('mp')
local M = {}
local active, pending_ime, observing_console, shutting_down
local section = 'mpvnet-track-selector-' .. mp.get_script_name()
local published = 'user-data/mpvnet/track-selector/open'
local defined = false
local panel_width, title_size, search_size, meta_size = 440, 16, 14, 12
local render, mouse_move, mouse_button, mouse_leave, wheel, key, console_changed
local profiles={
    subtitle={title='选择普通字幕',search='查找字幕',off='不显示普通字幕',fallback='字幕轨道 #',
        empty='没有普通字幕轨道',hint='加载字幕文件后再选择。',nomatch='没有匹配的字幕',failed='无法应用字幕，请重新选择。'},
    audio={title='选择音轨',search='查找音轨',off='关闭音轨',fallback='音轨 #',
        empty='没有可用音轨',hint='此媒体没有可选择的音轨。',nomatch='没有匹配的音轨',failed='无法切换音轨，请重新选择。'},
    chapter={title='选择章节',search='查找章节',fallback='章节 ',
        empty='没有可用章节',hint='此媒体没有章节信息。',nomatch='没有匹配的章节',failed='未能跳转到该章节，请重试。'},
}

local function native(name, default)
    local value = mp.get_property_native(name, default)
    return value
end
local function set(name, value) return mp.set_property_native(name, value) end
local function now() return mp.get_time() end
local function clamp(value, low, high) return math.max(low, math.min(high, value)) end
local function chars(text)
    local out, pos = {}, 1
    text = tostring(text or '')
    while pos <= #text do
        local byte = text:byte(pos)
        local length = byte < 128 and 1 or byte >= 194 and byte < 224 and 2 or byte < 240 and byte >= 224 and 3 or byte >= 240 and byte < 245 and 4 or 1
        for i = 1, length - 1 do
            local b = text:byte(pos + i)
            if not b or b < 128 or b > 191 then length = 1; break end
        end
        out[#out + 1] = text:sub(pos, pos + length - 1); pos = pos + length
    end
    return out
end
local function clean(text)
    local value=tostring(text or ''):gsub('[%z\1-\31\127]', ' ')
    return value
end
local function escape(text)
    local value,err=mp.command_native({'escape-ass', clean(text)})
    if type(value)~='string' then error('ASS text escaping failed: '..tostring(err)) end
    return value
end
local function ass_color(rgb) return rgb:sub(5,6) .. rgb:sub(3,4) .. rgb:sub(1,2) end
local function positive(value)
    return type(value)=='number' and value>0 and value<math.huge and value or nil
end
local function normalize(tracks)
    local out, seen = {}, {}
    for _, track in ipairs(type(tracks) == 'table' and tracks or {}) do
        local id = type(track) == 'table' and track.id
        if type(id) == 'number' and id > 0 and id < math.huge and id == math.floor(id) and not seen[id] then
            seen[id] = true
            out[#out + 1] = {id=id, title=type(track.title)=='string' and track.title or '',
                time_text=type(track.time_text)=='string' and track.time_text or '',
                lang=type(track.lang)=='string' and track.lang or '', codec=type(track.codec)=='string' and track.codec or '', external=track.external,
                channels=positive(track['demux-channel-count']),rate=positive(track['demux-samplerate']),
                bitrate=positive(track['demux-bitrate']) or positive(track['hls-bitrate']),
                profile=type(track['codec-profile'])=='string' and track['codec-profile'] or '',
                default=track.default==true,forced=track.forced==true,dependent=track.dependent==true,
                visual_impaired=track['visual-impaired']==true,hearing_impaired=track['hearing-impaired']==true}
        end
    end
    return out
end
local function current_id(id) return id == 'no' and 0 or tonumber(id) or 0 end
local language_names={zh='中文',chi='中文',zho='中文',['zh-hans']='简体中文',['zh-hant']='繁体中文',ja='日语',jpn='日语',en='英语',eng='英语'}
local function language(track) return language_names[track.lang:lower():gsub('_','-')] or clean(track.lang) end
local function label(track,kind)
    if track.title~='' then return clean(track.title) end
    if track.lang~='' then return language(track) end
    return profiles[kind or 'subtitle'].fallback .. tostring(track.id)
end
local function source(track)
    return track.external==true and '外挂' or track.external==false and '内嵌' or '来源未标注'
end
local function audio_details(track)
    local fields={}
    local function add(name,value) if value and value~='' then fields[#fields+1]=name..'  '..value end end
    add('语言',language(track));add('格式',track.codec);add('配置',track.profile)
    add('声道',track.channels and string.format('%g 声道',track.channels))
    add('采样率',track.rate and string.format('%g kHz',track.rate/1000))
    add('码率',track.bitrate and string.format('%.0f kbps',track.bitrate/1000))
    add('来源',source(track))
    local flags={}
    for _,item in ipairs({{'default','默认'},{'forced','强制'},{'dependent','依赖轨道'},
        {'visual_impaired','视障描述'},{'hearing_impaired','听障辅助'}}) do
        if track[item[1]] then flags[#flags+1]=item[2] end
    end
    add('标记',table.concat(flags,' / '))
    return fields
end
local function dimensions()
    local w, h = mp.get_osd_size()
    return math.max(0,tonumber(w) or 0), math.max(0,tonumber(h) or 0)
end
local function status(phase, detail)
    local w,h=dimensions()
    pcall(set,'user-data/mpvnet/track-selector/status',{
        phase=phase,detail=tostring(detail or ''),width=w,height=h,
        kind=active and active.kind or '',
        dpi=tostring(native('display-hidpi-scale','unavailable')),focused=native('focused'),
    })
end
local function position()
    local mouse = native('mouse-pos', {}) or {}
    return tonumber(mouse.x) or -1, tonumber(mouse.y) or -1, mouse.hover ~= false
end
local function contains(rect, x, y)
    return rect and x >= rect.x and y >= rect.y and x < rect.x + rect.w and y < rect.y + rect.h
end
local function query(s) return table.concat(s.chars) end
local function filtered(s)
    local result, needle = {}, query(s):lower()
    for _, track in ipairs(s.tracks) do
        local haystack = table.concat({label(track,s.kind), language(track), track.lang, track.codec, source(track), tostring(track.id),
            s.kind=='audio' and table.concat(audio_details(track),' ') or '',track.time_text}, ' '):lower()
        if needle == '' or haystack:find(needle, 1, true) then result[#result + 1] = track end
    end
    return result
end
local function measure(s, text, size, bold)
    local cache_key = tostring(size) .. ':' .. tostring(bold==true) .. ':' .. text
    if s.widths[cache_key] then return s.widths[cache_key] end
    local w, h = dimensions()
    s.measure.res_x, s.measure.res_y = math.max(1,w), math.max(1,h)
    s.measure.data = string.format('{\\an7\\pos(0,0)\\bord0\\shad0\\fnMicrosoft YaHei UI\\fs%.2f\\b%d}%s', size,bold and 1 or 0,escape(text))
    local bounds = s.measure:update()
    local width
    if type(bounds) == 'table' and bounds.x0 and bounds.x1 then width = math.max(0,bounds.x1-bounds.x0-size*0.16) end
    if not width then
        width = 0
        for _, ch in ipairs(chars(text)) do width = width + size * (#ch == 1 and 0.56 or 1)*(bold and 1.05 or 1) end
    end
    s.widths[cache_key] = width
    return width
end
local function fitted(s, text, width, size, bold)
    if measure(s,text,size,bold) <= width then return text, false end
    local parts, lo, hi = chars(text), 0, #chars(text)
    while lo < hi do
        local mid = math.ceil((lo+hi)/2)
        if measure(s,table.concat(parts,'',1,mid)..'…',size,bold) <= width then lo=mid else hi=mid-1 end
    end
    return table.concat(parts,'',1,lo)..'…', true
end
local function add_text(out, text, x, y, size, color, clip, bold, alignment)
    local style = string.format('\\an%d\\pos(%.2f,%.2f)\\bord0\\shad0\\fnMicrosoft YaHei UI\\fs%.2f\\1c&H%s&\\b%d',alignment or 7,x,y,size,ass_color(color),bold and 1 or 0)
    if clip then style=style..string.format('\\clip(%.2f,%.2f,%.2f,%.2f)',clip.x,clip.y,clip.x+clip.w,clip.y+clip.h) end
    out[#out+1]='{'..style..'}'..escape(text)
end
local function rect(out, x, y, w, h, color, radius)
    if w <= 0 or h <= 0 then return end
    local r = math.min(radius or 0,w/2,h/2)
    local path
    if r > 0 then
        local k=r*0.55228475
        path=string.format('m %.2f %.2f l %.2f %.2f b %.2f %.2f %.2f %.2f %.2f %.2f l %.2f %.2f b %.2f %.2f %.2f %.2f %.2f %.2f l %.2f %.2f b %.2f %.2f %.2f %.2f %.2f %.2f l %.2f %.2f b %.2f %.2f %.2f %.2f %.2f %.2f',
            x+r,y,x+w-r,y,x+w-r+k,y,x+w,y+r-k,x+w,y+r,x+w,y+h-r,x+w,y+h-r+k,x+w-r+k,y+h,x+w-r,y+h,x+r,y+h,x+r-k,y+h,x,y+h-r+k,x,y+h-r,x,y+r,x,y+r-k,x+r-k,y,x+r,y)
    else path=string.format('m %.2f %.2f l %.2f %.2f %.2f %.2f %.2f %.2f',x,y,x+w,y,x+w,y+h,x,y+h) end
    out[#out+1]=string.format('{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H%s&\\p1}%s{\\p0}',ass_color(color),path)
end
local function stroke(out,x1,y1,x2,y2,width,color)
    local length=math.sqrt((x2-x1)^2+(y2-y1)^2)
    if length==0 then return end
    local dx,dy=(y1-y2)*width/length/2,(x2-x1)*width/length/2
    out[#out+1]=string.format('{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H%s&\\p1}m %.2f %.2f l %.2f %.2f %.2f %.2f %.2f %.2f{\\p0}',ass_color(color),x1+dx,y1+dy,x2+dx,y2+dy,x2-dx,y2-dy,x1-dx,y1-dy)
end
local function reset_tip(s) s.tip=nil;s.tip_focus=nil end
local function caret(s) s.caret=true; s.blink=now() end
local function focus_row(s,id)
    if id==nil then return end
    s.focus='row';s.focus_id=id; reset_tip(s)
    if (s.kind=='audio' or s.kind=='chapter') and id~=0 then s.tip_focus=id end
    if id~=0 then
        for index,track in ipairs(s.matches) do
            if track.id==id then
                s.scroll=clamp(s.scroll,math.max(0,index-s.capacity),index-1); break
            end
        end
    end
end
local function selection(s)
    return s.anchor and math.min(s.anchor,s.cursor) or s.cursor, s.anchor and math.max(s.anchor,s.cursor) or s.cursor
end
local function replace_selection(s, text)
    local inserted=chars(clean(text))
    local first,last=selection(s)
    if #s.chars-(last-first)+#inserted>4096 then s.error='查找内容过长。';render();return end
    local result={}
    for i=1,first do result[#result+1]=s.chars[i] end
    for _,ch in ipairs(inserted) do result[#result+1]=ch end
    for i=last+1,#s.chars do result[#result+1]=s.chars[i] end
    s.chars=result;s.cursor=first+#inserted;s.anchor=nil;s.focus='search';s.focus_id=nil;s.scroll=0;s.error='';reset_tip(s);caret(s);render()
end
local function move_cursor(s, delta, select_text)
    if s.focus~='search' then return end
    if select_text then s.anchor=s.anchor or s.cursor
    elseif s.anchor then local a,b=selection(s);s.cursor=delta<0 and a or b;s.anchor=nil;caret(s);render();return end
    s.cursor=clamp(s.cursor+delta,0,#s.chars);if not select_text then s.anchor=nil end;caret(s);render()
end
local function submit(s,id)
    reset_tip(s)
    local ok,applied,err=pcall(s.submit,id)
    if active~=s then return end
    if ok and applied==true then M.close();return end
    s.error=clean(ok and err or s.profile.failed)
    if s.error=='' then s.error=s.profile.failed end
    s.focus=#s.tracks>0 and 'search' or 'close';s.focus_id=nil;caret(s);render()
end
local function move_rows(s,delta)
    if #s.tracks==0 then return end
    if s.kind=='chapter' and #s.matches==0 then return end
    local first=s.kind=='chapter' and 1 or 0
    local index
    if s.focus=='row' then
        if s.focus_id==0 then index=0 end
        for i,track in ipairs(s.matches) do if track.id==s.focus_id then index=i end end
    end
    if index==nil then index=delta<0 and #s.matches or first
    else index=(index-first+delta)%(#s.matches+1-first)+first end
    focus_row(s,index==0 and 0 or s.matches[index].id);render()
end
local function close_console_watch()
    if observing_console and not active and not pending_ime then mp.unobserve_property(console_changed);observing_console=false end
end
local function restore_pending()
    if pending_ime and not active and not native('user-data/mpv/console/open',false) then
        local previous=pending_ime;pending_ime=nil
        if native('input-ime')==true then pcall(set,'input-ime',previous.value) end
    end
    close_console_watch()
end
console_changed=function(_,value)
    if value==true and active then M.close() end
    if value~=true then restore_pending() end
end
local function watch_console()
    if not observing_console then observing_console=true;mp.observe_property('user-data/mpv/console/open','bool',console_changed) end
end
local function borrow(s,name,value)
    local previous=native(name)
    if previous==nil then return false end
    local ok,result=pcall(set,name,value)
    if not ok or result==false or result==nil then return false end
    s.borrowed[#s.borrowed+1]={name=name,previous=previous,value=native(name)};return true
end
local function all_input(s)
    local w,h=dimensions();mp.set_mouse_area(0,0,w,h,section)
end
local function get_hit(s)
    local x,y,hover=position()
    if not hover or not s.layout then return nil end
    if not contains(s.layout.panel,x,y) then return 'outside' end
    if contains(s.layout.close,x,y) then return 'close' end
    if contains(s.layout.search,x,y) and #s.tracks>0 then return 'search' end
    if contains(s.layout.thumb,x,y) then return 'thumb' end
    if contains(s.layout.scrollbar,x,y) then return 'scrollbar' end
    for _,row in ipairs(s.layout.rows) do if contains(row,x,y) then return row.id,row end end
    return nil
end
wheel=function(delta)
    local s=active;if not s then return end
    reset_tip(s);s.scroll=clamp(s.scroll+delta,0,math.max(0,#s.matches-s.capacity));render()
end
mouse_leave=function()
    local s=active;if not s then return end
    s.hover=nil;s.pressed=nil;s.drag=nil;reset_tip(s);render()
end
mouse_move=function()
    local s=active;if not s then return end
    local x,y,hover=position()
    if not hover then mouse_leave();return end
    if s.drag and s.layout.scrollbar and s.layout.thumb then
        local bar,thumb=s.layout.scrollbar,s.layout.thumb
        s.scroll=math.floor(clamp((y-s.drag-bar.y)/math.max(1,bar.h-thumb.h),0,1)*math.max(0,#s.matches-s.capacity)+0.5)
        reset_tip(s);render();return
    end
    local hit,row=get_hit(s)
    local changed=s.hover~=hit;s.hover=hit
    if row and (row.elided or row.details) then
        if not s.tip or s.tip.id~=hit or math.abs(x-s.tip.x)>4*s.layout.scale or math.abs(y-s.tip.y)>4*s.layout.scale then
            s.tip={id=hit,title=row.title,details=row.details,x=x,y=y,due=now()+0.55,phase='waiting'};changed=true
        end
    elseif s.tip then reset_tip(s);changed=true end
    if changed then render() end
end
mouse_button=function(info)
    local s=active;if not s then return end
    if info.canceled then s.pressed=nil;s.drag=nil;render();return end
    local hit,row=get_hit(s)
    if info.event=='down' or info.event=='press' then
        s.pressed=hit;reset_tip(s)
        if hit=='thumb' then local _,y=position();s.drag=y-s.layout.thumb.y
        elseif hit=='search' then
            s.focus='search';s.focus_id=nil;s.anchor=nil
            local x=position();local wanted=x-s.layout.search.x-36*s.layout.scale+s.query_offset
            local prefix='';s.cursor=0
            for i,ch in ipairs(s.chars) do
                local left=measure(s,prefix,search_size*s.layout.scale);prefix=prefix..ch
                if wanted<(left+measure(s,prefix,search_size*s.layout.scale))/2 then break end
                s.cursor=i
            end
            caret(s)
        elseif type(hit)=='number' then focus_row(s,hit)
        elseif hit=='scrollbar' then local _,y=position();wheel(y<s.layout.thumb.y and -s.capacity or s.capacity) end
        render()
    end
    if info.event=='up' or info.event=='press' then
        local pressed=s.pressed;s.pressed=nil;s.drag=nil
        if pressed==hit and type(hit)=='number' then submit(s,hit)
        elseif pressed==hit and hit=='close' then M.close()
        -- Keep the exclusive section until release so dismissal cannot also
        -- activate the video/OSC beneath it. Dragging out is not a click out.
        elseif pressed==hit and hit=='outside' then M.close('outside-click')
        elseif active==s then render() end
    end
end
key=function(name, info)
    local s=active;if not s or info.canceled or not ({press=true,down=true,['repeat']=true})[info.event] then return end
    if name=='unicode' then
        if #s.tracks>0 and type(info.key_text)=='string' then replace_selection(s,info.key_text) end
    elseif name=='escape' then M.close()
    elseif name=='enter' then
        if s.focus=='close' then M.close()
        elseif s.focus=='row' then submit(s,s.focus_id)
        elseif #s.matches>0 then submit(s,s.matches[1].id) end
    elseif name=='up' then move_rows(s,-1)
    elseif name=='down' then move_rows(s,1)
    elseif name=='pageup' then move_rows(s,-math.max(1,s.capacity))
    elseif name=='pagedown' then move_rows(s,math.max(1,s.capacity))
    elseif name=='left' then move_cursor(s,-1,false)
    elseif name=='right' then move_cursor(s,1,false)
    elseif name=='selectleft' then move_cursor(s,-1,true)
    elseif name=='selectright' then move_cursor(s,1,true)
    elseif name=='home' or name=='end' then
        if s.focus=='search' then s.cursor=name=='home' and 0 or #s.chars;s.anchor=nil;caret(s);render()
        elseif #s.tracks>0 then
            local first=s.kind=='chapter' and (s.matches[1] and s.matches[1].id) or 0
            if s.kind=='chapter' and #s.matches==0 then first=nil end
            focus_row(s,name=='home' and first or (#s.matches>0 and s.matches[#s.matches].id or first));render()
        end
    elseif name=='search' and #s.tracks>0 then reset_tip(s);s.focus='search';s.focus_id=nil;s.anchor=0;s.cursor=#s.chars;caret(s);render()
    elseif name=='all' and #s.tracks>0 then reset_tip(s);s.focus='search';s.focus_id=nil;s.anchor=0;s.cursor=#s.chars;caret(s);render()
    elseif name=='backspace' or name=='delete' then
        if #s.tracks==0 then return end
        s.focus='search';local a,b=selection(s)
        if a==b then
            if name=='backspace' and s.cursor>0 then s.anchor=s.cursor-1
            elseif name=='delete' and s.cursor<#s.chars then s.anchor=s.cursor+1 end
        end
        replace_selection(s,'')
    elseif name=='clear' and #s.tracks>0 then s.anchor=0;s.cursor=#s.chars;replace_selection(s,'')
    elseif name=='paste' and #s.tracks>0 then replace_selection(s,mp.get_property('clipboard/text',''))
    elseif name=='tab' then
        reset_tip(s)
        if s.focus=='search' and #s.tracks>0 then
            if s.kind=='chapter' then
                if s.matches[1] then focus_row(s,s.matches[1].id) else s.focus='close' end
            else focus_row(s,0) end
        elseif s.focus=='row' then s.focus='close';s.focus_id=nil
        else s.focus=#s.tracks>0 and 'search' or 'close' end
        render()
    end
end
local bindings={
    {'any_unicode','unicode'},{'ESC','escape'},{'ENTER','enter'},{'KP_ENTER','enter'},
    {'UP','up'},{'DOWN','down'},{'PGUP','pageup'},{'PGDWN','pagedown'},
    {'LEFT','left'},{'RIGHT','right'},{'Shift+LEFT','selectleft'},{'Shift+RIGHT','selectright'},
    {'HOME','home'},{'END','end'},{'BS','backspace'},{'DEL','delete'},
    {'Ctrl+a','all'},{'Ctrl+f','search'},{'Ctrl+u','clear'},{'Ctrl+v','paste'},
    {'TAB','tab'},{'Shift+TAB','tab'},{'MBTN_LEFT','mouse'},
    {'MOUSE_MOVE','move'},{'MOUSE_LEAVE','leave'},{'WHEEL_UP','wheelup'},{'WHEEL_DOWN','wheeldown'},
    {'MBTN_LEFT_DBL','ignore'},{'MBTN_RIGHT','ignore'},{'MBTN_MID','ignore'},
}
local function install_bindings(s)
    local entries={}
    for index,binding in ipairs(bindings) do
        local name='track-selector-'..tostring(index);local action=binding[2]
        s.binding_names[#s.binding_names+1]=name
        mp.add_key_binding(nil,name,function(info)
            if active~=s then return end
            if action=='mouse' then mouse_button(info)
            elseif action=='move' then mouse_move()
            elseif action=='leave' then mouse_leave()
            elseif action=='wheelup' or action=='wheeldown' then
                if not info.canceled and ({press=true,down=true,['repeat']=true})[info.event] then wheel((action=='wheelup' and -1 or 1)*math.max(1,math.floor(3*(info.scale or 1)))) end
            else key(action,info) end
        end,{complex=true,repeatable=true})
        entries[#entries+1]={binding[1],'nonscalable script-binding '..mp.get_script_name()..'/'..name}
    end
    if not defined then mp.set_key_bindings(entries,section,'force');defined=true end
    -- Named nil-key callbacks must be flushed before our exclusive section is
    -- enabled, so even an existing subtitle adjustment mode stays below it.
    if mp.flush_keybindings then mp.flush_keybindings() end
    all_input(s);mp.enable_key_bindings(section,'exclusive')
end
local function draw_tip(s,out,l)
    if not s.tip or s.tip.phase~='shown' then return end
    local size=12*l.scale;local maxwidth=math.min(380*l.scale,l.w-20)
    local wrapped={}
    local function wrap(text)
        local line=''
        for _,ch in ipairs(chars(text)) do
            if line~='' and measure(s,line..ch,size)>maxwidth-20*l.scale then wrapped[#wrapped+1]=line;line=ch else line=line..ch end
        end
        wrapped[#wrapped+1]=line
    end
    wrap(s.tip.title)
    for _,detail in ipairs(s.tip.details or {}) do wrap(detail) end
    local maxlines=math.max(1,math.floor((l.h-24*l.scale)/(size+5*l.scale)))
    if #wrapped>maxlines then
        while #wrapped>maxlines do table.remove(wrapped) end
        wrapped[maxlines]=fitted(s,wrapped[maxlines]..'…',maxwidth-20*l.scale,size)
    end
    local width=0;for _,value in ipairs(wrapped) do width=math.max(width,measure(s,value,size)) end
    width=math.min(maxwidth,width+20*l.scale);local height=#wrapped*(size+5*l.scale)+16*l.scale
    local x=clamp(s.tip.x+12*l.scale,4,math.max(4,l.w-width-4));local y=s.tip.y+16*l.scale
    if y+height>l.h-4 then y=s.tip.y-height-12*l.scale end
    y=math.max(4,y)
    rect(out,x,y,width,height,'444444',4*l.scale);rect(out,x+1,y+1,width-2,height-2,'242424',3*l.scale)
    for i,value in ipairs(wrapped) do add_text(out,value,x+10*l.scale,y+8*l.scale+(i-1)*(size+5*l.scale),size,'E5E5E5',{x=x+2,y=y+2,w=width-4,h=math.min(height-4,l.h-y-4)}) end
end
render=function()
    local s=active;if not s then return end
    local w,h=dimensions()
    if w<2 or h<2 then s.overlay.data='';s.overlay:update();s.last_data=nil;status('waiting-osd');return end
    s.matches=filtered(s)
    local extra=s.error~='' and 28 or 0
    local single=s.kind=='chapter'
    local off_step,row_step=single and 0 or 34,single and 40 or 54
    local minimum_height=122+(#s.tracks==0 and 116 or off_step+(#s.matches==0 and 76 or row_step)+8)
    local dpi=tonumber(native('display-hidpi-scale',1)) or 1
    if dpi~=dpi or dpi<=0 or dpi==math.huge then dpi=1 end
    local scale=math.max(0.000001,math.min(dpi,math.max(1,w-12)/panel_width,math.max(1,h-12)/(minimum_height+extra)))
    local capacity=clamp(math.floor((h/scale-28-122-off_step-8-extra)/row_step),1,single and 8 or 5)
    s.capacity=capacity;s.scroll=clamp(s.scroll,0,math.max(0,#s.matches-capacity))
    local rows=math.min(capacity,#s.matches)
    local listheight=#s.tracks==0 and 116 or off_step+(rows>0 and rows*row_step or 76)+8
    local height=(34+54+extra+listheight+34)*scale
    local x,y=(w-panel_width*scale)/2,(h-height)/2
    local l={x=x,y=y,w=w,h=h,scale=scale,rows={}}
    s.layout=l
    l.panel={x=x,y=y,w=panel_width*scale,h=height}
    l.close={x=x+(panel_width-44)*scale,y=y,w=44*scale,h=34*scale}
    l.search={x=x+16*scale,y=y+48*scale,w=(panel_width-32)*scale,h=30*scale}
    local listtop=y+(88+extra)*scale
    local out={}
    rect(out,x,y,panel_width*scale,height,'393939',8*scale);rect(out,x+1,y+1,panel_width*scale-2,height-2,'151515',7*scale)
    rect(out,x+1,y+1,panel_width*scale-2,33*scale,'1C1C1C',6*scale)
    add_text(out,s.profile.title,x+20*scale,y+17*scale,16*scale,'E5E5E5',nil,false,4)
    if s.hover=='close' then rect(out,l.close.x+1,l.close.y+1,l.close.w-2,l.close.h-2,'8F2633') end
    local cx,cy=l.close.x+22*scale,l.close.y+17*scale
    stroke(out,cx-5*scale,cy-5*scale,cx+5*scale,cy+5*scale,1.3*scale,'BBBBBB');stroke(out,cx+5*scale,cy-5*scale,cx-5*scale,cy+5*scale,1.3*scale,'BBBBBB')
    if s.focus=='close' then
        local left,top,right,bottom=l.close.x+4*scale,l.close.y+4*scale,l.close.x+l.close.w-4*scale,l.close.y+l.close.h-4*scale
        stroke(out,left,top,right,top,scale,'777777');stroke(out,right,top,right,bottom,scale,'777777')
        stroke(out,right,bottom,left,bottom,scale,'777777');stroke(out,left,bottom,left,top,scale,'777777')
    end
    rect(out,l.search.x,l.search.y,l.search.w,l.search.h,s.focus=='search' and #s.tracks>0 and '1287BB' or '444444',4*scale)
    rect(out,l.search.x+scale,l.search.y+scale,l.search.w-2*scale,l.search.h-2*scale,'202020',3*scale)
    local mx,my=l.search.x+18*scale,l.search.y+l.search.h/2-1.75*scale
    local previous
    for i=0,24 do local angle=i/24*math.pi*2;local p={mx+6.5*scale*math.cos(angle),my+6.5*scale*math.sin(angle)};if previous then stroke(out,previous[1],previous[2],p[1],p[2],1.3*scale,'999999') end;previous=p end
    stroke(out,mx+4.7*scale,my+4.7*scale,mx+10*scale,my+10*scale,1.3*scale,'999999')
    local q=query(s);local prefix=table.concat(s.chars,'',1,s.cursor);local prefixwidth=measure(s,prefix,search_size*scale);local available=l.search.w-48*scale
    s.query_offset=clamp(s.query_offset,math.max(0,prefixwidth-available),prefixwidth)
    local clip={x=l.search.x+34*scale,y=l.search.y+4*scale,w=available+2*scale,h=l.search.h-8*scale}
    if q=='' and s.focus~='search' then add_text(out,s.profile.search,l.search.x+36*scale,l.search.y+l.search.h/2,search_size*scale,#s.tracks>0 and '999999' or '777777',clip,false,4)
    else
        local a,b=selection(s)
        if a~=b then
            local left=measure(s,table.concat(s.chars,'',1,a),search_size*scale)-s.query_offset
            local right=measure(s,table.concat(s.chars,'',1,b),search_size*scale)-s.query_offset
            rect(out,l.search.x+36*scale+clamp(left,0,available),l.search.y+(l.search.h-20*scale)/2,math.max(0,clamp(right,0,available)-clamp(left,0,available)),20*scale,'174354')
        end
        add_text(out,q,l.search.x+36*scale-s.query_offset,l.search.y+l.search.h/2,search_size*scale,'E5E5E5',clip,false,4)
    end
    if s.focus=='search' and #s.tracks>0 and s.caret then rect(out,l.search.x+36*scale+prefixwidth-s.query_offset,l.search.y+(l.search.h-18*scale)/2,scale,18*scale,'E5E5E5') end
    if extra>0 then local message=fitted(s,s.error,(panel_width-36)*scale,meta_size*scale);add_text(out,message,x+18*scale,y+89*scale,meta_size*scale,'D8B780') end
    -- Shared columns use the whole track set, so scrolling/filtering cannot
    -- shift separators. Missing fields leave their column empty.
    local lang_width,codec_width,id_width,channel_width=0,0,0,36*scale
    local has_language,has_codec=false,false
    local function meta_language(track)
        return track.lang~='' and label(track,s.kind)~=language(track) and language(track) or ''
    end
    for _,track in ipairs(s.tracks) do
        local lang=s.kind=='audio' and language(track) or meta_language(track)
        if lang~='' then has_language=true;lang_width=math.max(lang_width,measure(s,lang,meta_size*scale)) end
        if track.codec~='' then has_codec=true;codec_width=math.max(codec_width,measure(s,track.codec,meta_size*scale)) end
        id_width=math.max(id_width,measure(s,single and track.time_text or '#'..track.id,meta_size*scale))
        if s.kind=='audio' and track.channels then
            channel_width=math.max(channel_width,measure(s,string.format('%g 声道',track.channels),meta_size*scale))
        end
    end
    lang_width=clamp(lang_width,24*scale,80*scale)
    codec_width=clamp(codec_width,32*scale,84*scale)
    local function row(track,top,off)
        local id=off and 0 or track.id;local current=s.current==id;local focused=s.focus=='row' and s.focus_id==id
        local r={x=x+8*scale,y=top,w=(panel_width-16)*scale,h=(off and 30 or single and 38 or 52)*scale,id=id,title=off and s.profile.off or label(track,s.kind)}
        if not off and s.kind=='audio' then r.details=audio_details(track) end
        l.rows[#l.rows+1]=r
        local background=current and '152B35' or s.hover==id and '252525' or focused and '222222' or '151515'
        if focused then rect(out,r.x,r.y,r.w,r.h,'777777',4*scale);rect(out,r.x+scale,r.y+scale,r.w-2*scale,r.h-2*scale,background,3*scale)
        else rect(out,r.x,r.y,r.w,r.h,background,4*scale) end
        local tx=r.x+40*scale;local width=r.w-64*scale-(off and 0 or id_width)
        local title,elided=fitted(s,r.title,width,title_size*scale,current);r.elided=elided
        add_text(out,title,tx,(off or single) and r.y+r.h/2 or r.y+7*scale,title_size*scale,current and '54B8E3' or 'E5E5E5',
            {x=tx,y=r.y+2*scale,w=width,h=(off and 26 or single and 34 or 25)*scale},current,(off or single) and 4 or 7)
        if current then
            local cx,cy=r.x+19*scale,r.y+r.h/2
            out[#out+1]=string.format('{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H%s&\\p1}m %.2f %.2f l %.2f %.2f %.2f %.2f{\\p0}',
                ass_color('54B8E3'),cx-3*scale,cy-5*scale,cx+4*scale,cy,cx-3*scale,cy+5*scale)
        end
        if not off then
            if single then
                add_text(out,track.time_text,r.x+r.w-10*scale,r.y+r.h/2,meta_size*scale,'AAAAAA',nil,false,6)
            else
            local identifier='#'..id;add_text(out,identifier,r.x+r.w-10*scale,r.y+9*scale,meta_size*scale,'999999',nil,false,9)
            if s.kind=='audio' then
                -- Compact, bounded columns shared across the complete track
                -- set. Center only interior cells between dividers, matching
                -- the subtitle codec column; keep the whole group left-anchored.
                local gap,line=8*scale,scale
                local cells={math.min(lang_width,56*scale),math.min(codec_width,64*scale),
                    math.min(channel_width,48*scale),72*scale}
                local values={language(track),track.codec,track.channels and string.format('%g 声道',track.channels) or '',source(track)}
                local left=tx
                for i,value in ipairs(values) do
                    local cell=cells[i]
                    local centered=i>1 and i<#values
                    add_text(out,fitted(s,value~='' and value or '—',cell,meta_size*scale),centered and left+cell/2 or left,r.y+36*scale,meta_size*scale,'AAAAAA',
                        {x=left,y=r.y+26*scale,w=cell,h=20*scale},false,centered and 5 or 4)
                    if i<4 then rect(out,left+cell+gap,r.y+31*scale,line,10*scale,'555555') end
                    left=left+cell+2*gap+line
                end
            else
            local sx=tx
            local function column(text,column_width,centered)
                local value=fitted(s,text,column_width,meta_size*scale)
                add_text(out,value,centered and sx+column_width/2 or sx,r.y+36*scale,meta_size*scale,'AAAAAA',
                    {x=sx,y=r.y+26*scale,w=column_width,h=20*scale},false,centered and 5 or 4)
                rect(out,sx+column_width+8*scale,r.y+31*scale,scale,10*scale,'555555')
                sx=sx+column_width+17*scale
            end
            if has_language then column(meta_language(track),lang_width,false) end
            if has_codec then column(track.codec,codec_width,true) end
            local source=track.external==true and '外挂' or track.external==false and '内嵌' or '来源未标注'
            local source_width=math.max(0,tx+width-sx)
            add_text(out,fitted(s,source,source_width,meta_size*scale),sx,r.y+36*scale,meta_size*scale,'AAAAAA',
                {x=sx,y=r.y+26*scale,w=source_width,h=20*scale},false,4)
            end
            end
        end
    end
    if #s.tracks==0 then
        local title,hint=s.profile.empty,s.profile.hint
        add_text(out,title,x+(panel_width*scale-measure(s,title,title_size*scale))/2,listtop+30*scale,title_size*scale,'DDDDDD')
        add_text(out,hint,x+(panel_width*scale-measure(s,hint,meta_size*scale))/2,listtop+60*scale,meta_size*scale,'AAAAAA')
    else
        if not single then row(nil,listtop,true) end
        if #s.matches==0 then local message=s.profile.nomatch;add_text(out,message,x+(panel_width*scale-measure(s,message,search_size*scale))/2,listtop+(off_step+30)*scale,search_size*scale,'AAAAAA') end
        for i=1,rows do row(s.matches[s.scroll+i],listtop+(off_step+(i-1)*row_step)*scale,false) end
        if #s.matches>capacity then
            local top=listtop+off_step*scale;local bh=rows*row_step*scale
            local th=math.min(bh,math.max(24*scale,bh*capacity/#s.matches));local ty=top+(bh-th)*s.scroll/(#s.matches-capacity)
            l.scrollbar={x=x+(panel_width-14)*scale,y=top,w=10*scale,h=bh};l.thumb={x=x+(panel_width-12)*scale,y=ty,w=6*scale,h=th}
            rect(out,l.thumb.x,l.thumb.y,l.thumb.w,l.thumb.h,s.drag and '1287BB' or '707070',3*scale)
        end
    end
    local footer=y+height-34*scale;rect(out,x+1,footer,panel_width*scale-2,scale,'2C2C2C')
    add_text(out,single and '↑ ↓ 移动　Enter 跳转　Esc 取消' or '↑ ↓ 移动　Enter 选择　Esc 取消',x+18*scale,footer+10*scale,meta_size*scale,'AAAAAA')
    local count=(q~='' and tostring(#s.matches)..' / ' or '')..tostring(#s.tracks)..(single and ' 章' or ' 条')
    add_text(out,count,x+(panel_width-18)*scale-measure(s,count,meta_size*scale),footer+10*scale,meta_size*scale,'AAAAAA')
    if s.tip_focus then
        for _,r in ipairs(l.rows) do
            if r.id==s.tip_focus and (r.details or r.elided) then
                s.tip={id=r.id,title=r.title,details=r.details,x=r.x+32*scale,y=r.y+r.h,due=now()+0.55,phase='waiting'}
                break
            end
        end
        s.tip_focus=nil
    end
    draw_tip(s,out,l)
    local data=table.concat(out,'\n')
    if data~=s.last_data or s.overlay.res_x~=w or s.overlay.res_y~=h then
        s.overlay.res_x=w;s.overlay.res_y=h;s.overlay.data=data;s.overlay:update();s.last_data=data
    end
    all_input(s)
    if s.status_w~=w or s.status_h~=h or s.status_scale~=scale then
        s.status_w,s.status_h,s.status_scale=w,h,scale;status('rendered')
    end
end
function M.is_open() return active~=nil end
function M.update(tracks,id)
    local s=active;if not s then return false end
    s.tracks=normalize(tracks);s.current=current_id(id);s.matches=filtered(s)
    if #s.tracks==0 then s.focus='close';s.focus_id=nil
    elseif s.focus=='row' and s.focus_id~=0 then
        local valid=false;for _,track in ipairs(s.matches) do valid=valid or track.id==s.focus_id end
        if not valid then s.focus='search';s.focus_id=nil end
    end
    reset_tip(s);render();return true
end
function M.close(reason)
    local s=active;if not s then restore_pending();return end
    active=nil
    for _,name in ipairs(s.binding_names) do mp.remove_key_binding(name) end
    mp.disable_key_bindings(section);mp.set_mouse_area(0,0,0,0,section)
    if mp.flush_keybindings then mp.flush_keybindings() end
    if s.timer then s.timer:kill() end
    if s.dimensions_changed then mp.unobserve_property(s.dimensions_changed) end
    if s.focus_changed then mp.unobserve_property(s.focus_changed) end
    for i=#s.borrowed,1,-1 do
        local item=s.borrowed[i]
        if item.name=='input-ime' and native('user-data/mpv/console/open',false) and not shutting_down then pending_ime={value=item.previous}
        elseif native(item.name)==item.value then pcall(set,item.name,item.previous) end
    end
    if s.overlay then s.overlay:remove() end;if s.measure then s.measure:remove() end
    pcall(set,published,false);close_console_watch()
    status('closed',reason)
    if s.close then pcall(s.close) end
end
function M.open(options)
    if shutting_down then return false,'播放器正在退出。' end
    if type(options)~='table' or type(options.submit)~='function' then return false,'轨道选择入口无效。' end
    local kind=options.kind or 'subtitle'
    if not profiles[kind] then return false,'轨道选择类型无效。' end
    if native('user-data/mpv/console/open',false) then status('blocked','console');return false,'控制台正在使用输入。' end
    restore_pending()
    if active and active.kind~=kind then M.close('switch-kind') end
    if active then
        active.submit=options.submit;active.close=options.close
        M.update(options.tracks,options.current_id);active.focus=#active.tracks>0 and 'search' or 'close';caret(active);render();return true
    end
    local s={kind=kind,profile=profiles[kind],tracks=normalize(options.tracks),current=current_id(options.current_id),submit=options.submit,close=options.close,
        chars={},cursor=0,query_offset=0,scroll=0,error='',binding_names={},borrowed={},widths={},matches={},capacity=1,caret=true,blink=now()}
    s.focus=#s.tracks>0 and 'search' or 'close';active=s
    status('opening')
    local ok,failure=pcall(function()
        for _,item in ipairs({{'input-ime',true},{'cursor-autohide','no'},{'window-dragging',false}}) do
            if not borrow(s,item[1],item[2]) then error('input-property') end
        end
        s.overlay=mp.create_osd_overlay('ass-events');s.overlay.z=1100
        s.measure=mp.create_osd_overlay('ass-events');s.measure.compute_bounds=true;s.measure.hidden=true
        install_bindings(s);pcall(set,published,true);watch_console()
        if active~=s then return end
        s.dimensions_changed=function() if active==s then reset_tip(s);render() end end
        s.focus_changed=function(_,focused)
            if active~=s then return end
            -- The first notification describes startup state, not a focus-loss
            -- event. Embedded/startup windows may initially report false.
            if focused==true then s.had_focus=true
            elseif focused==false and s.had_focus then M.close('focus-lost') end
        end
        mp.observe_property('osd-dimensions','native',s.dimensions_changed)
        mp.observe_property('display-hidpi-scale','native',s.dimensions_changed)
        mp.observe_property('focused','bool',s.focus_changed)
        if active~=s then return end
        s.timer=mp.add_periodic_timer(0.1,function()
            if active~=s then return end
            local changed=false
            if s.focus=='search' and now()-s.blink>=0.5 then s.caret=not s.caret;s.blink=now();changed=true end
            if s.tip and s.tip.phase=='waiting' and now()>=s.tip.due then s.tip.phase='shown';s.tip.expires=now()+5;changed=true
            elseif s.tip and s.tip.phase=='shown' and now()>=s.tip.expires then s.tip.phase='expired';changed=true end
            if changed then render() end
        end)
        render()
    end)
    if not ok then
        s.close=nil;M.close();status('failed',failure)
        if mp.msg then mp.msg.error('Track selector startup failed: '..tostring(failure)) end
        return false,'无法打开轨道选择器，请重试。'
    end
    return active==s
end
mp.register_event('shutdown',function()
    shutting_down=true;M.close();pending_ime=nil
    if observing_console then mp.unobserve_property(console_changed);observing_console=false end
end)
return M
