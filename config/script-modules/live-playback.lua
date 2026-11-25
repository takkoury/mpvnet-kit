-- Own the playing broadcast, its single end-of-stream lookup and its feedback.
-- A YouTube watch URL can also be VOD; confirm its extraction before arming it.
local M = {}
local live_status = 'user-data/mpvnet/feedback/live'

function M.new(mp, utils, feedback, ytdl_result)
    local bili = dofile(mp.command_native({'expand-path', '~~/script-modules/bilibili-live.lua'}))
    local room
    local control = {}

    local function cancel_query()
        if not room then return end
        if room.timer then room.timer:kill(); room.timer = nil end
        if room.query then
            local handle = room.query
            room.query = nil
            mp.abort_async_command(handle)
        end
    end

    local function reset_check()
        if not room or not room.checked then return end
        cancel_query()
        room.checked = false
        if room.youtube then mp.set_property_native(live_status, '') end
    end

    function control.open(bili_id)
        reset_check()
        room = bili_id and {id=bili_id} or nil
    end

    function control.loaded(youtube_id, catalog)
        if youtube_id then
            local data = ytdl_result.read(mp, utils)
            if type(data) ~= 'table' or data.extractor_key ~= 'Youtube' or data.id ~= youtube_id
                or data.live_status ~= 'is_live' or data.entries then return false end
            room = {id=youtube_id, youtube=true, request=catalog.live_status_request(mp, youtube_id)}
        end
        if not room then return false end
        room.played = true
        room.limited = mp.get_property('end') ~= 'none' or mp.get_property('length') ~= 'none'
            or mp.get_property('frames') ~= 'all'
        return true
    end

    local function report(current, output)
        if current.youtube then
            local id, status = (output or ''):match('^([%w_%-]+) ([a-z_]+)%s*$')
            local message
            if id == current.id and (status == 'post_live' or status == 'was_live') then
                message = '直播已结束'
            elseif id == current.id and status == 'is_live' then
                message = '直播连接中断\n可重新打开直播链接'
            else
                message = '暂时无法确认直播状态\n可重新打开直播链接'
            end
            mp.set_property_native(live_status, message)
            if not feedback.is_ready() then feedback.show(message, 'notice') end
        elseif output and bili.ended(utils, current.id, output) then
            feedback.show('直播已结束', 'notice')
        else
            feedback.show('直播连接中断\n可重新打开直播间', 'notice')
        end
    end

    local function check_broadcast()
        if not room or not room.played or room.checked or room.limited then return end
        room.checked = true
        local current = room
        local command = current.request
        if not current.youtube then command = bili.status_request(utils, current.id) end
        if not command then report(current); return end
        if current.youtube then mp.set_property_native(live_status, '正在确认直播状态…') end
        local handle
        handle = mp.command_native_async(command, function(ok, result)
            if room ~= current or current.query ~= handle then return end
            if current.timer then current.timer:kill(); current.timer = nil end
            current.query = nil
            report(current, ok and result and result.status == 0 and result.stdout or nil)
        end)
        current.query = handle
        if current.youtube then
            current.timer = mp.add_timeout(12, function()
                if room ~= current or current.query ~= handle then return end
                cancel_query()
                report(current)
            end)
        end
    end

    mp.observe_property('eof-reached', 'bool', function(_, eof)
        if eof then check_broadcast() end
    end)
    mp.register_event('playback-restart', function()
        if room and room.checked and not mp.get_property_bool('eof-reached') then
            reset_check()
        end
    end)
    mp.add_hook('on_unload', 60, function()
        if room and not room.played then
            room.offline = ytdl_result.match_error(mp, 'BiliLive', room.id, '^Streamer is not live$') ~= nil
        end
    end)

    function control.can_rejoin()
        return room ~= nil and room.played == true and not room.limited
    end

    function control.finish(reason, retry_hint)
        if not room then return end
        if reason ~= 'error' and reason ~= 'eof' then
            control.open(nil)
        elseif room.played then
            check_broadcast()
        elseif reason == 'error' then
            if room.offline then
                feedback.show('直播间当前未开播', 'notice')
            else
                feedback.show(retry_hint or '暂时无法打开直播间\n请检查网络和 yt-dlp，或打开原网页查看', 'error')
            end
        end
    end

    mp.register_event('start-file', function() control.open(nil) end)
    mp.register_event('shutdown', function() control.open(nil) end)
    return control
end

return M
