local time, encoded, wires, files = 0, 0, {}, {}
local properties={pid=42,pause=false,hwdec='auto-safe',vf={},
    ['video-params']={w=640,h=480,gamma='bt.1886',primaries='bt.601-525',colormatrix='bt.601',colorlevels='limited',['chroma-location']='mpeg2/4/h264'},
    ['video-out-params']={w=640,h=480},['options/input-ipc-server']='pipe'}
local observers,tick,processes,commands,registered={},{},{},{},{}
local events={began=0,configured=0,active=0,restored=0,cancelled=0,failed=0}
local fail_remove=false
local utils={}
function utils.format_json(value) encoded=encoded+1;local key='wire'..encoded;wires[key]=value;return key end
function utils.parse_json(value) return wires[value] end
function utils.file_info(path) return {is_file=true} end
files['C:/fixture/upscale/components.json']=utils.format_json({bundle_id='trt-10.16-v1',download_bytes=2000,expanded_bytes=3000})
files['C:/fixture/upscale/models.json']=utils.format_json(upscale_catalog)
local io={open=function(path,mode)
    if mode=='rb' and not files[path] then return nil end
    return {read=function() return files[path] end,write=function(self,value) files[path]=value;return self end,close=function() return true end}
end}
local os={getenv=function() return 'C:/temp' end,remove=function(path) files[path]=nil end}
local mp={
    get_time=function() return time end,
    get_property_number=function(name,default) return properties[name] or default end,
    get_property_bool=function(name,default) if properties[name]~=nil then return properties[name] end;return default end,
    get_property_native=function(name) return properties[name] end,
    get_property=function(name,default)
        if name:find('user-data/',1,true)==1 and type(properties[name])=='string' then return utils.format_json(properties[name]) end
        return properties[name] or default
    end,
    set_property=function(name,value) if name=='file-local-options/hwdec' then name='hwdec' end;properties[name]=value;return true end,
    set_property_bool=function(name,value) properties[name]=value;if observers[name] then observers[name](name,value) end;return true end,
    command_native=function(args) return (args[2]:gsub('~~/','C:/fixture/')) end,
    observe_property=function(name,_,cb) observers[name]=cb end,
    register_event=function(name,cb) registered[name]=cb end,
    add_periodic_timer=function(_,cb) tick=cb;return {kill=function() tick=function() end end} end,
    add_timeout=function(_,cb) return {kill=function() end,run=cb} end,
    abort_async_command=function(id) processes[id].aborted=true end,
}
function mp.command_native_async(options,cb)
    local request=utils.parse_json(files[options.args[3]])
    processes[#processes+1]={request=request,options=options,callback=cb}
    return #processes
end
function mp.commandv(...)
    local args={...};commands[#commands+1]=args
    if args[1]=='vf' and args[2]=='append' then
        local count,data=args[3]:match('user%-data=%%(%d+)%%(.*)')
        properties.vf[#properties.vf+1]={name='vapoursynth',label='mpvnet-upscale',enabled=true,
            params={file='C:/fixture/upscale/runtime.vpy',['user-data']=data:sub(1,tonumber(count))}}
    elseif args[1]=='vf' and args[2]=='remove' then
        if fail_remove then return false end
        for i=#properties.vf,1,-1 do if properties.vf[i].label=='mpvnet-upscale' then table.remove(properties.vf,i) end end
    end
    return true
end
-- MODULE HERE
local api=module.new(mp,utils,{
    changed=function() end,
    begin=function() events.began=events.began+1;return true end,
    restore=function() events.restored=events.restored+1;return true end,
    configure=function() events.configured=events.configured+1;return true end,
    active=function() events.active=events.active+1;return true end,
    failed=function() events.failed=events.failed+1 end,
    cancelled=function() events.cancelled=events.cancelled+1 end,
},module.read_models(mp,utils))
local function process(operation)
    for i=#processes,1,-1 do
        if processes[i].request.operation==operation and not processes[i].completed then return processes[i] end
    end
    error('no pending process '..operation)
end
local function complete(operation,values)
    local p=process(operation);p.completed=true
    values.request_id=p.request.request_id
    p.callback(true,{status=values.ok and 0 or 1,stdout=utils.format_json(values)})
end
local function ready_probe(ready,model_errors)
    complete('probe',{ok=true,phase='probed',component_ready=ready,device_id=0,model_errors=model_errors or {},
        bundle_root='C:/fixture/components/ai-upscale/bundles/trt-10.16-v1'})
end
local function start(name,model_errors)
    assert(api.select(name));ready_probe(true,model_errors)
    properties['user-data/mpvnet/upscale-host']=utils.format_json({status='idle',serial=0})
    tick()
    local serial=tonumber(commands[#commands][4])
    properties['user-data/mpvnet/upscale-host']=utils.format_json({status='ready',serial=serial})
    tick();assert(api.state().phase=='preparing')
end
local function success()
    complete('prepare',{ok=true,phase='ready',engine_path='C:/cache/model.engine',padded_width=640,padded_height=480})
end
local function first_frame()
    local vf=properties.vf[#properties.vf];local path=vf.params['user-data']
    files[path..'.ready']=utils.format_json({activation_id=path})
end
function missing_components_install_does_not_activate()
    assert(api.select('CUGAN'));ready_probe(false)
    assert(api.state().phase=='missing' and api.state().requested=='CUGAN')
    assert(events.began==0 and not properties.pause)
    api.action('install');api.retire()
    complete('install',{ok=true,phase='ready',component_ready=true,device_id=0})
    assert(api.state().component.ready and events.began==0 and events.active==0)
    assert(not properties.pause)
end
function span_model_errors_do_not_block_animation_or_request_components()
    assert(api.select('SPAN'));ready_probe(false,{SPAN='model_missing'})
    assert(api.state().phase=='failed' and api.state().requested=='SPAN')
    assert(api.state().error_text=='配置包中的写实模型缺失，请修复配置包。')
    assert(api.state().model_errors.SPAN=='model_missing' and #processes==1)
    assert(api.select('SPAN'));ready_probe(true,{SPAN='model_integrity'})
    assert(api.state().error_text=='配置包中的写实模型已更改，请修复配置包。')
    assert(api.state().component.ready and api.state().component.error_text=='')
    start('CUGAN',{SPAN='model_integrity'})
    assert(process('prepare').request.model=='CUGAN' and api.state().model_errors.ESRGAN==nil)
    api.cancel();complete('prepare',{ok=false,error_reason='cancelled'})
    start('ESRGAN',{SPAN='model_missing'})
    assert(process('prepare').request.model=='ESRGAN')
end
function span_uses_existing_first_frame_and_restore_path()
    start('SPAN')
    assert(process('prepare').request.model=='SPAN' and api.state().requested_label=='NomosUni SPAN · 写实')
    success();properties['video-out-params']={w=1280,h=960};tick()
    assert(api.state().phase=='loading' and events.active==0)
    first_frame();registered['playback-restart']();tick()
    assert(api.state().phase=='active' and events.active==1)
    assert(api.clear() and #properties.vf==0 and properties.hwdec=='auto-safe')
end
function cancel_waits_for_exit_and_preserves_manual_pause()
    start('CUGAN');assert(properties.pause)
    api.manual_pause();api.cancel()
    assert(api.state().phase=='preparing' and events.cancelled==0)
    assert(files[process('prepare').options.args[3]..'.cancel']=='cancel')
    complete('prepare',{ok=false,error_reason='cancelled'})
    assert(events.cancelled==1 and events.restored==1 and properties.pause)
    assert(api.state().phase=='idle')
end
function old_media_completion_cannot_activate_new_media()
    start('CUGAN');api.retire();assert(api.select('ESRGAN'))
    success()
    assert(events.active==0 and #properties.vf==0 and events.began==1)
    assert(process('probe').request.operation=='probe')
end
function only_actual_output_marks_active_and_external_hwdec_survives()
    properties.vf={{name='hflip',label='user-filter'}}
    start('ESRGAN');success();tick()
    assert(api.state().phase=='loading' and events.active==0 and properties.hwdec=='auto-copy')
    properties['video-out-params']={w=1280,h=960};tick();assert(events.active==0)
    first_frame();registered['playback-restart']();tick()
    assert(events.active==1 and api.state().phase=='active' and not properties.pause)
    properties.hwdec='no';assert(api.clear())
    assert(properties.hwdec=='no' and #properties.vf==1 and properties.vf[1].label=='user-filter')
end
function removed_filter_withdraws_active_and_releases_hwdec()
    start('CUGAN');success();first_frame();properties['video-out-params']={w=1280,h=960};registered['playback-restart']();tick()
    properties.vf={};properties['video-out-params']={w=640,h=480};tick()
    assert(api.state().phase=='failed' and events.failed==1 and properties.hwdec=='auto-safe')
end
function activation_reads_current_color_interpretation()
    start('CUGAN');properties['video-params'].colormatrix='bt.709';properties['video-params'].colorlevels='full'
    success()
    local path=properties.vf[#properties.vf].params['user-data'];local request=utils.parse_json(files[path])
    assert(request.matrix=='709' and request.levels=='full')
end
function component_probe_survives_media_change()
    api.action('probe');api.retire();ready_probe(true)
    assert(api.state().component.ready and api.state().component.phase=='ready' and events.began==0)
end
function resume_reclaims_only_new_managed_signature()
    local saved={name='vapoursynth',label='mpvnet-upscale',params={file='D:/old/upscale/runtime.vpy',
        ['user-data']='C:/temp/mpvnet-upscale-123-456-7.json',['buffered-frames']='4',['concurrent-frames']='4'}}
    api.before_file();properties.vf={saved};assert(api.scrub_resumed_filter());assert(#properties.vf==0)
    properties.vf={saved};api.before_file();assert(api.scrub_resumed_filter());assert(#properties.vf==1)
end
function failed_removal_keeps_ownership_for_explicit_retry()
    start('CUGAN');success();first_frame();properties['video-out-params']={w=1280,h=960};registered['playback-restart']();tick()
    local request=properties.vf[1].params['user-data'];fail_remove=true
    assert(not api.clear());assert(#properties.vf==1 and files[request] and properties.hwdec=='auto-copy')
    fail_remove=false;assert(api.clear());assert(#properties.vf==0 and not files[request] and properties.hwdec=='auto-safe')
end
function old_dialog_exit_does_not_hide_new_dialog()
    api.select('CUGAN');ready_probe(false);tick()
    local old=process('window');local token=api.state().dialog_token
    api.action('dismiss');api.select('ESRGAN');ready_probe(false)
    assert(api.state().dialog_token~=token and api.state().dialog_visible)
    old.completed=true;old.callback(true,{status=0,stdout=''} )
    assert(api.state().dialog_visible)
    tick();assert(process('window').request.dialog_token==api.state().dialog_token)
end
function cancel_host_wait_ignores_late_ready()
    api.select('CUGAN');ready_probe(true)
    api.cancel()
    properties['user-data/mpvnet/upscale-host']=utils.format_json({status='ready',serial=1})
    tick()
    assert(events.began==0 and api.state().phase=='idle' and not properties.pause)
end

function waits_for_final_renderer_before_activation_or_resume()
    start('SPAN');success()
    assert(events.configured==1 and properties.pause)
    properties['video-out-params']={w=1280,h=960}
    registered['playback-restart']();tick()
    assert(events.active==0 and api.state().phase=='loading')
    first_frame();tick()
    assert(events.active==0 and properties.pause)
    registered['playback-restart']();tick()
    assert(events.active==1 and not properties.pause)
    assert(api.clear())
    start('SPAN');success();first_frame();tick()
    assert(events.active==1 and properties.pause and api.state().phase=='loading')
    api.cancel();registered['playback-restart']();tick()
    assert(events.active==1 and api.state().phase=='idle')
end
