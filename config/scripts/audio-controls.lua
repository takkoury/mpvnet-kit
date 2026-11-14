-- Optional instance-local audio processing. Only the owned af label is modified.
local mp = require('mp')
local msg = require('mp.msg')
local feedback = dofile(mp.command_native({'expand-path', '~~/script-modules/feedback.lua'})).new(mp)
local settings = dofile(mp.command_native({'expand-path', '~~/script-modules/user-settings.lua'}))
local field = settings.field('audio.default-mode')
local property, tag = 'user-data/mpvnet/audio', 'mpvnet-night-audio'
local graph = 'acompressor=threshold=0.0630957344:ratio=3:attack=20:release=250:makeup=1:mix=0.5'
local filter = '@' .. tag .. ':lavfi=[' .. graph .. ']'
local expected_filter = {name = 'lavfi', label = tag, enabled = true, params = {graph = graph}}
local startup_mode, desired, manually_selected = field.default, field.default, false
local loaded, owned, blocked, busy, failure = false, nil, false, false, nil
local reported_unavailable, track_id, external_override, resume_label_allowed
local format_watch, format_timer, format_attempts = false, nil, 0
local reconcile
local reasons = {
    initializing = '声音处理尚未就绪', no_audio = '当前没有可用的音频',
    multichannel = '夜间观看仅支持双声道音轨', passthrough = '音频直通时无法使用夜间观看',
    read_failed = '无法读取当前声音处理', write_failed = '无法启用夜间观看',
    restore_failed = '声音处理还原失败', filter_changed = '声音处理已被其他操作修改',
    label_conflict = '当前已有同名声音处理，无法接管',
}
local function clone(value)
    if type(value) ~= 'table' then return value end
    local result = {}; for key, item in pairs(value) do result[key] = clone(item) end; return result
end
local function equal(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= 'table' then return a == b end
    for key, value in pairs(a) do if not equal(value, b[key]) then return false end end
    for key in pairs(b) do if a[key] == nil then return false end end
    return true
end
local function read_chain()
    local chain, err = mp.get_property_native('af')
    if type(chain) ~= 'table' then return nil, err or 'af is unavailable' end
    return chain
end
local function labelled(chain)
    local found, count
    count = 0
    for _, entry in ipairs(chain or {}) do
        if type(entry) == 'table' and entry.label == tag then found, count = entry, count + 1 end
    end
    return found, count
end
local function media_reason()
    if not loaded then return 'initializing' end
    if type(mp.get_property_native('current-tracks/audio')) ~= 'table' then return 'no_audio' end
    local input, output = mp.get_property_native('audio-params'), mp.get_property_native('audio-out-params')
    local input_format = type(input) == 'table' and tostring(input.format or '') or ''
    local output_format = type(output) == 'table' and tostring(output.format or '') or ''
    if input_format:find('^spdif') or output_format:find('^spdif') then return 'passthrough' end
    local track = mp.get_property_native('current-tracks/audio')
    local source_channels = type(track) == 'table' and tonumber(track['demux-channel-count'])
    if source_channels and source_channels > 0 and source_channels ~= 2 then return 'multichannel' end
    -- Reconfiguration can briefly withdraw format properties. Do not tear down a
    -- valid filter during its own graph rebuild; audio-reconfig will revisit it.
    if type(input) ~= 'table' or type(output) ~= 'table' then return 'initializing' end
    if input['channel-count'] ~= 2 then return 'multichannel' end
    if input_format == '' or output_format == '' then return 'initializing' end
end
local function publish()
    local chain = read_chain()
    local entry, count = labelled(chain)
    local media = media_reason()
    local reason = not chain and 'read_failed' or media
    if count > 0 and not owned then reason = 'label_conflict' end
    local applied
    if loaded and chain and media ~= 'no_audio' and media ~= 'initializing' then
        if owned and count == 1 and equal(entry, owned) and entry.enabled ~= false then applied = 'NIGHT'
        elseif count == 0 then applied = 'OFF' end
    end
    mp.set_property_native(property, {
        desired = desired, applied = applied, applied_scope = 'filter', ready = loaded,
        available = {OFF = true, NIGHT = reason == nil},
        unavailable_reasons = {OFF = not chain and 'read_failed' or count > 0 and not owned and 'label_conflict' or nil, NIGHT = reason},
        unavailable_text = reason and reasons[reason], error = failure and failure.detail,
        error_reason = failure and failure.reason,
    })
end
local function fail(reason, detail, quiet)
    failure = {reason = reason, detail = detail or reasons[reason]}
    if detail then msg.error(detail) end
    publish()
    if not quiet then feedback.show(reasons[reason], 'error') end
    return false
end
local function check_owner(chain)
    if not owned then return true end
    local entry, count = labelled(chain)
    if count == 1 and equal(entry, owned) then return true end
    -- Removal, replacement, edits, and disabling from another controller retire
    -- ownership. A later reconfig event must not silently add our processing back.
    owned, blocked, external_override = nil, true, true
    failure = {reason = 'filter_changed', detail = reasons.filter_changed}
    return false
end
local function remove_owned(quiet)
    if not owned then return true end
    local chain, err = read_chain()
    if not chain then return fail('read_failed', err, quiet) end
    local _, count = labelled(chain)
    if count == 0 then owned = nil; return true end
    if not check_owner(chain) then return fail('filter_changed', nil, quiet) end
    local ok, command_error = mp.commandv('af', 'remove', '@' .. tag)
    if ok then owned = nil end
    local after, read_error = read_chain()
    local _, remaining = labelled(after)
    if after and remaining == 0 then owned = nil end
    if not ok or not after or remaining ~= 0 then
        return fail('restore_failed', command_error or read_error or 'owned filter remains', quiet)
    end
    return true
end
local function add_owned(quiet)
    local chain, err = read_chain()
    if not chain then return fail('read_failed', err, quiet) end
    if not check_owner(chain) and quiet then return fail('filter_changed', nil, true) end
    local _, count = labelled(chain)
    if owned then return true end
    if count > 0 then return fail('label_conflict', nil, quiet) end
    local ok, command_error = mp.commandv('af', 'add', filter)
    if ok then
        -- The command succeeded after checking the label was absent. Keep its
        -- expected identity even if the immediate read fails, so OFF/unload can
        -- later remove it. A readable external replacement still retires ownership.
        owned = clone(expected_filter)
    end
    local after, read_error = read_chain()
    local entry, added = labelled(after)
    if added == 1 and equal(entry, expected_filter) then
        owned = clone(entry)
        if ok then return true end
        -- A failed command may still have changed the graph. Roll back only the
        -- exact label just observed, never a copy of the user's complete chain.
        if not remove_owned(true) then return fail('restore_failed', command_error, quiet) end
    end
    if after and owned and (added ~= 1 or not equal(entry, owned)) then owned = nil end
    return fail('write_failed', command_error or read_error or 'filter readback differs', quiet)
end
local function format_changed() if reconcile then reconcile() end end
local function cancel_format_wait()
    if format_timer then format_timer:kill(); format_timer = nil end
    if format_watch then mp.unobserve_property(format_changed); format_watch = false end
end
local function await_format()
    if format_watch then return end
    -- Some same-format track switches reuse the AO without a second reconfig
    -- event. Wait only while its decoder format is missing. Paused switches get
    -- up to two seconds of bounded retries; later progress can finish the wait.
    format_watch, format_attempts = true, 0
    mp.observe_property('time-pos', 'number', format_changed)
    format_timer = mp.add_periodic_timer(.1, function()
        format_attempts = format_attempts + 1
        if format_attempts >= 20 and format_timer then format_timer:kill(); format_timer = nil end
        format_changed()
    end)
end
reconcile = function()
    if busy then return end
    busy = true
    local chain, err = read_chain()
    if not chain then fail('read_failed', err, true)
    elseif not check_owner(chain) then publish()
    elseif not loaded then publish()
    else
        local reason = media_reason()
        if desired == 'NIGHT' and not blocked and reason == 'initializing'
            and type(mp.get_property_native('current-tracks/audio')) == 'table' then await_format()
        else cancel_format_wait() end
        if desired == 'OFF' then
            if remove_owned(true) then failure = nil end
        elseif reason and reason ~= 'initializing' then
            if remove_owned(true) and reason ~= reported_unavailable then
                reported_unavailable = reason
                if reason ~= 'no_audio' then feedback.show(reasons[reason] .. '，暂用原始声音', 'notice') end
            end
        elseif not reason and not blocked then
            if add_owned(true) then failure, reported_unavailable = nil, nil
            else blocked = true end
        end
        publish()
    end
    busy = false
end
mp.register_script_message('set-mode', function(name)
    name = tostring(name or ''):upper()
    if name ~= 'OFF' and name ~= 'NIGHT' then return end
    if name == 'OFF' then
        -- Even if cleanup cannot be confirmed, a request to turn processing off
        -- must prevent a later format notification from enabling it again.
        desired, manually_selected = 'OFF', true
        cancel_format_wait()
    end
    local chain, err = read_chain()
    if not chain then return fail('read_failed', err, false) end
    check_owner(chain)
    local _, count = labelled(chain)
    if count > 0 and not owned then return fail('label_conflict', nil, false) end
    if name == 'NIGHT' then
        local reason = media_reason()
        if reason then return fail(reason, nil, false) end
    end
    busy = true
    local ok = name == 'NIGHT' and add_owned(false) or name == 'OFF' and remove_owned(false)
    busy = false
    if not ok then return end
    desired, manually_selected, blocked, failure, external_override = name, true, false, nil, false
    reported_unavailable = nil
    publish()
    feedback.show(name == 'NIGHT' and '已启用夜间观看' or '已撤销套件声音处理', 'success')
end)
mp.add_hook('on_before_start_file', 50, function()
    local chain = read_chain()
    local _, count = labelled(chain)
    resume_label_allowed = chain ~= nil and count == 0
end)
mp.add_hook('on_load', 50, function()
    loaded, track_id = false, nil
    cancel_format_wait()
    -- af commands preserve other filters, including changes made during the last
    -- media. Do not mark the whole af option file-local and roll those edits back.
    busy = true
    local cleaned = remove_owned(true)
    -- mpv can save af before on_unload. Reclaim only a newly loaded exact kit
    -- fingerprint, not a pre-existing user label or an edited/disabled entry.
    if cleaned and resume_label_allowed and not external_override then
        local chain = read_chain()
        local entry, count = labelled(chain)
        if count == 1 and equal(entry, expected_filter) then
            owned = clone(entry); cleaned = remove_owned(true)
        end
    end
    busy = false
    blocked, reported_unavailable = external_override or not cleaned, nil
    if cleaned and not external_override then failure = nil end
    publish()
end)
mp.register_event('file-loaded', function()
    loaded = true
    local track = mp.get_property_native('current-tracks/audio')
    track_id = type(track) == 'table' and track.id or nil
    reconcile()
end)
mp.register_event('audio-reconfig', reconcile)
-- Gapless playback can reuse the AO before the new decoder's format is known.
-- playback-restart also covers the first settled frame after loading or seeking.
mp.register_event('playback-restart', reconcile)
mp.observe_property('current-tracks/audio', 'native', function()
    local track = mp.get_property_native('current-tracks/audio')
    local id = type(track) == 'table' and track.id or nil
    if id == track_id then return end
    track_id = id; cancel_format_wait()
    if loaded and owned then busy = true; remove_owned(true); busy = false end
    reconcile()
end)
mp.observe_property('af', 'native', function()
    if busy then return end
    local chain = read_chain()
    if chain then check_owner(chain) end
    if chain and owned and desired == 'OFF' then reconcile() else publish() end
end)
-- Synchronous cleanup must precede mpv's per-file option backup restoration and
-- the next file's profiles. An asynchronous end-file handler can see the next
-- chain, lose ownership, and leave our label in a backup that later resurfaces.
mp.add_hook('on_unload', 50, function()
    cancel_format_wait()
    loaded = false; busy = true; remove_owned(true); busy = false; publish()
end)
mp.register_event('shutdown', function() cancel_format_wait(); mp.del_property(property) end)
publish()
settings.owner(mp, {
    id = field.id, initialize_on_ready = true, default_source = '套件默认原始声音',
    read = function() return startup_mode end,
    write = function(value)
        startup_mode = value
        if not manually_selected then desired = value; reconcile() end
        return true
    end,
})
