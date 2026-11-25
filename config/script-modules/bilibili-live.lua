-- A room lookup is needed only after a playing broadcast stops. The stream
-- itself and the initial offline diagnostic come from the existing extractor.
local M = {}

function M.new(mp, utils, feedback, ytdl_result)
    local room
    local control = {}

    local function cancel_query()
        if room and room.query then
            local handle = room.query
            room.query = nil
            mp.abort_async_command(handle)
        end
    end

    function control.open(id)
        cancel_query()
        room = id and {id=id} or nil
    end

    local function check_broadcast()
        if not room or not room.played or room.checked or room.limited then return end
        room.checked = true
        local current = room
        local windows = os.getenv('SystemRoot') or os.getenv('WINDIR')
        local function report(ended)
            if ended then
                feedback.show('直播已结束', 'notice')
            else
                feedback.show('直播连接中断\n可重新打开直播间', 'notice')
            end
        end
        if not windows then report(false); return end
        local endpoint = 'https://api.live.bilibili.com/room/v1/Room/get_info?id=' .. room.id
        local handle
        handle = mp.command_native_async({name='subprocess', playback_only=false,
            capture_stdout=true, capture_size=131072,
            args={utils.join_path(windows, 'System32/curl.exe'), '--disable', '--silent', '--fail',
                '--max-time', '4', '--max-filesize', '131072', endpoint}}, function(ok, result)
            if room ~= current or current.query ~= handle then return end
            current.query = nil
            local data = ok and result and result.status == 0 and utils.parse_json(result.stdout or '')
            local info = type(data) == 'table' and data.code == 0 and data.data
            report(type(info) == 'table' and info.live_status == 0 and
                (tostring(info.room_id) == current.id or tostring(info.short_id) == current.id))
        end)
        current.query = handle
    end

    mp.register_event('file-loaded', function()
        if room then
            room.played = true
            room.limited = mp.get_property('end') ~= 'none' or mp.get_property('length') ~= 'none'
                or mp.get_property('frames') ~= 'all'
        end
    end)
    mp.observe_property('eof-reached', 'bool', function(_, eof)
        if eof then check_broadcast() end
    end)
    mp.register_event('playback-restart', function()
        if room and room.checked and not mp.get_property_bool('eof-reached') then
            cancel_query()
            room.checked = false
        end
    end)
    mp.add_hook('on_unload', 60, function()
        if not room or room.played then return end
        room.offline = ytdl_result.match_error(mp, 'BiliLive', room.id, '^Streamer is not live$') ~= nil
    end)

    function control.finish(reason)
        if not room then return end
        if reason ~= 'error' and reason ~= 'eof' then
            control.open(nil)
        elseif room.played then
            check_broadcast()
        elseif reason == 'error' then
            if room.offline then
                feedback.show('直播间当前未开播', 'notice')
            else
                feedback.show('暂时无法打开直播间\n请检查网络和 yt-dlp，或打开原网页查看', 'error')
            end
        end
    end

    mp.register_event('start-file', function() control.open(nil) end)
    mp.register_event('shutdown', function() control.open(nil) end)
    return control
end

return M
