-- Optional per-file rendering presets. No color, VO, hardware-decoding or FPS changes.
local mp = require('mp')
local utils = require('mp.utils')
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
local labels = {OFF = 'ORIGINAL', QUALITY = 'SCALING', SMOOTH = 'DEBAND', ANIME_LIGHT = 'ANIME4K-L',
    ANIME_STRONG = 'ANIME4K-S'}
local desired, applied, baseline = 'OFF', 'OFF', nil
local ready, last_error, shutting_down = false, nil, false

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
    return {OFF = ready and baseline ~= nil, QUALITY = renderer == true, SMOOTH = renderer == true,
        ANIME_LIGHT = renderer == true and sdr and opts.anime_verified and shader_paths('ANIME_LIGHT') ~= nil,
        ANIME_STRONG = renderer == true and sdr and opts.anime_verified and shader_paths('ANIME_STRONG') ~= nil}
end

local function publish()
    mp.set_property_native('user-data/mpvnet/enhancement', {
        desired = desired, applied = applied, applied_scope = 'options',
        ready = ready, available = availability(), error = last_error,
        anime_verified = opts.anime_verified,
    })
end

local function feedback(text)
    if not shutting_down then mp.osd_message('ENHANCEMENT: ' .. text, 1) end
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

local function apply(name, quiet, remember)
    if not availability()[name] then
        last_error = 'Preset unavailable: ' .. tostring(name)
        publish()
        if not quiet then feedback('UNAVAILABLE') end
        return false
    end
    local previous, err = snapshot()
    if not previous then
        last_error = err
        publish()
        if not quiet then feedback('FAILED') end
        return false
    end
    local ok
    ok, err = write_group(values_for(name))
    if not ok then
        local restored, restore_error = write_group(previous)
        if not restored then applied = nil end
        last_error = err .. (restored and '' or '; rollback: ' .. tostring(restore_error))
        msg.error(last_error)
        publish()
        if not quiet then feedback('FAILED') end
        return false
    end
    applied, last_error = name, nil
    if remember then desired = name end
    publish()
    if not quiet then feedback(labels[name]) end
    return true
end

mp.register_script_message('set-preset', function(name)
    name = tostring(name or ''):upper()
    if not labels[name] then feedback('UNAVAILABLE'); return end
    apply(name, false, true)
end)

mp.register_event('start-file', function()
    baseline, ready, applied, last_error = nil, false, nil, nil
    publish()
end)
mp.add_hook('on_preloaded', 100, function()
    baseline, last_error = snapshot()
    publish()
end)
mp.register_event('file-loaded', function()
    ready = baseline ~= nil
    applied = ready and 'OFF' or nil
    -- Fresh files get a fresh baseline after mpv's previous file-local reset.
    -- Preserve the desired instance preset even when this file lacks a GPU VO.
    if ready and desired ~= 'OFF' then apply(desired, true, false) else publish() end
end)
local function refresh_availability()
    if ready and applied and applied ~= 'OFF' and not availability()[applied] then
        local restored, err = write_group(baseline)
        applied = restored and 'OFF' or nil
        last_error = restored and 'GPU renderer unavailable' or tostring(err)
        publish()
    elseif ready and desired ~= 'OFF' and applied == 'OFF' and availability()[desired] then
        apply(desired, true, false)
    else publish() end
end
mp.observe_property('current-vo', 'string', refresh_availability)
mp.observe_property('video-params', 'native', refresh_availability)
-- Option acceptance is not a compilation certificate. A GPU renderer error while
-- an Anime4K chain is selected withdraws that selection and restores this file's
-- baseline. Pinned chains still require the separate real-renderer verification.
mp.enable_messages('error')
mp.register_event('log-message', function(event)
    if not ready or not chains[applied] or event.level ~= 'error' then return end
    local prefix = tostring(event.prefix or '')
    if not prefix:find('vo/gpu', 1, true) and not prefix:find('libplacebo', 1, true) then return end
    desired, applied = 'OFF', nil
    local restored, err = write_group(baseline)
    if restored then applied = 'OFF' end
    last_error = 'GPU renderer error: ' .. tostring(event.text or '')
        .. (restored and '' or '; rollback: ' .. tostring(err))
    publish()
    feedback('FAILED')
end)
mp.register_event('end-file', function()
    baseline, ready, applied = nil, false, nil
    publish()
end)
mp.register_event('shutdown', function()
    shutting_down = true
    mp.del_property('user-data/mpvnet/enhancement')
end)
publish()
