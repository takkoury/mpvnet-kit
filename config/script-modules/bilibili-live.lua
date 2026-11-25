-- One public room status lookup after the media stream ends.
local M = {}

function M.status_request(utils, id)
    local windows = os.getenv('SystemRoot') or os.getenv('WINDIR')
    if not windows then return end
    return {name='subprocess', playback_only=false, capture_stdout=true, capture_size=131072,
        args={utils.join_path(windows, 'System32/curl.exe'), '--disable', '--silent', '--fail',
            '--max-time', '4', '--max-filesize', '131072',
            'https://api.live.bilibili.com/room/v1/Room/get_info?id=' .. id}}
end

function M.ended(utils, id, output)
    local data = utils.parse_json(output)
    local info = type(data) == 'table' and data.code == 0 and data.data
    return type(info) == 'table' and info.live_status == 0 and
        (tostring(info.room_id) == id or tostring(info.short_id) == id)
end

return M
