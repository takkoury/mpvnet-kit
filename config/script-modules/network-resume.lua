-- One in-memory reload target. VOD carries a position and a source identity;
-- a live room keeps only its original queue entry and reopens at the live edge.
local M = {}

function M.new(mp, resume_source, show_position, part_changed, playing_live)
    local pending, unloading, next_load

    local function matches(index, point)
        if index < 0 then return false end
        local entry = 'playlist/' .. index .. '/'
        return mp.get_property_native(entry .. 'id') == point.id
            and mp.get_property(entry .. 'filename') == point.path
    end

    local function entry_target(position, source)
        local index = mp.get_property_number('playlist-playing-pos', -1)
        if index < 0 then return end
        local target = {id=mp.get_property_native('playlist/' .. index .. '/id'),
            path=mp.get_property('path'), position=position, source=source}
        if target.id and target.path and matches(index, target) then return target end
    end

    local function checkpoint()
        if playing_live() then return entry_target() end
        if not mp.get_property_bool('demuxer-via-network') or not mp.get_property_bool('seekable') then return end
        local position = mp.get_property_number('time-pos')
        local duration = mp.get_property_number('duration')
        -- Allow for frame boundaries and imprecise duration metadata.
        if not position or not duration or position <= 0 or duration - position <= 2 then return end
        if mp.get_property('end') ~= 'none' or mp.get_property('length') ~= 'none'
            or mp.get_property('frames') ~= 'all' or mp.get_property('play-direction') ~= 'forward'
            or not mp.get_property_bool('rebase-start-time') then return end
        local source = resume_source()
        if source then return entry_target(position, source) end
    end

    mp.observe_property('eof-reached', 'bool', function(_, eof)
        if eof then
            local point = checkpoint()
            if point and point.position then show_position(point.position) end
        end
    end)

    mp.add_hook('on_unload', 50, function()
        unloading = checkpoint()
    end)

    mp.register_event('start-file', function(event)
        -- A format switch may reopen this entry again before its first frame.
        local retry = pending and pending.phase == 'queued' and pending or next_load
        next_load = nil
        if retry and retry.id == event.playlist_entry_id then
            pending = retry
            pending.phase = 'loading'
        else
            pending = nil
        end
    end)

    mp.observe_property('idle-active', 'bool', function(_, idle)
        if idle then next_load = nil end
    end)

    mp.add_hook('on_preloaded', 80, function()
        if pending and pending.position and pending.phase == 'loading' and pending.path == mp.get_property('path')
            and matches(mp.get_property_number('playlist-pos', -1), pending) then
            if pending.source ~= true and resume_source() ~= pending.source then
                pending = nil
                part_changed()
                return
            end
            mp.set_property('file-local-options/start', string.format('%.6f', pending.position))
        end
    end)
    mp.register_event('playback-restart', function()
        if pending and pending.phase == 'loading' then pending = nil end
    end)

    local control = {}

    function control.ended(event)
        local previous = unloading
        unloading = nil
        -- Reload retires the original load with a stop before starting the same ID.
        if pending and pending.phase == 'queued' and event.reason == 'stop' then return end
        if pending and pending.phase == 'loading' and pending.id == event.playlist_entry_id then
            if pending.position and (event.reason == 'stop' or event.reason == 'error') then
                next_load = pending
            end
            if event.reason == 'error' then
                pending.phase = nil
                return pending.position, pending.position == nil
            end
        end
        pending = nil
        -- VOD recovery is for the final interrupted item. A live room may
        -- move in the queue; a subsequent start-file retires it if playback advances.
        if (event.reason == 'eof' or event.reason == 'error') and previous and previous.id == event.playlist_entry_id
            and (not previous.position or matches(mp.get_property_number('playlist-count', 0) - 1, previous)) then
            pending = previous
            return pending.position, pending.position == nil
        end
    end

    function control.prepare_reload()
        -- Repeated keypresses must not replace the restart point while opening.
        if pending and pending.phase then return false end
        local idle = mp.get_property_bool('idle-active')
        if mp.get_property_bool('eof-reached') or (not idle and playing_live()) then
            pending = checkpoint()
        elseif not idle then
            pending = nil
        end
        if not pending then return end
        local index = mp.get_property_number('playlist-pos', -1)
        if index < 0 and idle then
            for i, entry in ipairs(mp.get_property_native('playlist', {})) do
                if entry.id == pending.id then index = i - 1; break end
            end
        end
        if not matches(index, pending) then pending = nil; return end
        pending.phase = 'queued'
        return index
    end

    function control.reload_rejected()
        if pending then pending.phase = nil end
    end

    return control
end

return M
