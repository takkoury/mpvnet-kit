-- Settings controller: persistence and editor lifecycle; features apply values.
local mp=require('mp')
local utils=require('mp.utils')
local function expand(path) return mp.command_native({'expand-path','~~/'..path}) end
local model=dofile(expand('script-modules/user-settings.lua'))
local parser=dofile(expand('script-modules/user-shortcuts.lua'))
local paths=dofile(expand('script-modules/mpvnet-paths.lua'))
local settings_path,local_path=expand('mpvnet-user.json'),expand('script-opts/mpvnet-local.conf')
local storage,window=expand('helpers/settings-storage.ps1'),expand('helpers/settings-window.ps1')
local instance=string.format('%.0f-%.0f',mp.get_property_number('pid',0),mp.get_time()*1000000)
local sequence,revision_number,local_number,session=0,0,0,0
local revision,paths_revision='', ''
local observed_raw,observed_exists,observed_error,local_raw,local_exists,local_error
local document,error_text,paths_error=nil,'',''
local local_values={}
local runtime={}
local retired={}
local token,editor_running,editor_visible,closing='',false,false,false
local saving,saving_page,save_serial,save_page,save_error,save_ok,save_revision=false,'',0,'','',false,''
local preview_serial,preview_error=0,''
local owned={}
local encode,decode=utils.format_json,utils.parse_json
local function read(path)
    local file,_,errno=io.open(path,'rb')
    if not file then
        if errno==2 and not utils.file_info(path) then return '',false end
        return nil,nil,'无法读取配置；请检查文件权限'
    end
    local raw=file:read(model.max_bytes+1); local closed=file:close()
    if not raw or not closed then return nil,nil,'读取配置失败' end
    if #raw>model.max_bytes then return nil,nil,'配置文件超过 256 KiB 限制' end
    return raw,true
end
local function defaults()
    local values={}
    for _,field in ipairs(model.fields) do values[field.id]=runtime[field.id] and runtime[field.id].default or field.default end
    return values
end
local function publish()
    local fields={}
    for _,field in ipairs(model.fields) do
        local owner=runtime[field.id] or {}
        local default=owner.default or field.default
        local override=document and document.values[field.id]
        local status=owner.status or 'unavailable'
        if status=='effective' and not model.same_number(owner.effective,override or default) then status='pending-media' end
        fields[#fields+1]={id=field.id,page=field.page,label=field.label,search_terms=field.search_terms,default=default,
            saved=override or default,has_override=override~=nil,effective=owner.effective,
            status=status,apply_error=owner.apply_error or '',can_cancel=(owner.preview_owner or '')~='',
            min=field.min,max=field.max,slider_min=field.slider_min,slider_max=field.slider_max,
            step=field.step,default_source=owner.default_source or '等待功能模块'}
    end
    local labels={capture_root='截图与片段目录',ffmpeg_path='FFmpeg 路径',python_path='Python 路径',mpv_path='缩略图播放器路径'}
    for _,id in ipairs(model.path_fields) do
        local saved=local_values[id] or ''
        local effective=id=='capture_root' and saved or paths.options[id] or ''
        fields[#fields+1]={id=id,page='paths',label=labels[id],default='',saved=saved,
            has_override=saved~='',effective=effective,status=saved==effective and 'effective' or 'pending-restart',
            apply_error='',default_source='自动选择'}
    end
    mp.set_property_native('user-data/mpvnet/settings',{schema=1,editor_token=token,
        editor_visible=editor_visible,revision=revision,paths_revision=paths_revision,error=error_text,
        paths_error=paths_error,saving=saving,saving_page=saving_page,save_serial=save_serial,
        save_page=save_page,save_error=save_error,save_ok=save_ok,save_revision=save_revision,
        fields=fields,pages=model.pages,preview_serial=preview_serial,preview_error=preview_error,
        preview_subtitle_position=mp.get_property_number('sub-pos',100)})
end
local function reload(force)
    if closing then return end
    local raw,exists,err=read(settings_path)
    if force==true or force=='settings' or raw~=observed_raw or exists~=observed_exists or err~=observed_error then
        observed_raw,observed_exists,observed_error=raw,exists,err
        revision_number=revision_number+1;revision=instance..':'..revision_number
        local parsed
        if not err then
            if exists and raw=='' then err='用户配置文件为空；未修改文件'
            else parsed,err=model.document(raw,decode,parser) end
        end
        document,error_text=parsed,err or ''
        if parsed then mp.set_property_native('user-data/mpvnet/settings-values',{schema=1,revision=revision,values=parsed.values}) end
    end
    raw,exists,err=read(local_path)
    if force==true or force=='paths' or raw~=local_raw or exists~=local_exists or err~=local_error then
        local_raw,local_exists,local_error=raw,exists,err
        local_number=local_number+1;paths_revision=instance..':paths:'..local_number
        local parsed
        if not err then parsed,err=paths.parse_local(raw) end
        paths_error=err or '';if parsed then local_values=parsed end
    end
    publish()
end
local function remove_owned(path)
    if path and owned[path] then os.remove(path);owned[path]=nil end
end
local function request_file(kind,text)
    local temp=os.getenv('TEMP') or os.getenv('TMP')
    if not temp or temp=='' then return nil,'找不到系统临时目录' end
    sequence=sequence+1
    local path=utils.join_path(temp,'mpvnet-settings-'..instance..'-'..sequence..'-'..kind..'.json')
    local file=io.open(path,'wb');if not file then return nil,'无法创建设置请求文件' end
    owned[path]=true
    local ok,closed=file:write(text),file:close()
    if not ok or not closed then remove_owned(path);return nil,'无法写入设置请求文件' end
    return path
end
local function launch(helper,operation,path,callback)
    local args={paths.powershell(),'-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',helper}
    if operation then args[#args+1]='-Operation';args[#args+1]=operation end
    args[#args+1]='-RequestPath';args[#args+1]=path
    mp.command_native_async({name='subprocess',args=args,capture_stdout=true,capture_stderr=false,playback_only=false},function(ok,result)
        remove_owned(path);if not closing then callback(ok,result) end
    end)
end
local function current(received) return not closing and token~='' and received==token end
local function display_preview(owner,operation)
    mp.commandv('script-message-to','modernz','settings-display-preview',owner,operation)
end
local function retire(owner)
    for _,field in ipairs(model.fields) do
        local value=mp.get_property_native('user-data/mpvnet/settings-runtime/'..field.id) or runtime[field.id] or {}
        if value.preview_owner==owner then
            retired[field.id]={owner=owner,serial=value.cancel_serial or 0,generation=value.generation,notified=false}
        end
    end
end
local function cancel(page,owner)
    for _,field in ipairs(model.fields) do
        if not page or field.page==page then
            mp.commandv('script-message-to',field.script,'settings-cancel',owner)
            local old=retired[field.id]
            local value=mp.get_property_native('user-data/mpvnet/settings-runtime/'..field.id) or runtime[field.id] or {}
            if old and value.preview_owner==old.owner then
                if old.owner~=owner then mp.commandv('script-message-to',field.script,'settings-cancel',old.owner) end
            elseif old then retired[field.id]=nil end
        end
    end
end
local function finish(page,message,ok,written_revision)
    saving,saving_page=false,'';save_page=page;save_error=message or '';save_ok=ok==true
    save_revision=written_revision or '';save_serial=save_serial+1;publish()
end
local function save(received,expected,page,proposed)
    if not current(received) then return end
    if page~='paths' and page~='subtitles' and page~='controlbar' then return end
    if saving then
        save_page=page;save_error='上一项保存仍在进行，请稍后重试';save_ok=false;save_serial=save_serial+1;publish();return
    end
    reload(false)
    if expected~=(page=='paths' and paths_revision or revision) then finish(page,'配置已被其他窗口修改；请重新载入后保存',false);return end
    local err,body,operation,expected_written
    if page=='paths' then
        if paths_error~='' then finish(page,paths_error,false);return end
        local root;root,err=parser.parse(proposed or '',decode)
        if not root or root.kind~='object' then finish(page,err or '路径保存内容必须是 JSON 对象',false);return end
        local values={}
        for id,node in pairs(root.values) do
            local known=false;for _,name in ipairs(model.path_fields) do if id==name then known=true end end
            if not known or node.kind~='string' then finish(page,'本机路径项目或值无效',false);return end
            values[id]=node.value
        end
        body=encode({schema=1,return_written_text=true,settings_path=local_path,expected_exists=local_exists==true,
            expected_text=local_raw or '',values=values});operation='SaveLocal'
    else
        if not document then finish(page,error_text~='' and error_text or '用户配置当前不可写',false);return end
        local next_raw;next_raw,err=model.prepare(document,page,proposed or '',decode,encode,parser,defaults())
        if not next_raw then finish(page,err,false);return end
        body=encode({schema=1,return_written_text=true,settings_path=settings_path,expected_exists=observed_exists==true,
            expected_text=observed_raw or '',document_text=next_raw:gsub('^\239\187\191','')});operation='Save'
        expected_written=next_raw:gsub('^\239\187\191','')
    end
    local path;path,err=request_file('save',body)
    if not path then finish(page,err,false);return end
    saving,saving_page,save_error,save_ok=true,page,'',false;publish()
    launch(storage,operation,path,function(ok,result)
        local response=result and decode(result.stdout or '')
        if not ok or not result or result.status~=0 or type(response)~='table' or response.ok~=true then
            finish(page,response and response.conflict==true and '配置已被其他窗口修改；请重新载入后保存'
                or '保存失败；原配置保持不变',false);return
        end
        reload(false)
        local written_text=type(response.written_text)=='string' and response.written_text or expected_written
        local ours=written_text~=nil and (page=='paths' and local_raw or observed_raw)==written_text
        local written=ours and (page=='paths' and paths_revision or revision) or ''
        if page~='paths' and document and ours and current(received) then
            for _,field in ipairs(model.fields) do
                if field.page==page then mp.commandv('script-message-to',field.script,'settings-commit',received,revision) end
            end
        end
        finish(page,(page=='paths' and paths_error or error_text)~='' and '文件已保存，但重新载入失败' or '',true,written)
    end)
end
local function preview(received,id,value)
    if not current(received) then return end
    local field=model.field(id);if not field then return end
    local root,err=parser.parse(value or '',decode)
    if not root or (root.kind~='null' and (root.kind~='number' or not model.valid(field,root.value))) then
        preview_error=err or '预览值超出允许范围';preview_serial=preview_serial+1;publish();return
    end
    preview_error='';preview_serial=preview_serial+1
    local old=retired[id]
    local value=mp.get_property_native('user-data/mpvnet/settings-runtime/'..id) or runtime[id] or {}
    local previous_owner=old and value.preview_owner==old.owner and old.owner or ''
    mp.commandv('script-message-to',field.script,'settings-preview',received,root.kind=='null' and 'null' or tostring(root.value),previous_owner)
    publish()
end
local function open()
    if closing then return end
    if editor_running then mp.commandv('script-message','mpvnet-settings-show',token);return end
    session=session+1;token=instance..':editor:'..session
    local pipe=mp.get_property('options/input-ipc-server','')
    if pipe=='' then
        pipe='\\\\.\\pipe\\mpvnet-settings-'..instance
        if not mp.set_property('options/input-ipc-server',pipe) then save_error='无法建立当前播放器的 IPC 通道';publish();return end
    end
    local path,err=request_file('editor',encode({schema=1,pipe=pipe,parent_pid=mp.get_property_number('pid',0),
        script=mp.get_script_name(),token=token,settings_path=settings_path,local_path=local_path}))
    if not path then save_error=err;publish();return end
    local opened_token=token
    editor_running,editor_visible=true,true;publish()
    launch(window,nil,path,function(ok,result)
        if token==opened_token then
            display_preview(opened_token,'end')
            retire(opened_token);cancel(nil,opened_token);token='';editor_visible=false
        end
        editor_running=false
        if not ok or not result or result.status~=0 then save_error='无法打开设置窗口' end
        publish()
    end)
end
mp.add_key_binding(nil,'open',open)
mp.register_script_message('editor-ready',function(received) if current(received) then editor_visible=true;publish() end end)
mp.register_script_message('editor-close',function(received)
    if current(received) then
        display_preview(received,'end')
        retire(received);cancel(nil,received);token='';editor_visible=false;publish()
    end
end)
mp.register_script_message('preview-display',function(received,page)
    if not current(received) then return end
    local operation=({controlbar='begin',none='end',renew='renew'})[page]
    if operation then display_preview(received,operation) end
end)
mp.register_script_message('save',save)
mp.register_script_message('preview',preview)
mp.register_script_message('cancel',function(received,page) if current(received) then cancel(page,received) end end)
mp.register_script_message('reset',function(received,page)
    if current(received) then for _,field in ipairs(model.fields) do if field.page==page then preview(received,field.id,'null') end end end
end)
for _,field in ipairs(model.fields) do
    local id=field.id
    mp.observe_property('user-data/mpvnet/settings-runtime/'..id,'native',function(_,value)
        if type(value)=='table' then
            runtime[id]=value
            local old=retired[id]
            if old then
                if value.preview_owner==old.owner and value.cancel_owner==old.owner
                    and (value.cancel_serial or 0)>old.serial and (value.cancel_error or '')~='' then
                    if not old.notified then
                        mp.osd_message('预览未能恢复，请重新打开设置后重试撤销',3);old.notified=true
                    end
                elseif value.generation~=old.generation or (value.preview_owner or '')~='' and value.preview_owner~=old.owner
                    or (value.preview_owner or '')=='' and (value.apply_error or '')=='' then retired[id]=nil end
            end
            publish()
        end
    end)
end
mp.register_event('shutdown',function()
    if token~='' then
        display_preview(token,'end')
        cancel(nil,token);mp.commandv('script-message','mpvnet-settings-close',token)
    end
    closing,editor_visible=true,false;token=''
    for path in pairs(owned) do remove_owned(path) end
end)
reload(true)
mp.add_periodic_timer(1,function() if not saving then reload(false) end end)
