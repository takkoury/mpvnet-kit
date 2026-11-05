-- Read the active main subtitle source without writing subtitle text to disk.
local mp = require('mp')
local utils = require('mp.utils')
local M = {}
local max_bytes, max_lines, timeout = 8 * 1024 * 1024, 10000, 30
local bitmap_codecs = {
    dvd_subtitle=true, dvb_subtitle=true, hdmv_pgs_subtitle=true, xsub=true,
    vobsub=true, pgs=true, dvbsub=true, dvdsub=true,
}

local function valid_path(value)
    return type(value) == 'string' and value ~= '' and not value:find('%z')
end

local function stream_index(value)
    return type(value) == 'number' and value >= 0 and value <= 2147483647 and value == math.floor(value)
end

local function stream_map(sub)
    if stream_index(sub['ff-index']) then return '0:' .. sub['ff-index'] end
    if sub.external then return '0:s:0' end
    local tracks = mp.get_property_native('track-list')
    local index = 0
    for _, track in ipairs(type(tracks) == 'table' and tracks or {}) do
        if type(track) == 'table' and track.type == 'sub' and not track.external then
            if track.id == sub.id then return '0:s:' .. index end
            index = index + 1
        end
    end
end

function M.source()
    local source = {media=mp.get_property_native('path')}
    local sub = mp.get_property_native('current-tracks/sub')
    local sid = mp.get_property_native('sid')
    local requested_id = tonumber(sid)
    if type(sub) ~= 'table' or type(sub.id) ~= 'number' or sid == 'no' or sid == false or
        (requested_id and requested_id ~= sub.id) then
        source.problem = 'no_subtitle'
        return source
    end
    source.id, source.src_id = sub.id, sub['src-id']
    source.codec = type(sub.codec) == 'string' and sub.codec:lower() or nil
    source.external = sub.external == true
    source.external_filename = source.external and sub['external-filename'] or nil
    source.map = stream_map(sub)
    if source.external then
        source.input = source.external_filename
        if valid_path(source.input) and source.input:match('^edl://') then
            source.input = source.input:match('https?://.*') or source.input
        end
    else
        source.input = source.media
    end
    if bitmap_codecs[source.codec] then
        source.problem = 'bitmap'
    elseif not valid_path(source.media) or not valid_path(source.input) or not source.map then
        source.problem = 'source'
    elseif not source.input:match('^[\\/][\\/]') and
        (source.input:match('^%a:[\\/]') or not source.input:match('^%a[%w+.-]*:')) then
        -- Only a local stat: do not contact a URL or UNC share to revalidate rows.
        -- This catches observable replacement/edits without rereading the media.
        local stat = utils.file_info(source.input)
        if stat then
            source.mtime, source.ctime, source.size = stat.mtime, stat.ctime, stat.size
        end
    end
    return source
end

function M.same_source(a, b)
    if not a or not b then return false end
    for key, value in pairs(a) do if b[key] ~= value then return false end end
    for key in pairs(b) do if a[key] == nil then return false end end
    return true
end

local function plain_text(text)
    local output, position, drawing = {}, 1, false
    for start, tag, after in text:gmatch('(){([\\=][^{}]*)}()') do
        if not drawing then output[#output+1] = text:sub(position, start-1) end
        for scale in tag:gmatch('\\p(%d+)') do drawing = tonumber(scale) > 0 end
        position = after
    end
    if not drawing then output[#output+1] = text:sub(position) end
    text = table.concat(output):gsub('<[^<>]*>', ''):gsub('\\h+', ' ')
        :gsub('\\[nN]', ' '):gsub('[%z\1-\31\127]', ' ')
    local first, last = text:find('%S'), text:match('^.*()%S')
    if not first then return '' end
    text = text:sub(first, last)
    if text:match('^m%s[mblnspc%s%-%d%.]+$') then return '' end
    return text
end

function M.parse(stdout)
    if type(stdout) ~= 'string' then return nil, 'failed' end
    if #stdout > max_bytes then return nil, 'too_large' end
    local lines, seen = {}, {}
    stdout = stdout:gsub('^\239\187\191', '')
    for raw in stdout:gmatch('[^\n]+') do
        local minutes, seconds, text = raw:match('^%[(%d+):(%d%d)%.%d+%](.*)$')
        if not minutes then minutes, seconds, text = raw:match('^%[(%d+):(%d%d)%](.*)$') end
        if minutes then
            minutes, seconds = tonumber(minutes), tonumber(seconds)
            local time = minutes * 60 + seconds
            if seconds < 60 and time < 2^53 then
                text = plain_text(text)
                if text ~= '' then
                    if not seen[time] then seen[time] = {} end
                    if not seen[time][text] then
                        if #lines == max_lines then return nil, 'too_large' end
                        seen[time][text] = true
                        lines[#lines+1] = {time=time, title=text, order=#lines+1}
                    end
                end
            end
        end
    end
    table.sort(lines, function(a, b)
        if a.time ~= b.time then return a.time < b.time end
        return a.order < b.order
    end)
    return lines
end

local function ffmpeg_path()
    local ok, paths = pcall(dofile, mp.command_native({'expand-path', '~~/script-modules/mpvnet-paths.lua'}))
    local options = ok and type(paths) == 'table' and paths.options
    local path = type(options) == 'table' and options.ffmpeg_path
    return valid_path(path) and path or 'ffmpeg'
end

function M.run(source, done)
    local pending, request, timer = true, nil, nil
    local function retire(abort)
        if not pending then return false end
        pending = false
        if timer then timer:kill(); timer = nil end
        if abort and request then mp.abort_async_command(request) end
        return true
    end
    local function finish(success, result)
        if not retire(false) then return end
        if type(result) == 'table' and result.error_string == 'init' then
            done(nil, 'ffmpeg')
        elseif type(result) == 'table' and type(result.stdout) == 'string' and #result.stdout > max_bytes then
            done(nil, 'too_large')
        elseif success and type(result) == 'table' and result.status == 0 then
            done(M.parse(result.stdout))
        else
            done(nil, 'failed')
        end
    end
    -- Capture one extra byte so a capped stream is never presented as complete.
    -- Keep FFmpeg's diagnostics private, as they can include source addresses.
    local args = {ffmpeg_path(), '-hide_banner', '-loglevel', 'error', '-nostdin', '-i', source.input,
        '-map', source.map, '-f', 'lrc', '-map_metadata', '-1', '-fflags', '+bitexact', '-'}
    local ok, command = pcall(mp.command_native_async, {name='subprocess', args=args, playback_only=true,
        capture_size=max_bytes+1, capture_stdout=true, capture_stderr=true}, finish)
    if not ok or not command then
        finish(false)
    elseif pending then
        request = command
        timer = mp.add_timeout(timeout, function()
            if retire(true) then done(nil, 'timeout') end
        end)
    end
    return function() retire(true) end
end

return M
