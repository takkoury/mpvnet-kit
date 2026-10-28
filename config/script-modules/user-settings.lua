-- Settings data and field ownership. The window owns drafts; each feature owns
-- its actual value, media generation and conditional preview restoration.
local M = {max_bytes=256*1024}
M.fields = {
    {id='sub-scale', page='subtitles', label='字幕字号', default=1, min=0.05, max=100, step=0.05, script='subtitle_controls'},
    {id='modernz.scalewindowed', page='controlbar', label='窗口控制栏缩放', default=1, min=0.25, max=4, step=0.05, script='modernz'},
}
M.path_fields = {'capture_root', 'ffmpeg_path', 'python_path', 'mpv_path'}
M.pages = {{id='subtitles',label='字幕'},{id='controlbar',label='控制栏'},{id='paths',label='本机路径'}}
function M.field(id)
    for _, field in ipairs(M.fields) do if field.id == id then return field end end
end
function M.valid(field, value)
    return type(value)=='number' and value==value and value>=field.min and value<=field.max
end
-- mpv stores some numeric options as float32. A successful 1.8 write can read
-- back as 1.79999995; allow that representation error, far below a 0.05 edit.
-- Preview ownership still compares the exact actual value captured after write.
function M.same_number(a,b)
    return type(a)=='number' and type(b)=='number'
        and math.abs(a-b)<=1e-6*math.max(1,math.abs(a),math.abs(b))
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
            if node.kind~='number' or not M.valid(field,node.value) then return nil, field.label..'超出允许范围' end
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
        if node.kind~='null' and (node.kind~='number' or not M.valid(field,node.value)) then
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
        if node and node.kind~='null' and not M.same_number(node.value,defaults[field.id] or field.default) then
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

function M.owner(mp, spec)
    local field=assert(M.field(spec.id))
    local baseline=spec.read()
    -- The editor range limits new overrides, not a user's valid advanced startup
    -- configuration. Following defaults must never silently replace that value.
    if type(baseline)~='number' or baseline~=baseline or math.abs(baseline)==math.huge then baseline=field.default end
    local saved, revision, initialized, override=baseline,'',false,false
    local generation,version,preview,apply_error=0,0,nil,''
    local cancel_serial,cancel_owner,cancel_error=0,'',''
    local observed=spec.read()
    local property='user-data/mpvnet/settings-runtime/'..spec.id
    local function current() return spec.read() end
    local function publish()
        local value=current()
        local status=apply_error~='' and 'apply-failed' or preview and 'preview'
            or (not M.same_number(value,saved) and 'pending-media' or 'effective')
        mp.set_property_native(property,{id=spec.id,default=baseline,default_source=spec.default_source,
            saved=saved,has_override=override,effective=value,status=status,apply_error=apply_error,
            revision=revision,generation=generation,version=version,preview_owner=preview and preview.owner or '',
            cancel_serial=cancel_serial,cancel_owner=cancel_owner,cancel_error=cancel_error})
    end
    local function refresh()
        local value=current()
        if value~=observed then
            version=version+1; observed=value
            if preview and value~=preview.value then preview=nil end
        end
        publish()
    end
    local function write(value)
        local ok,result=pcall(spec.write,value)
        observed=current(); version=version+1
        if not ok or not result or not M.same_number(observed,value) then
            apply_error='播放器未能应用此设置'; publish(); return false
        end
        apply_error=''; return true
    end
    local function cancel(token)
        refresh()
        local old=preview
        if not old or old.owner~=token then return end
        preview=nil
        if old.generation==generation and old.version==version and current()==old.value then
            if not write(old.base) and current()==old.value then old.version=version;preview=old end
        end
        cancel_serial=cancel_serial+1;cancel_owner=token;cancel_error=preview and apply_error or ''
        publish()
    end
    local function apply_saved()
        local old=preview
        if write(saved) then
            preview=nil
            if spec.committed then spec.committed(saved) end
        elseif old and old.generation==generation and current()==old.value then
            -- A rejected write has not taken ownership from the old preview.
            -- Keep its original restoration point available to Cancel/Close.
            old.version=version;preview=old
        else preview=nil end
        publish()
    end
    local function sync(snapshot)
        if type(snapshot)~='table' or snapshot.schema~=1 or type(snapshot.values)~='table' then return end
        local value=snapshot.values[spec.id]
        if value~=nil and not M.valid(field,value) then return end
        saved=value or baseline; override=value~=nil; revision=snapshot.revision or ''
        if not initialized then initialized=true; apply_saved() else refresh() end
    end
    mp.observe_property('user-data/mpvnet/settings-values','native',function(_,snapshot)
        -- mpv observers can run after a later script-message. Consult the current
        -- property so a delayed notification cannot resurrect an older snapshot.
        sync(mp.get_property_native('user-data/mpvnet/settings-values') or snapshot)
    end)
    if spec.property then mp.observe_property(spec.property,'number',refresh) end
    mp.register_script_message('settings-preview',function(token,value,previous_owner)
        local follow_default=value=='null'
        value=follow_default and baseline or tonumber(value)
        if (not follow_default and not M.valid(field,value)) or type(token)~='string' or token=='' then return end
        refresh()
        local old=preview
        local base=old and (old.owner==token or old.owner==previous_owner)
            and old.generation==generation and old.version==version and old.base or current()
        preview=nil
        if write(value) then preview={owner=token,base=base,value=current(),generation=generation,version=version}
        elseif old and old.generation==generation and current()==old.value then old.version=version;preview=old end
        publish()
    end)
    mp.register_script_message('settings-cancel',cancel)
    mp.register_script_message('settings-commit',function(_,expected_revision)
        sync(mp.get_property_native('user-data/mpvnet/settings-values'))
        if initialized and expected_revision==revision then apply_saved() end
    end)
    -- A media change invalidates previews even when the next file has the same
    -- path. Apply after file-local options and temporary adjustment cleanup.
    mp.register_event('start-file',function()
        if preview then cancel(preview.owner) end
        generation=generation+1; preview=nil; publish()
    end)
    mp.register_event('end-file',function()
        if preview then cancel(preview.owner) end
        generation=generation+1;preview=nil;publish()
    end)
    mp.register_event('file-loaded',function()
        sync(mp.get_property_native('user-data/mpvnet/settings-values'))
        if initialized then apply_saved() end
    end)
    mp.register_event('shutdown',function() if preview then cancel(preview.owner) end end)
    publish()
    return {refresh=refresh,cancel=cancel,invalidate=function()
        preview=nil;version=version+1;observed=current();publish()
    end}
end
return M
