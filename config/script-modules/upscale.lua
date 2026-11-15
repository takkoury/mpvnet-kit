-- Own the optional runtime, helper tasks and borrowed playback state. The caller
-- remains the only owner of desired/applied presets and startup preferences.
local M = {}
M.names = {CUGAN='Real-CUGAN Pro · 动画', ESRGAN='Real-ESRGAN · 动画'}
local errors = {
    helper_missing='缺少超分管理程序，请重新安装配置包。', helper_failed='准备程序未能完成，请重试。',
    gpu_unavailable='未检测到可用的 NVIDIA 显卡。', gpu_unsupported='当前显卡不支持这套超分组件。',
    driver_unsupported='当前显卡驱动不满足超分组件要求。', crt_missing='缺少 Microsoft Visual C++ 运行库，请先查看组件说明。',
    components_missing='需要先准备超分组件。', bundle_integrity='组件文件已更改，请检查组件目录后重试。',
    bundle_conflict='组件目录中已有不同内容，请先检查该目录。', component_busy='另一窗口正在准备组件，请稍后重试。',
    cache_busy='另一窗口正在准备同一画面，请稍后重试。', cache_invalid='已有画面缓存无法使用，请移开该项缓存后重试。',
    compile_failed='本次画面准备失败，请查看详情后重试。', prepare_failed='本次画面准备失败，请重试。',
    runtime_load='超分运行组件未能加载。', host_unavailable='当前播放器未能加载超分支持扩展，请重开窗口后重试。',
    runtime_conflict='当前窗口已经使用另一套 Python 或 VapourSynth，请在独立窗口中使用超分。',
    source_unsupported='首批超分支持 480p 及以下的 SDR 逐行动画。', source_color='无法识别这段视频的色彩信息。',
    filter_conflict='当前已有其他 VapourSynth 处理，请先关闭它。', filter_failed='超分滤镜未能正常输出画面。',
    restore_failed='画面还原未能完成，请关闭增强后重试。', cancelled='已取消准备。', request_failed='无法创建准备请求，请检查临时目录。',
    component_download_failed='组件下载未完成，请检查网络后重试。', component_extract_failed='组件展开失败，请重新准备。',
    component_disk_space='组件目录所在磁盘空间不足，请释放空间后重试。', component_io_failed='无法读写组件目录，请检查权限和可用空间。',
    unsupported_architecture='这套超分组件仅支持 Windows x64。',
    component_path_too_long='组件目录路径过长，无法完成准备。请使用较短的播放器目录。',
    source_changed='视频参数已改变，请重新启用画面增强。', filter_changed='画面滤镜已被其他操作改变，超分已停止。',
}
local stages = {probing='检查运行条件', checking='检查组件与画面', converting='准备当前视频尺寸',
    compiling='编译画面处理', downloading='下载组件', extracting='展开组件', verifying='校验组件',
    installing='准备组件', committing='提交组件', loading='加载画面增强', ready='准备完成'}

function M.new(mp, utils, callbacks)
    local root = mp.command_native({'expand-path','~~/'})
    local function expand(path) return mp.command_native({'expand-path','~~/'..path}) end
    local instance = tostring(mp.get_property_number('pid',0))..'-'..string.format('%.0f',mp.get_time()*1000000)
    local sequence, generation, host_serial = 0, 0, 0
    local job, pending, active, activation, borrowed, pause_owned, expected_pause, host_wait
    local active_source, performance, warned
    local filter_before_file
    local closing, dialog_process, dialog_request
    local s = {phase='idle',requested='',stage='',elapsed=0,error_text='',dialog_visible=false,dialog_token='',
        component={phase='missing',ready=false,can_install=false,stage='',elapsed=0,error_text='',download_bytes=0,expanded_bytes=0,
            bundle_root=root:gsub('[/\\]$','')..'/components/ai-upscale',source_summary='Real-CUGAN Pro／Real-ESRGAN · TensorRT 10.16／VapourSynth R79'}}
    local api = {}
    local function read_json(path)
        local f=io.open(path,'rb'); if not f then return nil end
        local text=f:read(2*1024*1024+1);f:close()
        if not text or #text>2*1024*1024 then return nil end
        return utils.parse_json(text)
    end
    local manifest=read_json(expand('upscale/components.json')) or {}
    s.component.download_bytes=manifest.download_bytes or 0
    s.component.expanded_bytes=manifest.expanded_bytes or 0
    local function write_json(path, value)
        local f=io.open(path,'wb');if not f then return false end
        local text=utils.format_json(value);local ok=text and f:write(text);local closed=f:close()
        return ok and closed
    end
    local function temporary()
        sequence=sequence+1
        return (os.getenv('TEMP') or os.getenv('TMP') or '.')..'/mpvnet-upscale-'..instance..'-'..sequence..'.json'
    end
    local function reason(code)
        code=tostring(code or 'helper_failed'):gsub('-','_')
        if code:find('conflict') and (code:find('python') or code:find('vapoursynth')) then code='runtime_conflict' end
        return errors[code] or errors.helper_failed,code
    end
    local function changed() if not closing then callbacks.changed() end end
    local function dialog(show)
        if show and not s.dialog_visible then s.dialog_token=instance..':dialog:'..tostring(sequence+1) end
        s.dialog_visible=show
    end
    local function pause_release()
        if pause_owned and mp.get_property_bool('pause',false) then
            expected_pause=false;mp.set_property_bool('pause',false)
        end
        pause_owned=false
    end
    local function own_filter()
        for _,vf in ipairs(mp.get_property_native('vf') or {}) do
            if vf.label=='mpvnet-upscale' then return vf end
        end
    end
    local function remove_filter()
        local vf=own_filter()
        local ok=true
        if vf then
            local path=vf.params and vf.params.file
            if path~=expand('upscale/runtime.vpy') or not activation or vf.params['user-data']~=activation then ok=false
            else ok=mp.commandv('vf','remove','@mpvnet-upscale') and own_filter()==nil end
            -- A failed removal is not a release of ownership. Retain its request
            -- and loan so a later explicit Original action can retry correctly.
            if not ok and path==expand('upscale/runtime.vpy') and activation
                and vf.params['user-data']==activation then return false end
        end
        if borrowed then
            if mp.get_property('hwdec')==borrowed.value then
                if not mp.set_property('hwdec',borrowed.original) then return false end
            end
            borrowed=nil
        end
        active=nil;active_source=nil;performance=nil
        if activation then
            os.remove(activation);os.remove(activation..'.ready');os.remove(activation..'.ready.part');activation=nil
        end
        return ok
    end
    local function cleanup(task)
        os.remove(task.path);os.remove(task.path..'.status.json');os.remove(task.path..'.cancel')
    end
    local function stop_task(task)
        if not task or task.cancelling then return end
        task.cancelling=true
        local f=io.open(task.path..'.cancel','wb');if f then f:write('cancel');f:close() end
        task.abort=mp.add_timeout(2,function()
            if job==task and task.async then mp.abort_async_command(task.async) end
        end)
    end
    local function fail(code, restore)
        if restore then
            if not remove_filter() or callbacks.restore()==false then code='restore_failed' end
            pause_release()
            callbacks.failed(code)
        end
        s.phase='failed';s.error_text,s.error_reason=reason(code);s.stage='';dialog(true);changed()
    end
    local select_model
    local function run(operation, extra, done, component_task)
        if job then return false end
        if not utils.file_info(expand('helpers/KitUpscale.exe')) then fail('helper_missing',false);return false end
        local path=temporary()
        local req={schema=1,request_id=instance..'-'..sequence,parent_pid=mp.get_property_number('pid',0),
            operation=operation,config_root=root,progress_path=path..'.status.json'}
        for k,v in pairs(extra or {}) do req[k]=v end
        if not write_json(path,req) then fail('request_failed',false);return false end
        local task={id=req.request_id,path=path,operation=operation,generation=generation,started=mp.get_time(),
            component=operation=='install' or component_task==true}
        job=task
        task.async=mp.command_native_async({name='subprocess',args={expand('helpers/KitUpscale.exe'),'-RequestPath',path},
            capture_stdout=true,capture_stderr=true,playback_only=false},function(ok,result)
            if task.abort then task.abort:kill() end
            cleanup(task)
            if job~=task then return end
            job=nil
            if closing then return end
            local response=result and utils.parse_json(result.stdout or '')
            if not ok or type(response)~='table' or response.request_id~=task.id then
                response={ok=false,error_reason=task.cancelling and 'cancelled' or 'helper_failed'}
            end
            if task.component or task.generation==generation then done(response,task.cancelling) end
            if pending and not job then local name=pending;pending=nil;select_model(name) end
            changed()
        end)
        return true
    end
    local function source()
        local p=mp.get_property_native('video-params')
        if type(p)~='table' or not p.w or not p.h or p.w<16 or p.w>854 or p.h<16 or p.h>480
            or p.gamma=='pq' or p.gamma=='hlg' or p.gamma=='st2084' or (tonumber(p['sig-peak'] or p.sigpeak) or 0)>1
            or (p.rotate or 0)~=0 then return nil,'source_unsupported' end
        local frame=mp.get_property_native('video-frame-info') or {}
        if frame.interlaced==true then return nil,'source_unsupported' end
        local matrices={['bt.709']='709',['bt.601']='170m',['bt.2020-ncl']='2020ncl'}
        local matrix=matrices[p.colormatrix]
        if p.colormatrix=='bt.601' and p.primaries=='bt.601-625' then matrix='470bg' end
        local chroma={['mpeg2/4/h264']='left',mpeg1='center',['topleft']='top_left',
            ['top-left']='top_left',left='left',center='center',top='top',bottom='bottom',['bottomleft']='bottom_left'}
        local location=chroma[p['chroma-location']]
        if not matrix or not location or (p.colorlevels~='limited' and p.colorlevels~='full')
            or not p.gamma or p.gamma=='' or p.gamma=='auto' then return nil,'source_color' end
        for _,vf in ipairs(mp.get_property_native('vf') or {}) do
            if vf.name=='vapoursynth' and vf.label~='mpvnet-upscale' then return nil,'filter_conflict' end
        end
        return {width=p.w,height=p.h,matrix=matrix,levels=p.colorlevels,chroma=location}
    end
    local function same_source(a,b)
        return a and b and a.width==b.width and a.height==b.height and a.matrix==b.matrix
            and a.levels==b.levels and a.chroma==b.chroma
    end
    function api.availability()
        local p,code=source()
        if s.phase=='active' and not same_source(p,active_source) then return false,code or 'source_changed' end
        return p~=nil,code
    end
    local function component_result(r)
        for _,key in ipairs({'bundle_root','download_bytes','expanded_bytes','bundle_id','manifest_sha256'}) do
            if r[key]~=nil then s.component[key]=r[key] end
        end
        s.component.ready=r.component_ready==true or r.phase=='ready' and r.ok==true
        s.component.can_install=r.device_id~=nil
        s.component.phase=s.component.ready and 'ready' or 'missing'
        s.component.error_text=r.ok and '' or reason(r.error_reason)
        s.component.error_reason=r.ok and '' or tostring(r.error_reason or 'helper_failed'):gsub('-','_')
    end
    local function enable(r,params,name,device)
        if s.phase~='preparing' then return end
        local now,code=source()
        if not now or now.width~=params.width or now.height~=params.height then fail(code or 'source_unsupported',true);return end
        activation=temporary()
        local info={schema=1,bundle_root=s.component.bundle_root,engine_path=r.engine_path,
            activation_id=activation,
            width=params.width,height=params.height,padded_width=r.padded_width,padded_height=r.padded_height,
            device_id=device.device_id,matrix=now.matrix,levels=now.levels,chroma=now.chroma}
        if not write_json(activation,info) then fail('request_failed',true);return end
        s.phase='loading';s.stage=stages.loading;s.loading_since=mp.get_time();s.output_width=params.width*2;s.output_height=params.height*2
        local hwdec=mp.get_property('hwdec','no')
        if hwdec~='no' and not hwdec:find('copy',1,true) then
            borrowed={original=hwdec,value='auto-copy'}
            -- A file-local write would make mpv restore an old backup even after
            -- somebody else changes hwdec. We release the ordinary loan on_unload.
            if not mp.set_property('hwdec','auto-copy') then fail('filter_failed',true);return end
        end
        local descriptor='@mpvnet-upscale:vapoursynth=file=%'..#expand('upscale/runtime.vpy')..'%'..expand('upscale/runtime.vpy')
            ..':user-data=%'..#activation..'%'..activation..':buffered-frames=4:concurrent-frames=4'
        if not mp.commandv('vf','append',descriptor) then fail('filter_failed',true);return end
        active=name;active_source=now;warned=false;changed()
    end
    local function prepare(name,params,device)
        if not remove_filter() then fail('restore_failed',true);return end
        s.phase='preparing';s.started=mp.get_time();s.stage=stages.checking;s.error_text='';s.elapsed=0;dialog(true)
        if callbacks.begin(name)==false then fail('restore_failed',true);return end
        pause_owned=not mp.get_property_bool('pause',false)
        if pause_owned then expected_pause=true;mp.set_property_bool('pause',true) end
        local launched=run('prepare',{model=name,width=params.width,height=params.height},function(r,cancelled)
            if cancelled then api.cancel_complete();return end
            if not r.ok then fail(r.error_reason,true);return end
            enable(r,params,name,device)
        end)
        if not launched then fail('helper_failed',true) end
        changed()
    end
    select_model=function(name)
        if not M.names[name] then return false end
        if job or host_wait then
            if job and not job.component and job.generation~=generation then pending=name;return true end
            return false
        end
        local params,code=source()
        if not params then fail(code,false);return false end
        s.requested=name;s.phase='checking';s.error_text='';s.stage=stages.probing;changed()
        return run('probe',{},function(r,cancelled)
            if cancelled then s.phase='idle';dialog(false);changed();return end
            component_result(r)
            if not r.ok then fail(r.error_reason,false);return end
            if not s.component.ready then s.phase='missing';dialog(true);changed();return end
            host_serial=host_serial+1
            host_wait={name=name,params=params,device=r,serial=host_serial,started=mp.get_time()}
        end)
    end
    api.select=select_model
    function api.cancel_complete()
        s.phase='idle';s.stage='';dialog(false)
        local ok=remove_filter() and callbacks.restore()~=false
        pause_release();callbacks.cancelled(ok);changed()
    end
    function api.cancel()
        if host_wait then
            host_wait=nil;s.phase='idle';s.stage='';dialog(false);changed()
        elseif job and not job.component then
            stop_task(job);s.stage='正在取消准备';changed()
        elseif s.phase=='loading' or s.phase=='preparing' then api.cancel_complete() end
    end
    function api.clear()
        generation=generation+1;pending=nil;host_wait=nil
        if job and not job.component then stop_task(job) end
        local ok=remove_filter();pause_release();s.phase='idle';s.stage='';dialog(false);changed()
        return ok
    end
    function api.retire()
        generation=generation+1;pending=nil;host_wait=nil
        if job and not job.component then stop_task(job) end
        -- No old task result may write to the new media. File-local restoration
        -- also occurs in mpv; only release state this module still owns.
        remove_filter();pause_release();s.phase='idle';dialog(false);changed()
    end
    function api.before_file() filter_before_file=own_filter()~=nil end
    function api.scrub_resumed_filter()
        -- Core watch-later can restore vf before on_load, including our retired
        -- per-activation temp path. As with the audio owner, reclaim only a new,
        -- exact managed signature; pre-existing/foreign labels remain untouched.
        local vf=own_filter();local p=vf and vf.params or {}
        local file=tostring(p.file or ''):gsub('\\','/')
        local data=tostring(p['user-data'] or ''):gsub('\\','/')
        if not filter_before_file and vf and vf.name=='vapoursynth'
            and file:match('/upscale/runtime%.vpy$') and data:match('/mpvnet%-upscale%-%d+%-%d+%-%d+%.json$')
            and tostring(p['buffered-frames'])=='4' and tostring(p['concurrent-frames'])=='4' then
            return mp.commandv('vf','remove','@mpvnet-upscale') and own_filter()==nil
        end
        return true
    end
    function api.manual_pause() pause_owned=false end
    function api.action(action)
        if action=='probe' and not job and not host_wait then
            s.component.phase='checking';changed()
            run('probe',{},function(r) component_result(r);changed() end,true)
        elseif action=='install' and not job and not host_wait then
            dialog(false);s.component.phase='installing';s.component.error_text='';s.component.stage=stages.checking;changed()
            run('install',{},function(r,cancelled)
                component_result(r)
                if cancelled then s.component.phase='missing';s.component.error_text='已取消组件准备。'
                elseif not r.ok then s.component.phase='failed' end
                s.component.stage='';changed()
            end)
        elseif action=='cancel-install' and job and job.operation=='install' then stop_task(job)
        elseif action=='enable-requested' or action=='retry' then select_model(s.requested)
        elseif action=='cancel' then api.cancel()
        elseif action=='components' then dialog(false);changed();mp.commandv('script-message-to','user_settings','open-components')
        elseif action=='dismiss' then dialog(false);changed() end
    end
    function api.dialog_action(token,action)
        if token==s.dialog_token and s.dialog_visible then api.action(action) end
    end
    function api.state() return s end
    function api.busy() return job~=nil or host_wait~=nil or s.phase=='preparing' or s.phase=='loading' end
    function api.is_active() return active~=nil end
    function api.on_error(event)
        local prefix=tostring(event.prefix or '')
        if (s.phase=='loading' or s.phase=='active') and event.level=='error'
            and (prefix:find('vapoursynth',1,true) or prefix:find('user_filter_wrapper',1,true)) then
            fail('filter_failed',true)
        end
    end
    function api.invalidate(code) fail(code,true) end
    mp.observe_property('pause','bool',function(_,paused)
        if expected_pause~=nil and paused==expected_pause then expected_pause=nil
        elseif pause_owned then pause_owned=false end
    end)
    local timer=mp.add_periodic_timer(0.25,function()
        if closing then return end
        if job then
            local progress=read_json(job.path..'.status.json')
            local target=job.component and s.component or s
            target.elapsed=math.floor(mp.get_time()-job.started)
            if progress and progress.request_id==job.id and not job.cancelling then
                target.stage=stages[progress.phase] or stages.checking
            end
            changed()
        elseif host_wait then
            -- The string property API JSON-quotes user-data strings again.
            -- Read the actual node before decoding the host's JSON payload.
            local host=mp.get_property_native('user-data/mpvnet/upscale-host')
            if type(host)=='string' then host=utils.parse_json(host) end
            if type(host)~='table' then host=nil end
            local waiting=host_wait
            if host and not waiting.sent then
                waiting.sent=true
                mp.commandv('script-message-to','mpvnet','mpvnet-kit-upscale-host-load',tostring(waiting.serial),manifest.bundle_id or '')
            elseif host and host.serial==waiting.serial and host.status=='ready' then
                host_wait=nil;prepare(waiting.name,waiting.params,waiting.device)
            elseif host and host.serial==waiting.serial and (host.status=='failed' or host.status=='unsupported') then
                host_wait=nil;fail(host.error_reason or 'runtime_load',false)
            elseif mp.get_time()-waiting.started>15 then host_wait=nil;fail('host_unavailable',false) end
        elseif s.phase=='loading' then
            local p=mp.get_property_native('video-out-params') or {}
            local vf=own_filter()
            local first=activation and read_json(activation..'.ready')
            if vf and vf.enabled~=false and first and first.activation_id==activation
                and p.w==s.output_width and p.h==s.output_height then
                if callbacks.active(active)==false then fail('restore_failed',true)
                else s.phase='active';s.stage='';dialog(false);pause_release();changed() end
            elseif mp.get_time()-s.loading_since>15 then fail('filter_failed',true) end
        elseif s.phase=='active' then
            local vf=own_filter()
            if not vf or vf.enabled==false or not vf.params or vf.params.file~=expand('upscale/runtime.vpy')
                or vf.params['user-data']~=activation then fail('filter_changed',true)
            elseif not same_source(source(),active_source) then fail('source_changed',true)
            elseif not warned then
                if mp.get_property_bool('pause',false) or mp.get_property_bool('seeking',false)
                    or mp.get_property_number('speed',1)~=1 then performance=nil
                else
                    local now=mp.get_time();local drops=mp.get_property_number('frame-drop-count',0)
                    if not performance then performance={time=now,drops=drops}
                    elseif now-performance.time>=15 then
                        local fps=mp.get_property_number('container-fps',0)
                        if fps>0 and drops-performance.drops>fps*(now-performance.time)*0.05 then
                            warned=true
                            if callbacks.notice then callbacks.notice('当前超分可能跟不上播放，可切换方案或恢复原始画面。') end
                        else performance={time=now,drops=drops} end
                    end
                end
            end
        end
        if s.dialog_visible and not dialog_process then
            local path=temporary();local pipe=mp.get_property('options/input-ipc-server','')
            if pipe=='' then
                pipe='\\\\.\\pipe\\mpvnet-upscale-'..instance
                if not mp.set_property('options/input-ipc-server',pipe) then return end
            end
            if write_json(path,{schema=1,operation='window',request_id=instance..':window:'..sequence,
                parent_pid=mp.get_property_number('pid',0),pipe=pipe,dialog_token=s.dialog_token}) then
                local launched_token=s.dialog_token
                dialog_request=path
                dialog_process=mp.command_native_async({name='subprocess',args={expand('helpers/KitUpscale.exe'),'-RequestPath',path},
                    capture_stdout=true,capture_stderr=true,playback_only=false},function()
                    os.remove(path);dialog_process=nil;dialog_request=nil
                    -- Dismissing a failed UI process must not respawn indefinitely.
                    if s.dialog_visible and s.dialog_token==launched_token then
                        dialog(false)
                        if s.phase=='preparing' or s.phase=='loading' then api.cancel() end
                        if callbacks.notice then callbacks.notice('画面增强窗口已关闭。') end
                        changed()
                    end
                end)
            end
        end
    end)
    function api.shutdown()
        closing=true;timer:kill();generation=generation+1
        if job then stop_task(job);if job.async then mp.abort_async_command(job.async) end end
        if dialog_process then mp.abort_async_command(dialog_process) end
        if dialog_request then os.remove(dialog_request) end
        if activation then os.remove(activation) end
    end
    return api
end
return M
