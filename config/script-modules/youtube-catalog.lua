-- Metadata lookups for public YouTube videos and playlists.
local M = {}

local function playlist_id(value)
    return type(value) == 'string' and #value <= 128 and value:match('^PL[%w_%-]+$')
end

function M.watch_list(video, rest)
    if not video then return end
    local query = rest:match('^[^?#]*%?([^#]*)') or ''
    local id, index
    local single = 'https://www.youtube.com/watch?v=' .. video
    for field in query:gmatch('[^&]+') do
        local key, value = field:match('^([^=]+)=(.*)$')
        if key == 'list' then
            if not playlist_id(value) or (id and id ~= value) then return end
            id = value
        elseif key == 'index' then
            if value:match('^[1-9]%d*$') then index = tonumber(value) end
        elseif key == 't' or key == 'start' or key == 'end' or key == 'time_continue' then
            single = single .. '&' .. field
        end
    end
    if id then return id, index, single .. (rest:match('(#.*)$') or '') end
end

function M.queue_entries(source, data)
    if type(data) ~= 'table' or data.id ~= source.playlist_id then return end
    local rows = data.entries
    if type(rows) ~= 'table' or #rows < 2 or #rows > 10000 then return end
    local entries, first, matches = {}, nil, 0
    for i, row in ipairs(rows) do
        if type(row) ~= 'table' or type(row.id) ~= 'string' or #row.id ~= 11
            or not row.id:match('^[%w_%-]+$') then return end
        local title = type(row.title) == 'string' and row.title:gsub('%c', ' ') or ''
        entries[i] = {path='https://www.youtube.com/watch?v=' .. row.id, title=title ~= '' and title or row.id}
        if row.id == source.content_id then first, matches = i, matches + 1 end
    end
    local at = source.index and rows[source.index]
    if at and at.id == source.content_id then return entries, source.index end
    if matches == 1 then return entries, first end
end

local function query_args(mp, url, options)
    local exe = mp.get_property_native('user-data/mpv/ytdl/path')
    if type(exe) ~= 'string' or exe == '' then return end
    local args = {exe, '--ignore-config', '--no-warnings', '--no-cache-dir', '--no-plugin-dirs',
        '--skip-download', '--socket-timeout', '6', '--retries', '0', '--extractor-retries', '0'}
    for _, option in ipairs(options) do args[#args+1] = option end
    local raw = mp.get_property_native('file-local-options/ytdl-raw-options', {})
    local proxy = raw.proxy
    if proxy == nil then
        local http = mp.get_property('file-local-options/http-proxy', '')
        if http ~= '' then proxy = http end
    end
    if type(proxy) == 'string' then
        args[#args+1] = '--proxy'
        args[#args+1] = proxy
    end
    args[#args+1] = '--'
    args[#args+1] = url
    return args
end

-- Capture the original item's extractor and proxy before mpv unloads its options.
function M.live_status_request(mp, id)
    local args = query_args(mp, 'https://www.youtube.com/watch?v=' .. id,
        {'--no-playlist', '--ignore-no-formats-error', '--print', '%(id)s %(live_status)s'})
    if args then
        return {name='subprocess', args=args, playback_only=false, capture_stdout=true, capture_size=4096}
    end
end

function M.fetch(mp, utils, id, done)
    if not playlist_id(id) then done(nil); return end
    local args = query_args(mp, 'https://www.youtube.com/playlist?list=' .. id, {'--flat-playlist',
        '--playlist-end', '10001', '--print', 'playlist:{"id":%(id)j,"entries":%(entries.:.{id,title})j}'})
    if not args then done(nil); return end
    local timer
    local handle = mp.command_native_async({name='subprocess', args=args, playback_only=true,
        capture_stdout=true, capture_size=2097152}, function(ok, result)
        if timer then timer:kill() end
        local data = ok and result and result.status == 0 and utils.parse_json(result.stdout or '')
        done(data)
    end)
    timer = mp.add_timeout(12, function() mp.abort_async_command(handle) end)
    return handle
end

return M
