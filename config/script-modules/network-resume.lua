-- One in-memory restart point. Direct URLs use queue identity alone (true);
-- extracted pages also carry the media ID to check again on reload.
local M = {}

function M.new(mp, resume_source, show_position, part_changed)
    local pending, unloading

    local function matches(index, point)
        if index < 0 then return false end
        local entry = 'playlist/' .. index .. '/'
        return mp.get_property_native(entry .. 'id') == point.id
            and mp.get_property(entry .. 'filename') == point.path
    end

    local function checkpoint()
        if not mp.get_property_bool('demuxer-via-network') or not mp.get_property_bool('seekable') then return end
        local position = mp.get_property_number('time-pos')
        local duration = mp.get_property_number('duration')
        -- Allow for frame boundaries and imprecise duration metadata.
        if not position or not duration or position <= 0 or duration - position <= 2 then return end
        if mp.get_property('end') ~= 'none' or mp.get_property('length') ~= 'none'
            or mp.get_property('frames') ~= 'all' or mp.get_property('play-direction') ~= 'forward'
            or not mp.get_property_bool('rebase-start-time') then return end
        local index = mp.get_property_number('playlist-playing-pos', -1)
        if index < 0 then return end
        local source = resume_source()
        if not source then return end
        local point = {id=mp.get_property_native('playlist/' .. index .. '/id'),
            path=mp.get_property('path'), position=position, source=source}
        if point.id and point.path and matches(index, point) then return point end
    end

    mp.observe_property('eof-reached', 'bool', function(_, eof)
        if eof then
            local point = checkpoint()
            if point then show_position(point.position) end
        end
    end)

    mp.add_hook('on_unload', 50, function()
        unloading = checkpoint()
    end)

    mp.register_event('start-file', function(event)
        if pending and pending.phase == 'queued' and pending.id == event.playlist_entry_id then
            pending.phase = 'loading'
        else
            pending = nil
        end
    end)

    mp.add_hook('on_preloaded', 80, function()
        if pending and pending.phase == 'loading' and pending.path == mp.get_property('path')
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
        if pending and pending.id == event.playlist_entry_id
            and pending.phase == 'loading' and event.reason == 'error' then
            pending.phase = nil
            return pending.position
        end
        pending = nil
        if (event.reason == 'eof' or event.reason == 'error') and previous and previous.id == event.playlist_entry_id
            and matches(mp.get_property_number('playlist-count', 0) - 1, previous) then
            pending = previous
            return pending.position
        end
    end

    function control.prepare_reload()
        -- Repeated keypresses must not replace the restart point while opening.
        if pending and pending.phase then return false end
        if mp.get_property_bool('eof-reached') then
            pending = checkpoint()
        elseif not mp.get_property_bool('idle-active') then
            pending = nil
        end
        if not pending then return end
        local index = mp.get_property_number('playlist-pos', -1)
        if index < 0 and mp.get_property_bool('idle-active') then
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
