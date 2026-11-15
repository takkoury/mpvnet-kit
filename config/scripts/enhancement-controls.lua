-- Rendering choice owner. The optional upscale module owns its vf and hwdec loan.
local mp = require('mp')
local utils = require('mp.utils')
local feedback_client = dofile(mp.command_native({'expand-path', '~~/script-modules/feedback.lua'})).new(mp)
local settings = dofile(mp.command_native({'expand-path', '~~/script-modules/user-settings.lua'}))
local upscale_module = dofile(mp.command_native({'expand-path', '~~/script-modules/upscale.lua'}))
local upscale, requested_manually
local deferred_preset, deferred_timer, schedule_deferred

local options = require('mp.options')
local msg = require('mp.msg')

local opts = {anime_verified = false}
options.read_options(opts, 'enhancement-controls')
local keys = {'scale', 'dscale', 'cscale', 'scale-antiring', 'deband',
    'deband-iterations', 'deband-threshold', 'deband-range', 'deband-grain', 'glsl-shaders'}
local chains = {
    ANIME_LIGHT = {'Anime4K_Clamp_Highlights.glsl', 'Anime4K_Restore_CNN_Soft_M.glsl',
        'Anime4K_Upscale_CNN_x2_M.glsl', 'Anime4K_AutoDownscalePre_x2.glsl',
        'Anime4K_AutoDownscalePre_x4.glsl', 'Anime4K_Upscale_CNN_x2_S.glsl'},
    ANIME_STRONG = {'Anime4K_Clamp_Highlights.glsl', 'Anime4K_Restore_CNN_VL.glsl',
        'Anime4K_Upscale_CNN_x2_VL.glsl', 'Anime4K_AutoDownscalePre_x2.glsl',
        'Anime4K_AutoDownscalePre_x4.glsl', 'Anime4K_Upscale_CNN_x2_M.glsl'},
}
local preset_field = settings.field('enhancement.default-preset')
local labels = {}
for _, choice in ipairs(preset_field.choices) do labels[choice.value] = choice.label end
local startup_preset, manually_selected = preset_field.default, false
local desired, applied, baseline = startup_preset, 'OFF', nil
local ready, last_error, shutting_down = false, nil, false
local error_reason, error_preset = nil, nil
local reason_text = {
    initializing = '增强功能尚未就绪', no_video = '无可增强的画面', renderer_unsupported = '当前显示方式不支持增强',
    hdr_source = '此增强不支持 HDR 视频', metadata_unknown = '无法增强\n无法识别视频色彩',
    anime_unverified = 'Anime4K 尚未启用', shader_missing = '缺少增强文件',
    settings_failed = '无法应用增强设置', rollback_failed = '画面设置还原失败',
    renderer_error = '画面增强失败', unavailable = '此增强不可用',
    source_unsupported = '首批超分支持 480p 及以下的 SDR 逐行动画', source_color = '无法识别视频色彩',
    filter_conflict = '请先关闭其他 VapourSynth 处理', preparing = '请先取消当前准备',
}

local function clone(value)
    if type(value) ~= 'table' then return value end
    local result = {}
    for key, entry in pairs(value) do result[key] = clone(entry) end
    return result
end

local function snapshot()
    local result = {}
    for _, key in ipairs(keys) do
        local value, err = mp.get_property_native('options/' .. key)
        if value == nil then return nil, key .. ': ' .. tostring(err) end
        result[key] = clone(value)
    end
    return result
end

local function shader_paths(name)
    local paths = {}
    for _, filename in ipairs(chains[name] or {}) do
        local path = mp.command_native({'expand-path', '~~/shaders/anime4k/' .. filename})
        local info = path and utils.file_info(path)
        if not info or not info.is_file then return nil end
        paths[#paths + 1] = path
    end
    return paths
end

local function availability()
    local vo = mp.get_property('current-vo')
    local renderer = ready and baseline ~= nil and (vo == 'gpu-next' or vo == 'gpu')
    local params = mp.get_property_native('video-params')
    local gamma = type(params) == 'table' and tostring(params.gamma or ''):lower() or ''
    local sigpeak = type(params) == 'table' and tonumber(params.sigpeak or params['sig-peak']) or nil
    -- CNN chains are verified only for SDR; unknown source metadata is not proof of SDR.
    local sdr = type(params) == 'table' and gamma ~= '' and gamma ~= 'auto'
        and gamma ~= 'pq' and gamma ~= 'hlg' and gamma ~= 'st2084'
        and (sigpeak == nil or sigpeak <= 1)
    local available = {OFF = ready and baseline ~= nil, QUALITY = renderer == true, SMOOTH = renderer == true,
        ANIME_LIGHT = renderer == true and sdr and opts.anime_verified and shader_paths('ANIME_LIGHT') ~= nil,
        ANIME_STRONG = renderer == true and sdr and opts.anime_verified and shader_paths('ANIME_STRONG') ~= nil}
    -- Reasons describe the existing gates; they do not change which presets can be selected.
    local vid = mp.get_property_native('vid')
    local no_video = vid == false or vid == 'no' or mp.get_property_native('idle-active') == true
        or (ready and type(params) ~= 'table')
    local base_reason = not available.OFF and (error_reason == 'settings_failed' and error_reason
        or (no_video and 'no_video' or 'initializing')) or nil
    local renderer_reason = base_reason or (not renderer and (no_video and 'no_video' or 'renderer_unsupported')) or nil
    local anime_reason = renderer_reason
    if not anime_reason then
        if gamma == 'pq' or gamma == 'hlg' or gamma == 'st2084' or (sigpeak and sigpeak > 1) then
            anime_reason = 'hdr_source'
        elseif not sdr then anime_reason = no_video and 'no_video' or 'metadata_unknown'
        elseif not opts.anime_verified then anime_reason = 'anime_unverified' end
    end
    local reasons = {OFF = base_reason, QUALITY = renderer_reason, SMOOTH = renderer_reason}
    for _, name in ipairs({'ANIME_LIGHT', 'ANIME_STRONG'}) do
        if not available[name] then reasons[name] = anime_reason or 'shader_missing' end
    end
    local source_ok, source_reason = false, 'initializing'
    if upscale then source_ok, source_reason = upscale.availability() end
    for name in pairs(upscale_module.names) do
        available[name] = renderer == true and source_ok and not upscale.busy()
        if not available[name] then
            reasons[name] = renderer_reason or source_reason or (upscale and upscale.busy() and 'preparing') or 'unavailable'
        end
    end
    if upscale and (upscale.state().phase=='preparing' or upscale.state().phase=='loading') then
        for name in pairs(available) do available[name]=false;reasons[name]='preparing' end
    end
    return available, reasons
end

local function publish()
    local available, reasons = availability()
    local texts={}
    for name,reason in pairs(reasons) do texts[name]=reason_text[reason] or reason_text.unavailable end
    mp.set_property_native('user-data/mpvnet/enhancement', {
        desired = desired, applied = applied, applied_scope = upscale_module.names[applied] and 'options+vf' or 'options',
        ready = ready, available = available, unavailable_reasons = reasons, error = last_error,
        unavailable_text = texts,
        error_reason = error_reason, error_preset = error_preset,
        anime_verified = opts.anime_verified,
        upscale = upscale and upscale.state() or nil,
    })
end

local function feedback(text, kind)
    if not shutting_down then feedback_client.show(text, kind) end
end

-- Set only file-local options: mpv restores the original values when this file ends.
-- Every preset owns the complete controlled group; disabled deband parameters come
-- from this file's baseline, so previous presets cannot leak their values.
local function values_for(name)
    local values = clone(baseline)
    if name ~= 'OFF' then
        values.scale, values.dscale, values.cscale = 'ewa_lanczos', 'mitchell', 'spline36'
        values['scale-antiring'], values.deband = 0.7, false
        values['glsl-shaders'] = chains[name] and shader_paths(name) or {}
        if name == 'SMOOTH' then
            values.deband = true
            values['deband-iterations'], values['deband-threshold'] = 1, 32
            values['deband-range'], values['deband-grain'] = 16, 0
        end
    end
    return values
end

local function write_group(values)
    for _, key in ipairs(keys) do
        local value = clone(values[key])
        -- mpv 0.41 reports SCALER_INHERIT as native 0, but choice setters take
        -- its registered empty-string name (cdscale_filters in gpu/video.c).
        if (key == 'cscale' or key == 'dscale') and value == 0 then value = '' end
        local ok, err = mp.set_property_native('file-local-options/' .. key, value)
        if not ok then return false, key .. ': ' .. tostring(err) end
    end
    return true
end

local function apply(name, quiet)
    if not quiet then deferred_preset=nil end
    local available, reasons = availability()
    if not available[name] then
        last_error = 'Preset unavailable: ' .. tostring(name)
        error_reason, error_preset = reasons[name] or 'unavailable', name
        publish()
        if not quiet then feedback(reason_text[error_reason], 'error') end
        return false
    end
    if upscale_module.names[name] then
        requested_manually = not quiet
        return upscale.select(name)
    end
    if upscale and not upscale.clear() then
        applied=nil;error_reason='rollback_failed';publish()
        if not quiet then feedback(reason_text.rollback_failed,'error') end
        return false
    end
    local previous, err = snapshot()
    if not previous then
        last_error = err
        error_reason, error_preset = 'settings_failed', name
        publish()
        if not quiet then feedback(reason_text[error_reason], 'error') end
        return false
    end
    local ok
    ok, err = write_group(values_for(name))
    if not ok then
        local restored, restore_error = write_group(previous)
        if not restored then applied = nil end
        last_error = err .. (restored and '' or '; rollback: ' .. tostring(restore_error))
        error_reason, error_preset = restored and 'settings_failed' or 'rollback_failed', name
        msg.error(last_error)
        publish()
        if not quiet then feedback(reason_text[error_reason], 'error') end
        return false
    end
    applied, last_error = name, nil
    error_reason, error_preset = nil, nil
    if not quiet then desired, manually_selected = name, true end
    publish()
    if not quiet then feedback(name == 'OFF' and '画面设置已还原' or ('已选择' .. labels[name]), 'success') end
    return true
end

-- file-loaded can precede usable video metadata, or an old cancelled helper's
-- exit. Keep one startup intent for this media, never an automatic failure retry.
schedule_deferred=function()
    if not deferred_preset or deferred_timer or not ready or not upscale or upscale.busy() then return end
    local available=availability()
    if not available[deferred_preset] then return end
    deferred_timer=mp.add_timeout(0,function()
        deferred_timer=nil
        if deferred_preset and ready and not upscale.busy() then
            local choices=availability()
            if choices[deferred_preset] then
                local name=deferred_preset;deferred_preset=nil;apply(name,true)
            end
        end
    end)
end

upscale = upscale_module.new(mp,utils,{
    changed=function() publish();schedule_deferred() end,
    notice=function(text) feedback(text,'notice') end,
    begin=function(name)
        if not baseline or not write_group(baseline) then return false end
        desired,applied=name,'OFF'
        if requested_manually then manually_selected=true end
        last_error,error_reason,error_preset=nil,nil,nil
        publish();return true
    end,
    restore=function()
        local ok=baseline and write_group(baseline)
        applied=ok and 'OFF' or nil
        return ok==true
    end,
    active=function(name)
        if not baseline or not write_group(values_for(name)) then return false end
        desired,applied=name,name;last_error,error_reason,error_preset=nil,nil,nil
        publish();feedback('已启用 '..labels[name],'success');return true
    end,
    failed=function(code)
        desired='OFF';error_reason=code;error_preset=upscale.state().requested
        if code=='restore_failed' then applied=nil end
        last_error='Upscaling failed: '..tostring(code)
    end,
    cancelled=function(ok)
        desired='OFF';manually_selected=true
        error_reason=ok and nil or 'rollback_failed'
        feedback(ok and '已取消准备，恢复原始画面' or reason_text.rollback_failed,ok and 'action' or 'error')
    end,
})

mp.register_script_message('upscale-action',function(action)
    if action=='enable-requested' or action=='retry' then requested_manually=true;deferred_preset=nil end
    upscale.action(action)
end)
mp.register_script_message('upscale-dialog-action',function(token,action)
    if action=='retry' then requested_manually=true;deferred_preset=nil end
    upscale.dialog_action(token,action)
end)
mp.register_script_message('pause-intent',function() upscale.manual_pause() end)
mp.add_hook('on_unload',0,function() deferred_preset=nil;upscale.retire() end)
mp.add_hook('on_before_start_file',0,function() upscale.before_file() end)
mp.add_hook('on_load',90,function()
    if not upscale.scrub_resumed_filter() then feedback(reason_text.rollback_failed,'error') end
end)

mp.register_script_message('set-preset', function(name)
    name = tostring(name or ''):upper()
    if not labels[name] then feedback(reason_text.unavailable, 'error'); return end
    apply(name, false)
end)

mp.register_event('start-file', function()
    deferred_preset=nil
    upscale.retire()
    baseline, ready, applied, last_error = nil, false, nil, nil
    error_reason, error_preset = nil, nil
    publish()
end)
mp.add_hook('on_preloaded', 100, function()
    baseline, last_error = snapshot()
    error_reason = not baseline and 'settings_failed' or nil
    publish()
end)
mp.register_event('file-loaded', function()
    ready = baseline ~= nil
    applied = ready and 'OFF' or nil
    -- Fresh files get a fresh baseline after mpv's previous file-local reset.
    -- Preserve the desired instance preset even when this file lacks a GPU VO.
    if ready and upscale_module.names[desired] then deferred_preset=desired;publish();schedule_deferred()
    elseif ready and desired ~= 'OFF' then apply(desired, true) else publish() end
end)
local function refresh_availability()
    local available, reasons = availability()
    if ready and upscale_module.names[applied] then
        local ok,code=upscale.availability()
        if not ok then upscale.invalidate(code) else publish() end
        return
    end
    if ready and applied and applied ~= 'OFF' and not available[applied] then
        local previous = applied
        local restored, err = write_group(baseline)
        applied = restored and 'OFF' or nil
        error_reason, error_preset = restored and reasons[previous] or 'rollback_failed', previous
        last_error = restored and reason_text[error_reason] or tostring(err)
        publish()
    elseif ready and desired ~= 'OFF' and not upscale_module.names[desired] and applied == 'OFF' and available[desired] then
        apply(desired, true)
    else publish() end
    schedule_deferred()
end
mp.observe_property('current-vo', 'string', refresh_availability)
mp.observe_property('video-params', 'native', refresh_availability)
-- Option acceptance is not a compilation certificate. A GPU renderer error while
-- an Anime4K chain is selected withdraws that selection and restores this file's
-- baseline. Pinned chains still require the separate real-renderer verification.
mp.enable_messages('error')
mp.register_event('log-message', function(event)
    upscale.on_error(event)
    if not ready or not chains[applied] or event.level ~= 'error' then return end
    local prefix = tostring(event.prefix or '')
    if not prefix:find('vo/gpu', 1, true) and not prefix:find('libplacebo', 1, true) then return end
    local previous = applied
    desired, applied = 'OFF', nil
    local restored, err = write_group(baseline)
    if restored then applied = 'OFF' end
    last_error = 'GPU renderer error: ' .. tostring(event.text or '')
        .. (restored and '' or '; rollback: ' .. tostring(err))
    error_reason, error_preset = restored and 'renderer_error' or 'rollback_failed', previous
    publish()
    feedback(reason_text[error_reason], 'error')
end)
mp.register_event('end-file', function()
    deferred_preset=nil
    upscale.retire()
    baseline, ready, applied = nil, false, nil
    publish()
end)
mp.register_event('shutdown', function()
    shutting_down = true
    if deferred_timer then deferred_timer:kill() end
    upscale.shutdown()
    mp.del_property('user-data/mpvnet/enhancement')
end)
publish()

settings.owner(mp, {
    id=preset_field.id, initialize_on_ready=true, default_source='套件默认原始画面',
    -- Effective here is this instance's startup choice, independent of media
    -- availability and temporary choices in the enhancement menu.
    read=function() return startup_preset end,
    write=function(value)
        startup_preset = value
        if not manually_selected then
            desired = value
            if ready and upscale_module.names[desired] then deferred_preset=desired;publish();schedule_deferred()
            elseif ready and desired ~= 'OFF' then apply(desired, true) else publish() end
        end
        return true
    end,
})
