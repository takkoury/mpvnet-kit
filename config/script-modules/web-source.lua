-- Identify supported webpage URLs without consulting player state or the network.
local M = {}

local function web_address(value)
    if type(value) ~= 'string' or value:find('%s') or value:find('%c') then return end
    local authority, rest = value:match('^[Hh][Tt][Tt][Pp][Ss]?://([^/?#]+)(.*)$')
    if not authority or authority:find('@', 1, true) then return end
    local host = authority:lower():gsub(':%d+$', '')
    return host, rest
end

local function site_host(host, domain)
    return host and (host == domain or host:sub(-#domain - 1) == '.' .. domain)
end

local function youtube_host(host)
    return host == 'www.youtube.com' or host == 'youtube.com' or host == 'm.youtube.com'
end

local function youtube_id(value)
    if value and #value == 11 and value:match('^[%w_%-]+$') then return value end
end

local function youtube_watch_id(host, rest)
    local id
    if host == 'youtu.be' then
        id = rest:match('^([^?#]*)'):match('^/([^/]+)/?$')
    elseif youtube_host(host) then
        local query = rest:match('^/watch%?([^#]*)') or ''
        for value in ('&' .. query):gmatch('&v=([^&]*)') do
            if id and id ~= value then return end
            id = value
        end
    end
    return youtube_id(id)
end

local function share_parameters(short_url, target_url)
    local part, start_time
    -- The first valid value for each parameter wins, including across the redirect.
    for _, url in ipairs({short_url or '', target_url}) do
        local query = url:match('^[^?#]*%?([^#]*)') or ''
        for field in query:gmatch('[^&]+') do
            part = part or field:match('^p=([1-9]%d*)$')
            start_time = start_time or field:match('^t=(%d+)$') or field:match('^t=(%d+%.%d*)$')
        end
    end
    return part, start_time
end

local function bilibili_page(rest, short_url)
    local path = rest:match('^([^?#]*)'):gsub('^/zh%-Han[st]/', '/')
    local part, start_time = share_parameters(short_url, rest)
    local bvid = path:match('^/video/(BV%w+)/?$')
    if bvid and #bvid == 12 then
        local page = 'https://www.bilibili.com/video/' .. bvid .. '/'
        if part then page = page .. '?p=' .. part end
        return {kind='bilibili', page=page, id=bvid, part=part, start=start_time}
    end
    local id = path:match('^/bangumi/play/(ep[1-9]%d*)/?$') or path:match('^/bangumi/play/(ss[1-9]%d*)/?$')
    if id then
        local page = 'https://www.bilibili.com/bangumi/play/' .. id
        -- A season alone does not identify the episode to start at this time.
        return {kind='bilibili', page=page, id=id, start=id:sub(1, 2) == 'ep' and start_time or nil}
    end
end

function M.parse(address, short_url)
    local host, rest = web_address(address)
    if not host then return end
    local path = rest:match('^[^?#]*')
    if host == 'b23.tv' then
        local code = path:match('^/([A-Za-z0-9]+)/?$')
        return {kind='short', code=code and #code <= 32 and code or nil}
    end
    if host == 'live.bilibili.com' then
        local room = path:match('^/([1-9]%d*)/?$') or path:match('^/blanc/([1-9]%d*)/?$')
        if room then return {kind='live', id=room} end
    end
    if site_host(host, 'bilivideo.com') then return {kind='cdn'} end
    if site_host(host, 'bilibili.com') then return bilibili_page(rest, short_url) or {kind='url'} end
    local video = youtube_watch_id(host, rest)
    if video then
        return {kind='youtube', id=video, page='https://www.youtube.com/watch?v=' .. video, rest=rest}
    end
    if youtube_host(host) then
        local live = youtube_id(path:match('^/live/([^/]+)/?$'))
        if live then return {kind='youtube', id=live} end
    end
    return {kind='url'}
end

-- A browser-supplied CDN stream may need a part or episode lookup before handoff.
function M.resume_target(address, from_cdn, cid)
    local source = M.parse(address)
    if not source or not source.page then return end
    if source.kind == 'bilibili' then
        local prefix = source.id:sub(1, 2)
        if prefix == 'ss' or (from_cdn and prefix == 'BV' and not source.part) then
            return source.page, source.id, from_cdn and cid or nil
        end
    end
    return source.page
end

-- The canonical page can already contain a video ID or part number.
function M.url_at_time(page, seconds)
    if not seconds then return page end
    local separator = page:find('?', 1, true) and '&' or '?'
    return page .. separator .. 't=' .. seconds
end

return M
