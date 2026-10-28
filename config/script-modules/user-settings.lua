-- Settings data and field ownership. The window owns drafts; each feature owns
-- its actual value, media generation and conditional preview restoration.
local M = {max_bytes=256*1024}
M.fields = {
    {id='slang',page='subtitles',label='字幕语言顺序',kind='string',default='zh,zho,chi,ja,jpn,en,eng',timing='next-media',section='语言与显示',script='settings_options',search_terms='语言 优先 顺序 中文 日语 英语 slang'},
    {id='sub-visibility',page='subtitles',label='打开视频时显示字幕',kind='boolean',default=true,timing='next-media',section='语言与显示',script='settings_options'},
    {id='sub-font',page='subtitles',label='字幕字体',kind='string',default='sans-serif',timing='preview',section='外观',script='subtitle_controls'},
    {id='sub-pos',page='subtitles',label='字幕位置',kind='number',display='position',default=100,min=0,max=100,slider_min=0,slider_max=100,step=1,timing='preview',section='外观',script='subtitle_controls'},
    {id='sub-scale',page='subtitles',label='字幕缩放',kind='number',display='percent',search_terms='字幕大小 字号 比例 字体大小',default=1,min=0.05,max=100,slider_min=0.5,slider_max=2,step=0.05,timing='preview',section='外观',script='subtitle_controls'},
    {id='alang',page='audio',label='音轨语言顺序',kind='string',default='',timing='next-media',section='音轨',script='settings_options',search_terms='语言 优先 顺序 音频 alang'},
    {id='volume',page='audio',label='启动音量',kind='number',display='number',default=100,min=0,max=1000,slider_min=0,slider_max=100,step=1,timing='startup',first_media=true,section='启动',script='settings_options'},
    {id='mute',page='audio',label='启动静音',kind='boolean',default=false,timing='startup',first_media=true,section='启动',script='settings_options'},
    {id='fullscreen',page='window',label='默认全屏',kind='boolean',default=false,timing='startup',script='settings_options'},
    {id='ontop',page='window',label='默认置顶',kind='boolean',default=false,timing='startup',script='settings_options'},
    {id='modernz.scalewindowed',page='controlbar',label='窗口控制栏缩放',kind='number',display='percent',search_terms='控制栏大小 比例 OSC',default=1,min=0.25,max=4,slider_min=0.5,slider_max=2,step=0.05,timing='preview',section='外观',script='modernz'},
    {id='modernz.scalefullscreen',page='controlbar',label='全屏控制栏缩放',kind='number',display='percent',default=1,min=0.25,max=4,slider_min=0.5,slider_max=2,step=0.05,timing='preview',section='外观',script='modernz'},
    {id='modernz.hidetimeout',page='controlbar',label='自动隐藏时间',kind='number',display='seconds',default=1.5,min=0,max=60,slider_min=0,slider_max=10,step=0.1,timing='preview',section='显示',script='modernz'},
    {id='modernz.keeponpause',page='controlbar',label='暂停时显示',kind='choice',default='no',choices={{value='no',label='不保持'},{value='bottombar',label='显示控制栏'},{value='both',label='显示全部'}},timing='preview',section='显示',script='modernz'},
    {id='modernz.chapter_fmt',page='controlbar',label='章节标题',kind='boolean',default=true,timing='preview',section='显示',script='modernz'},
    {id='modernz.timecurrent',page='controlbar',label='显示当前时间',kind='boolean',default=true,timing='preview',section='时间',script='modernz'},
    {id='modernz.timems',page='controlbar',label='显示毫秒',kind='boolean',default=false,timing='preview',section='时间',script='modernz'},
    {id='modernz.persistent_progress',page='controlbar',label='常驻进度线',kind='boolean',default=false,timing='preview',section='显示',script='modernz'},
    {id='hwdec',page='decoding',label='硬件解码',kind='choice',default='auto-safe',choices={{value='auto-safe',label='自动安全硬解'},{value='no',label='关闭硬解'}},timing='next-media',script='settings_options',search_terms='硬解 软件 解码 hwdec'},
}
M.path_fields = {'capture_root','ffmpeg_path','python_path','mpv_path'}
M.pages = {{id='subtitles',label='字幕'},{id='audio',label='声音与音轨'},{id='window',label='窗口'},
    {id='controlbar',label='控制栏'},{id='decoding',label='解码'},{id='paths',label='本机路径'},
    {id='shortcuts',label='快捷键',action_only=true},{id='advanced',label='高级',action_only=true}}
M.actions = {{id='shortcuts.open',page='shortcuts',label='编辑用户快捷键',search_terms='录键 冲突 恢复 键位'},
    {id='edit.mpv.conf',page='advanced',label='编辑 mpv.conf',search_terms='高级 播放器配置'},
    {id='edit.input.conf',page='advanced',label='编辑 input.conf',search_terms='高级 按键 菜单'},
    {id='edit.modernz.conf',page='advanced',label='编辑 ModernZ 配置',search_terms='高级 控制栏 OSC'},
    {id='open.config-folder',page='advanced',label='打开配置目录',search_terms='高级 配置文件 文件夹'}}
function M.field(id)
    for _,field in ipairs(M.fields) do if field.id==id then return field end end
end
function M.value_or(value,fallback) if value~=nil then return value end;return fallback end
function M.valid(field,value)
    if field.kind=='number' then return type(value)=='number' and value==value and value>=field.min and value<=field.max end
    if field.kind=='boolean' then return type(value)=='boolean' end
    if field.kind=='string' then return type(value)=='string' and #value<=512 and not value:find('[%z\1-\31\127]') end
    if field.kind=='choice' then for _,choice in ipairs(field.choices) do if value==choice.value then return true end end end
    return false
end
-- Accept mpv float32 round-trips for validation, while ownership uses exact values.
function M.same_number(a,b)
    return type(a)=='number' and type(b)=='number'
        and math.abs(a-b)<=1e-6*math.max(1,math.abs(a),math.abs(b))
end
function M.same(a,b) return a==b or M.same_number(a,b) end
function M.valid_node(field,node)
    -- The shared raw parser represents JSON booleans by kind, with no value.
    if not node then return false end
    if node.kind=='true' or node.kind=='false' then node.value=node.kind=='true' end
    return M.valid(field,node.value)
end
function M.document(raw, decode, parser)
    local doc, err = parser.document(raw, decode)
    if not doc then return nil, err end
    doc.settings = doc.root and doc.root.values.settings or {kind='object',members={},values={}}
    if doc.settings.kind ~= 'object' then return nil, 'settings 必须是 JSON 对象' end
    doc.values = {}
    for _, field in ipairs(M.fields) do
        local node = doc.settings.values[field.id]
        if node then
            if not M.valid_node(field,node) then return nil, field.label..'超出允许范围' end
            doc.values[field.id] = node.value
        end
    end
    return doc
end
function M.proposed(page, raw, decode, parser)
    local root, err = parser.parse(raw,decode)
    if not root then return nil, err end
    if root.kind~='object' then return nil, '保存内容必须是 JSON 对象' end
    for id,node in pairs(root.values) do
        local field=M.field(id)
        if not field or field.page~=page then return nil, '保存内容包含其他分类或未知设置' end
        if node.kind~='null' and (not M.valid_node(field,node)) then
            return nil, field.label..'超出允许范围'
        end
    end
    return root
end
function M.prepare(document, page, raw, decode, encode, parser, defaults)
    local proposed,err=M.proposed(page,raw,decode,parser)
    if not proposed then return nil,err end
    local fields={}
    for _,member in ipairs(document.settings.members) do
        if not proposed.values[member.key] then fields[#fields+1]=document.raw:sub(member.first,member.node.last) end
    end
    for _,field in ipairs(M.fields) do
        local node=proposed.values[field.id]
        local legacy_default=field.id=='sub-scale' or field.id=='modernz.scalewindowed'
        if node and node.kind~='null' and (not legacy_default or not M.same(node.value,M.value_or(defaults[field.id],field.default))) then
            fields[#fields+1]=encode(field.id)..':'..encode(node.value)
        end
    end
    local replacement='{'..table.concat(fields,',')..'}'
    local result
    if document.raw=='' then result='{"schema":1,"settings":'..replacement..'}'
    elseif document.root.values.settings then
        local old=document.root.values.settings
        result=document.raw:sub(1,old.first-1)..replacement..document.raw:sub(old.last+1)
    else
        result=document.raw:sub(1,document.root.last-1)..(#document.root.members>0 and ',' or '')
            ..'"settings":'..replacement..document.raw:sub(document.root.last)
    end
    if #result>M.max_bytes then return nil,'保存后的配置超过 256 KiB 限制' end
    return result
end

-- Owners in one feature share message handlers. Each internal message carries the
-- field ID; registering several owners cannot silently replace earlier handlers.
local dispatchers=setmetatable({},{__mode='k'})
local function dispatcher(mp,field)
    local scripts=dispatchers[mp] or {};dispatchers[mp]=scripts
    local script=mp.get_script_name and mp.get_script_name() or field.script
    local group=scripts[script]
    if group then return group end
    group={};scripts[script]=group
    local function dispatch(id,method,...)
        if id and id~='' then if group[id] then group[id][method](...) end
        elseif method=='preview' then
            local legacy=script=='modernz' and 'modernz.scalewindowed' or 'sub-scale'
            if group[legacy] then group[legacy][method](...) end
        else for _,owner in pairs(group) do owner[method](...) end end
    end
    mp.register_script_message('settings-preview',function(token,value,previous_owner,id) dispatch(id,'preview',token,value,previous_owner) end)
    mp.register_script_message('settings-cancel',function(token,id) dispatch(id,'cancel',token) end)
    mp.register_script_message('settings-commit',function(token,expected,id) dispatch(id,'commit',token,expected) end)
    return group
end
function M.owner(mp,spec)
    local field=assert(M.field(spec.id))
    local expected_type=field.kind=='choice' and 'string' or field.kind
    local function baseline_value(value)
        if type(value)~=expected_type or type(value)=='number' and (value~=value or math.abs(value)==math.huge) then return field.default end
        return value
    end
    local baseline=baseline_value(spec.read())
    local first_media=spec.initialize_on_load==true
    local startup_ready,startup_applied,startup_override,startup_value=false,false,false,nil
    local saved,revision,initialized,override=baseline,'',false,false
    local generation,version,preview,apply_error=0,0,nil,''
    local cancel_serial,cancel_owner,cancel_error=0,'',''
    local observed=spec.read()
    local property='user-data/mpvnet/settings-runtime/'..spec.id
    local function current() return spec.read() end
    local function publish()
        local value=current()
        local pending=field.timing=='startup' and 'pending-startup' or 'pending-media'
        local status=apply_error~='' and 'apply-failed' or preview and 'preview'
            or (first_media and not startup_applied and startup_override and 'pending-startup')
            or (not M.same(value,saved) and pending or 'effective')
        mp.set_property_native(property,{id=spec.id,default=baseline,default_source=spec.default_source,
            saved=saved,has_override=override,effective=value,status=status,apply_error=apply_error,
            revision=revision,generation=generation,version=version,preview_owner=preview and preview.owner or '',
            cancel_serial=cancel_serial,cancel_owner=cancel_owner,cancel_error=cancel_error})
    end
    local function refresh()
        local value=current()
        -- Before the first media, host remember-volume and other host startup
        -- work may still update the inherited baseline. Never write it back.
        if first_media and not startup_applied then
            baseline=baseline_value(value)
            if not override then saved=baseline end
        end
        if value~=observed then
            version=version+1;observed=value
            if preview and value~=preview.value then preview=nil end
        end
        publish()
    end
    local function write(value,reason)
        local ok,result=pcall(spec.write,value,reason)
        observed=current();version=version+1
        if not ok or not result or not M.same(observed,value) then
            apply_error='播放器未能应用此设置';publish();return false
        end
        apply_error='';return true
    end
    local function cancel(token)
        refresh()
        local old=preview
        if not old or old.owner~=token then return end
        preview=nil
        if old.generation==generation and old.version==version and current()==old.value then
            if not write(old.base,'cancel') and current()==old.value then old.version=version;preview=old end
        end
        cancel_serial=cancel_serial+1;cancel_owner=token;cancel_error=preview and apply_error or ''
        publish()
    end
    local function apply_saved(reason)
        local old=preview
        if write(saved,reason or 'saved') then
            preview=nil
            if spec.committed then spec.committed(saved) end
        elseif old and old.generation==generation and current()==old.value then
            old.version=version;preview=old
        else preview=nil end
        publish()
    end
    local function sync(snapshot)
        if type(snapshot)~='table' or snapshot.schema~=1 then return end
        if first_media and not startup_ready and not startup_applied then
            -- The controller carries its immutable first read, even if that
            -- read was invalid. A repair/save before playback is for a future
            -- instance and cannot silently change this instance's startup goal.
            local seed=snapshot.startup
            if type(seed)~='table' and type(snapshot.values)=='table' then seed={available=true,values=snapshot.values} end
            if type(seed)=='table' and type(seed.values)=='table' then
                startup_ready=true
                local initial=seed.values[spec.id]
                if seed.available==true and initial~=nil and M.valid(field,initial) then
                    startup_override,startup_value=true,initial
                end
            end
        end
        if type(snapshot.values)~='table' then refresh();return end
        local value=snapshot.values[spec.id]
        if value~=nil and not M.valid(field,value) then return end
        saved=M.value_or(value,baseline);override=value~=nil;revision=snapshot.revision or ''
        if not initialized then
            initialized=true
            -- Startup inheritance leaves host initialization intact; overrides are
            -- applied once. Polling, saves and media changes never reapply them.
            if field.timing=='preview' or field.timing=='startup' and override and not first_media then apply_saved('startup') else refresh() end
        else refresh() end
    end
    mp.observe_property('user-data/mpvnet/settings-values','native',function(_,snapshot)
        sync(mp.get_property_native('user-data/mpvnet/settings-values') or snapshot)
    end)
    if spec.property then
        local kind=field.kind=='number' and 'number' or field.kind=='boolean' and 'bool' or 'string'
        mp.observe_property(spec.property,kind,refresh)
    end
    local owner={refresh=refresh,cancel=cancel,invalidate=function()
        preview=nil;version=version+1;observed=current();publish()
    end}
    owner.preview=function(token,value,previous_owner)
        if field.timing~='preview' or type(token)~='string' or token=='' or type(value)~='string' then return end
        local follow_default=value=='null'
        if follow_default then value=baseline
        elseif field.kind=='number' then value=tonumber(value)
        elseif field.kind=='string' then
            if value:sub(1,7)=='string:' then value=value:sub(8) end
        elseif field.kind=='boolean' then
            if value=='true' then value=true elseif value=='false' then value=false else return end
        end
        if not follow_default and not M.valid(field,value) then return end
        refresh()
        local old=preview
        local base=current()
        if old and (old.owner==token or old.owner==previous_owner) and old.generation==generation and old.version==version then base=old.base end
        preview=nil
        if write(value,'preview') then preview={owner=token,base=base,value=current(),generation=generation,version=version}
        elseif old and old.generation==generation and current()==old.value then old.version=version;preview=old end
        publish()
    end
    owner.commit=function(_,expected_revision)
        sync(mp.get_property_native('user-data/mpvnet/settings-values'))
        if initialized and expected_revision==revision and field.timing=='preview' then apply_saved() end
    end
    dispatcher(mp,field)[spec.id]=owner
    mp.register_event('start-file',function()
        if preview then cancel(preview.owner) end
        generation=generation+1;preview=nil;publish()
    end)
    mp.register_event('end-file',function()
        if preview then cancel(preview.owner) end
        generation=generation+1;preview=nil;publish()
    end)
    if field.timing=='next-media' then
        -- on_load runs before demux, track selection and decoder creation. Writing
        -- file-local options here never rebuilds the currently playing decoder.
        mp.add_hook('on_load',50,function()
            sync(mp.get_property_native('user-data/mpvnet/settings-values'))
            if initialized and override then apply_saved('media') else refresh() end
        end)
    elseif field.timing=='startup' then
        mp.add_hook('on_load',50,function()
            if first_media and startup_applied then refresh();return end
            if first_media then baseline=baseline_value(current()) end
            -- Read the latest bus directly even if its observer is delayed. The
            -- bootstrap selection stays frozen while saved values can advance.
            sync(mp.get_property_native('user-data/mpvnet/settings-values'))
            initialized=true
            if first_media then
                startup_applied=true
                if startup_override then write(startup_value,'startup') end
            end
            refresh()
        end)
    elseif field.timing=='preview' then
        mp.register_event('file-loaded',function()
            sync(mp.get_property_native('user-data/mpvnet/settings-values'))
            if initialized then apply_saved() end
        end)
    end
    mp.register_event('shutdown',function() if preview then cancel(preview.owner) end end)
    sync(mp.get_property_native('user-data/mpvnet/settings-values'))
    publish()
    return owner
end
return M
