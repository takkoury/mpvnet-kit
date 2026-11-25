-- Focused playback actions shared by input.conf and ModernZ.
-- Explicit actions use short messages. Cache waits publish a persistent status.
local mp = require("mp")
local feedback_client = dofile(mp.command_native({'expand-path', '~~/script-modules/feedback.lua'})).new(mp)
local utils = require("mp.utils")
local paths = dofile(mp.command_native({'expand-path', '~~/script-modules/mpvnet-paths.lua'}))
-- The Windows host enables defaults before mpv_initialize; enforce the user whitelist at runtime too.
mp.set_property_bool("input-default-bindings", false)
mp.set_property("osd-playing-msg", "")
-- mpv.net keeps _ as its menu placeholder; the menu command stays callable without a player key.
mp.add_forced_key_binding("_", "menu-placeholder", function() end)
local held, hold_timer
local seek_pending = false
local frame_pending = false
local reload_pending = false
local saved_video
local saved_video_revision
local mark
local reload_marks
local window_scale_timer
local path_requests = {}
local path_sequence = 0
-- One in-memory association only; never retain request headers or infer a page from CID/CDN.
local origin_path, origin_page, origin_active, origin_cid
local initial_media, inherited_cid = true, nil
local playback_entry_id, failure_source
local expanded_short_page

local function web_address(value)
    if type(value) ~= 'string' or value:find('%s') or value:find('%c') then return end
    local authority, rest = value:match('^[Hh][Tt][Tt][Pp][Ss]?://([^/?#]+)(.*)$')
    if not authority or authority:find('@', 1, true) then return end
    local host = authority:lower():gsub(':%d+$', '')
    return value, host, rest
end

local function site_host(host, domain)
    return host and (host == domain or host:sub(-#domain - 1) == '.' .. domain)
end

local function youtube_video_id(host, rest)
    local id
    if host == 'youtu.be' then
        id = rest:match('^([^?#]*)'):match('^/([^/]+)/?$')
    elseif host == 'www.youtube.com' or host == 'youtube.com' or host == 'm.youtube.com' then
        local query = rest:match('^/watch%?([^#]*)') or ''
        for value in ('&' .. query):gmatch('&v=([^&]*)') do
            if id and id ~= value then return end
            id = value
        end
    end
    if id and #id == 11 and id:match('^[%w_%-]+$') then return id end
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

local function bilibili_page(value, short_url)
    local address, host, rest = web_address(value)
    if not address or not site_host(host, 'bilibili.com') then return end
    local path = rest:match('^([^?#]*)'):gsub('^/zh%-Han[st]/', '/')
    local part, start_time = share_parameters(short_url, rest)
    local bvid = path:match('^/video/(BV%w+)/?$')
    if bvid and #bvid == 12 then
        local page = 'https://www.bilibili.com/video/' .. bvid .. '/'
        if part then page = page .. '?p=' .. part end
        return page, bvid, start_time
    end
    local id = path:match('^/bangumi/play/(ep[1-9]%d*)/?$') or path:match('^/bangumi/play/(ss[1-9]%d*)/?$')
    if id then
        local page = 'https://www.bilibili.com/bangumi/play/' .. id
        -- A season alone does not identify the episode to start at this time.
        return page, id, id:sub(1, 2) == 'ep' and start_time or nil
    end
end

-- Return a canonical page, plus a Bilibili lookup ID only if the page still
-- needs a specific part or episode. YouTube IDs are opaque.
local function resume_target(address, from_cdn, cid)
    local _, host, rest = web_address(address)
    local video_id = youtube_video_id(host, rest)
    if video_id then return 'https://www.youtube.com/watch?v=' .. video_id end
    local page, id = bilibili_page(address)
    if not page then return end
    if id:sub(1, 2) == 'ss' or (from_cdn and id:sub(1, 2) == 'BV' and not page:find('?p=', 1, true)) then
        return page, id, from_cdn and cid or nil
    end
    return page
end

local function capture_media_origin(loaded)
    origin_active = false
    local path = mp.get_property('path')
    local _, host, rest = web_address(path)
    if not host then return end
    if youtube_video_id(host, rest) then return 'youtube' end
    if host == 'b23.tv' and expanded_short_page then return 'page' end
    if not site_host(host, 'bilivideo.com') then
        return bilibili_page(path) and 'page' or 'url'
    end
    local option = 'referrer'
    local page, id = bilibili_page(mp.get_property('file-local-options/referrer'))
    if not page then
        option = 'http-header-fields'
        local headers = mp.get_property_native('file-local-options/http-header-fields', {})
        for _, header in ipairs(type(headers) == 'table' and headers or {}) do
            if type(header) == 'string' and (header:match('^%s*([^:]+):') or ''):lower() == 'referer' then
                page, id = bilibili_page(header:match('^[^:]+:%s*(.-)%s*$'))
                if page then break end
            end
        end
    end
    if not page then return 'url' end
    local cid = mp.get_opt('cid')
    local local_cid = cid ~= nil and cid ~= inherited_cid
        and mp.get_property_bool('option-info/script-opts/set-locally', false)
    -- A second episode can legitimately carry the same season Referer when
    -- both it and a new CID were supplied for that file.
    local explicit_season = id:sub(1, 2) == 'ss' and local_cid
        and mp.get_property_bool('option-info/' .. option .. '/set-locally', false)
    if not origin_page or page ~= origin_page or path == origin_path or explicit_season then
        local same = path == origin_path and page == origin_page and cid == origin_cid
        origin_cid = (initial_media or local_cid or same) and cid or nil
        origin_path, origin_page, origin_active = path, page, loaded
        return 'page'
    end
    return 'url'
end

local function media_address()
    local path = mp.get_property("path")
    if not path or path == "" then return nil, "PATH" end
    if path:find("://", 1, true) then
        local address, host = web_address(path)
        if not address then return nil, 'URL' end
        if site_host(host, 'bilivideo.com') then
            return origin_active and origin_path == path and origin_page or nil, 'URL'
        end
        return bilibili_page(address) or address, 'URL'
    end
    local file = utils.file_info(path)
    if not file or not file.is_file then return nil, "PATH" end
    local normalized = mp.command_native({"normalize-path", path})
    return normalized and normalized:gsub("/", "\\"), "PATH"
end

local function time_text(value, hours)
    if not value then return hours and "--:--:--" or "--:--" end
    value = math.max(0, math.floor(value))
    if hours then
        return string.format("%02d:%02d:%02d", math.floor(value / 3600), math.floor(value / 60) % 60, value % 60)
    end
    return string.format("%02d:%02d", math.floor(value / 60), value % 60)
end

local function show_time()
    local current = mp.get_property_number("time-pos")
    local total = mp.get_property_number("duration")
    local hours = (current or 0) >= 3600 or (total or 0) >= 3600
    feedback_client.show(time_text(current, hours) .. " / " .. time_text(total, hours), 'action')
end

local function show_speed()
    local speed = mp.get_property_number("speed", 1)
    local number = string.format(speed % 1 == 0 and "%.1f" or "%g", speed)
    feedback_client.show("倍速 ×" .. number, 'action')
end

local function set_speed(value, quiet)
    value = tonumber(value)
    if not value then return end
    mp.commandv("no-osd", "set", "speed", value)
    if not quiet then show_speed() end
end

local function add_speed(value)
    value = tonumber(value)
    if not value then return end
    mp.commandv("no-osd", "add", "speed", value)
    show_speed()
end

local seek_timer = mp.add_timeout(0.15, function()
    -- A slow network seek must report its resolved time at playback-restart.
    if seek_pending and not mp.get_property_bool("seeking", false) then
        seek_pending = false
        show_time()
    end
end)
seek_timer:kill()

local function seek(value, flags)
    seek_pending = true
    seek_timer:kill()
    seek_timer:resume()
    mp.commandv("script-message-to", "modernz", "osc-show")
    mp.commandv("no-osd", "seek", value, flags or "relative+exact")
end

local function toggle_pause()
    local paused = not mp.get_property_bool("pause", false)
    mp.set_property_bool("pause", paused)
    feedback_client.show(paused and "已暂停" or "继续播放", 'action')
end

local function release_hold()
    if hold_timer then hold_timer:kill(); hold_timer = nil end
    if held and held.active then
        mp.set_property_number("speed", held.speed)
        mp.set_property_bool("pause", held.pause)
    end
    held = nil
end

local function space(event)
    if event.canceled then release_hold(); return end
    if event.event == "down" then
        if held then return end
        held = {speed = mp.get_property_number("speed", 1), pause = mp.get_property_bool("pause", false)}
        hold_timer = mp.add_timeout(0.25, function()
            if not held then return end
            held.active = true
            set_speed(2)
            mp.set_property_bool("pause", false)
        end)
    elseif event.event == "up" then
        local short = held and not held.active
        release_hold()
        if short then toggle_pause() end
    elseif event.event == "press" then
        toggle_pause()
    end
end

local function cycle_speed(values)
    local current = mp.get_property_number("speed", 1)
    local next_speed = 1
    for i, value in ipairs(values) do
        if current == value then next_speed = values[i % #values + 1]; break end
    end
    -- A value outside this particular cycle (including the other cycle) returns to 1.
    set_speed(next_speed)
end

mp.add_key_binding(nil, "space", space, {complex = true})
mp.add_key_binding(nil, "toggle-pause", toggle_pause)
mp.add_key_binding(nil, "frame-forward", function(event)
    if event.canceled or event.event == "up" then return end
    if event.event == "down" or event.event == "press" then frame_pending = false end
    -- Native repeated frame-step switches to continuous playback. Every forwarded
    -- command is fresh; allow at most one unfinished step, including on slow video.
    if frame_pending and not mp.get_property_bool("pause", false) then return end
    if not mp.get_property_native("current-tracks/video") or mp.get_property_bool("eof-reached", false) then return end
    frame_pending = mp.commandv("no-osd", "frame-step") == true
end, {complex = true})
for name, amount in pairs({["seek-back"] = -3, ["seek-forward"] = 3,
    ["seek-back-small"] = -1, ["seek-forward-small"] = 1,
    ["seek-back-large"] = -10, ["seek-forward-large"] = 10}) do
    mp.add_key_binding(nil, name, function() seek(amount) end, {repeatable = true})
end
mp.add_key_binding(nil, "speed-down", function() cycle_speed({1, 0.75, 0.5}) end)
mp.add_key_binding(nil, "speed-up", function() cycle_speed({1, 1.25, 1.5, 2}) end)
mp.add_key_binding(nil, "speed-reset", function() set_speed(1) end)
mp.add_key_binding(nil, "fullscreen", function()
    mp.set_property_bool("fullscreen", not mp.get_property_bool("fullscreen", false))
end)
mp.add_key_binding(nil, "ontop", function()
    local enabled = not mp.get_property_bool("ontop", false)
    mp.set_property_bool("ontop", enabled)
    feedback_client.show(enabled and "窗口已置顶" or "已取消置顶", 'action')
end)
mp.add_key_binding(nil, "window-100", function()
    if window_scale_timer then window_scale_timer:kill() end
    mp.set_property_bool("fullscreen", false)
    mp.set_property_bool("window-maximized", false)
    -- Force a changed property even after a manual resize left window-scale at 1.
    -- The tiny intermediate scale rounds to the same pixels for ordinary video sizes.
    mp.set_property_number("window-scale", 1.000001)
    window_scale_timer = mp.add_timeout(0.05, function()
        window_scale_timer = nil
        mp.set_property_number("window-scale", 1)
    end)
    feedback_client.show("窗口缩放 100%", 'action')
end)
mp.add_key_binding(nil, "media-info", function()
    mp.commandv('script-message-to', 'media_info', 'open')
end)
mp.add_key_binding(nil, "osc-visibility", function()
    local mode = mp.get_property_native("user-data/osc/visibility") == "never" and "auto" or "never"
    mp.commandv("script-message-to", "modernz", "osc-visibility", mode, "yes")
    if mode == "auto" then mp.commandv("script-message-to", "modernz", "osc-show") end
end)
mp.add_key_binding(nil, "copy-time", function()
    local current = mp.get_property_number("time-pos")
    if not current or current < 0 or current ~= current or current == math.huge then
        feedback_client.show("无可复制的时间", 'error')
        return
    end
    -- Round the full timestamp before splitting so milliseconds carry across minutes/hours.
    local milliseconds = math.floor(current * 1000 + 0.5)
    local seconds = math.floor(milliseconds / 1000)
    local text = time_text(seconds, true) .. string.format(".%03d", milliseconds % 1000)
    local ok = mp.set_property("clipboard/text", text)
    feedback_client.show(ok and "时间已复制" or "时间复制失败", ok and 'success' or 'error')
end)
mp.add_key_binding(nil, "copy-media-path", function()
    local address, kind = media_address()
    local ok = address and mp.set_property("clipboard/text", address)
    feedback_client.show((kind == "URL" and "网址" or "路径") .. (ok and "已复制" or "复制失败"), ok and 'success' or 'error')
end)
local function open_address(address, kind, done)
    local function finish(ok)
        if done then done(ok)
        elseif not ok then feedback_client.show(kind == "URL" and "网址打开失败" or "文件定位失败", 'error') end
    end
    if not address then finish(false); return end
    -- Windows mpv subprocess stdin_data is unreliable; transport data in one owned UTF-8 JSON file.
    path_sequence = path_sequence + 1
    local directory = os.getenv("TEMP") or os.getenv("TMP")
    local absolute = directory and (directory:match("^%a:[\\/]") or directory:match("^\\\\"))
    local metadata = absolute and utils.file_info(directory)
    if not metadata or not metadata.is_dir then finish(false); return end
    local request_path = utils.join_path(directory, "mpvnet-path-" .. tostring(mp.get_property_number("pid")) .. "-" .. tostring(mp.get_time()):gsub("%W", "") .. "-" .. path_sequence .. ".json")
    local file = io.open(request_path, "wb")
    if not file then finish(false); return end
    local written = file:write(utils.format_json({operation = kind == "URL" and "url" or "reveal", address = address}))
    local closed = file:close()
    if not written or not closed then os.remove(request_path); finish(false); return end
    local helper = mp.command_native({"expand-path", "~~/helpers/media-path-action.ps1"})
    path_requests[request_path] = mp.command_native_async({name = "subprocess", args = {
        paths.powershell(), "-NoProfile", "-NonInteractive", "-STA", "-ExecutionPolicy", "Bypass", "-File", helper, "-RequestPath", request_path,
    }, capture_stderr = true, playback_only = done ~= nil}, function(success, result)
        path_requests[request_path] = nil
        os.remove(request_path)
        finish(success and result and result.status == 0)
    end)
    return path_requests[request_path]
end
mp.add_key_binding(nil, "open-media-path", function()
    open_address(media_address())
end)

local web_resume = dofile(mp.command_native({'expand-path', '~~/script-modules/web-resume.lua'}))
local bili_catalog = dofile(mp.command_native({'expand-path', '~~/script-modules/bilibili-catalog.lua'}))
local youtube_catalog = dofile(mp.command_native({'expand-path', '~~/script-modules/youtube-catalog.lua'}))
web_resume.bind(mp, utils, feedback_client, function()
    local _, host = web_address(mp.get_property('path'))
    if not host then return end
    local address
    if host == 'b23.tv' then address = expanded_short_page else address = media_address() end
    return resume_target(address, site_host(host, 'bilivideo.com'), origin_active and origin_cid)
end, open_address, bilibili_page, bili_catalog)
mp.add_key_binding(nil, "clipboard-url", function()
    mp.commandv("script-message-to", "playlist_controls", "open-clipboard-url")
end)
mp.add_key_binding(nil, "save-mark", function()
    local current = mp.get_property_number("time-pos")
    if not current or not mp.get_property("path") then return end
    mark = current
    feedback_client.show("已标记 " .. time_text(mark, true), 'success')
end)
mp.add_key_binding(nil, "jump-mark", function()
    if mark == nil then feedback_client.show("尚无播放标记", 'error'); return end
    seek(mark, "absolute+exact")
end)
mp.add_key_binding(nil, "ab-loop", function()
    if not mp.get_property("path") then return end
    local a = mp.get_property_number("ab-loop-a")
    local b = mp.get_property_number("ab-loop-b")
    if a and b then
        mp.commandv("no-osd", "set", "ab-loop-a", "no")
        mp.commandv("no-osd", "set", "ab-loop-b", "no")
        feedback_client.show("A–B 循环已关闭", 'action')
        return
    end
    local current = mp.get_property_number("time-pos")
    if not current then return end
    if a then
        if current <= a then
            feedback_client.show("循环终点要晚于起点", 'error')
            return
        end
        mp.commandv("no-osd", "set", "ab-loop-count", "inf")
        mp.commandv("no-osd", "set", "ab-loop-b", current)
        feedback_client.show("A–B 循环已开启", 'action')
    else
        mp.commandv("no-osd", "set", "ab-loop-b", "no")
        mp.commandv("no-osd", "set", "ab-loop-a", current)
        feedback_client.show("循环起点 A  " .. time_text(current, true), 'action')
    end
end)
mp.add_key_binding(nil, "file-loop", function()
    local value = mp.get_property("loop-file", "no")
    local enabled = value ~= "no" and value ~= "0"
    mp.commandv("no-osd", "set", "loop-file", enabled and "no" or "inf")
    feedback_client.show(enabled and "单文件循环已关闭" or "单文件循环已开启", 'action')
end)
local function show_resume_position(position)
    feedback_client.show('播放停在 ' .. time_text(position, position >= 3600) .. '\n重新加载当前媒体可从这里继续', 'error')
end
local ytdl_result = dofile(mp.command_native({'expand-path', '~~/script-modules/ytdl-result.lua'}))
local function network_resume_source()
    if failure_source == 'url' then return true end
    if failure_source ~= 'page' then return end
    -- A browser-supplied CDN stream can have a page Referer, but reloading
    -- that queue entry would reopen the CDN URL instead of extracting the page.
    local page, bv = bilibili_page(expanded_short_page or mp.get_property('path'))
    if not bv or bv:sub(1, 2) ~= 'BV' then return end
    return ytdl_result.bilibili_part(ytdl_result.read(mp, utils), bv, page:match('%?p=(%d+)$') or '1')
end
local network_resume = dofile(mp.command_native({'expand-path', '~~/script-modules/network-resume.lua'})).new(
    mp, network_resume_source, show_resume_position, function()
        feedback_client.show('未能确认原分 P，沿用网页起点', 'notice')
    end)

mp.add_key_binding(nil, "reload", function()
    local path = mp.get_property("path")
    local index = network_resume.prepare_reload()
    if index == false or (not path and not index) then return end
    release_hold()
    reload_pending = true
    -- Preserve only this explicit Reload of the same input; no media history/cache.
    reload_marks = path and {path = path, mark = mark, a = mp.get_property_number("ab-loop-a"),
        b = mp.get_property_number("ab-loop-b"), count = mp.get_property("ab-loop-count", "inf")}
    -- Reuse the playlist entry, including its external audio and per-entry options.
    if mp.commandv("no-osd", "playlist-play-index", index or "current") then
        mp.set_property_bool("pause", false)
    else
        reload_pending, reload_marks = false, nil
        network_resume.reload_rejected()
    end
end)
-- Callable without allocating an unspecified physical shortcut.
mp.add_key_binding(nil, "revert-seek", function()
    seek_pending = true
    seek_timer:kill(); seek_timer:resume()
    mp.commandv("script-message-to", "modernz", "osc-show")
    mp.commandv("no-osd", "revert-seek")
end)
mp.add_key_binding(nil, "audio-only", function()
    local revision=mp.get_property_native('user-data/mpvnet/video-selection-revision',0)
    if saved_video_revision ~= revision then saved_video=nil end
    local vid = mp.get_property_native("vid")
    local has_video = vid ~= nil and vid ~= "no" and vid ~= false and mp.get_property_native("current-tracks/video")
    if has_video then
        saved_video, saved_video_revision = vid, revision
        mp.commandv("no-osd", "set", "vid", "no")
    elseif saved_video ~= nil then
        local restore = saved_video
        saved_video = nil
        for _, track in ipairs(mp.get_property_native("track-list", {})) do
            if track.type == "video" and (restore == "auto" or tostring(track.id) == tostring(restore)) then
                mp.commandv("no-osd", "set", "vid", restore)
                return
            end
        end
    else
        if vid == "no" or vid == false then
            -- A new file has no saved selection; an explicit Restore uses auto.
            for _, track in ipairs(mp.get_property_native("track-list", {})) do
                if track.type == "video" then
                    mp.commandv("no-osd", "set", "vid", "auto")
                    return
                end
            end
        end
    end
end)
mp.register_script_message("seek", function(value, flags) seek(tonumber(value) or 0, flags) end)
mp.register_script_message("show-time", show_time)
mp.register_script_message("set-speed", function(value, mode) set_speed(value, mode == "quiet") end)
mp.register_script_message("add-speed", add_speed)
mp.register_event("playback-restart", function()
    if seek_pending then seek_pending = false; seek_timer:kill(); show_time() end
end)
mp.register_event("seek", function() frame_pending = false end)
mp.add_hook('on_before_start_file', 50, function()
    -- Per-file options have not been applied yet. A process-wide CID belongs
    -- to the launching input, not to every later item in the same instance.
    inherited_cid = mp.get_opt('cid')
end)
mp.register_event("start-file", function(event)
    playback_entry_id, failure_source = event.playlist_entry_id, nil
    expanded_short_page = nil
    origin_active = false
    frame_pending = false
    release_hold()
    saved_video = nil
    mark = nil
    mp.commandv("no-osd", "set", "ab-loop-a", "no")
    mp.commandv("no-osd", "set", "ab-loop-b", "no")
    seek_pending = false
    seek_timer:kill()
end)

local function apply_share_start(start_time)
    if not start_time or mp.get_property('file-local-options/start', 'none') ~= 'none'
        or mp.get_property_native('option-info/start/set-from-commandline')
        or mp.get_property_native('option-info/start/set-locally') then return end
    mp.set_property('file-local-options/start', start_time)
end

-- Resolve at open time so a queued item uses the current Windows proxy.
-- An explicitly configured route (including yt-dlp's empty direct proxy) wins.
local function use_youtube_system_proxy(hook, input)
    local raw_key = 'file-local-options/ytdl-raw-options'
    local http_key = 'file-local-options/http-proxy'
    local function available_options()
        local raw = mp.get_property_native(raw_key, {})
        if type(raw) == 'table' and raw.proxy == nil and mp.get_property(http_key, '') == ''
            and not mp.get_property_native('option-info/http-proxy/set-from-commandline')
            and not mp.get_property_native('option-info/http-proxy/set-locally') then return raw end
    end
    if not available_options() then return end
    local helper = mp.command_native({'expand-path', '~~/helpers/system-http-proxy.ps1'})
    hook:defer()
    local timer
    local handle = mp.command_native_async({name='subprocess', playback_only=true,
        capture_stdout=true, capture_stderr=true, capture_size=2048,
        args={paths.powershell(), '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', helper, input}}, function(ok, result)
        timer:kill()
        if ok and result and result.status == 0 and mp.get_property('stream-open-filename') == input then
            local proxy = (result.stdout or ''):match('^(http://[^%s/@?#]+)[\r\n]*$')
            local raw = proxy and available_options()
            if raw then
                raw.proxy = proxy
                if mp.set_property_native(raw_key, raw) and not mp.set_property(http_key, proxy) then
                    raw.proxy = nil
                    mp.set_property_native(raw_key, raw)
                end
            end
        end
        hook:cont()
    end)
    timer = mp.add_timeout(4, function() mp.abort_async_command(handle) end)
end

-- Apply the shared position before mpv's ytdl_hook (priority 10).
-- The queue keeps the supplied link. Only this playback attempt changes source.
mp.add_hook('on_load', 5, function(hook)
    local input = mp.get_property('stream-open-filename', '')
    if not mp.get_property_native('options/ytdl') then return end
    local _, host, rest = web_address(input)
    if youtube_video_id(host, rest) then
        use_youtube_system_proxy(hook, input)
        return
    end
    if host ~= 'b23.tv' then
        local _, _, start_time = bilibili_page(input)
        apply_share_start(start_time)
        return
    end
    local code = rest:match('^([^?#]*)'):match('^/([A-Za-z0-9]+)/?$')
    local windows = os.getenv('SystemRoot') or os.getenv('WINDIR')
    if not code or #code > 32 or not windows then return end
    hook:defer()
    mp.command_native_async({name='subprocess', playback_only=true, capture_stdout=true,
        args={utils.join_path(windows, 'System32/curl.exe'), '--disable', '--silent', '--head',
            '--output', 'NUL', '--max-time', '4', '--write-out', '%{redirect_url}', 'https://b23.tv/' .. code}},
        function(ok, result)
            if ok and result and result.status == 0 and mp.get_property('stream-open-filename') == input then
                local page, _, start_time = bilibili_page(result.stdout, input)
                if page and mp.set_property('stream-open-filename', web_resume.url_at_time(page, start_time)) then
                    expanded_short_page = page
                    apply_share_start(start_time)
                end
            end
            hook:cont()
        end)
end)
mp.add_hook('on_load', 7, function()
    local key = 'user-data/mpvnet/web-queue-source'
    mp.set_property_native(key, false)
    if not mp.get_property_native('options/ytdl') then return end
    local standalone = mp.get_property_number('playlist-count') == 1 and not mp.get_property('playlist/0/playlist-path')
    local input = mp.get_property('path')
    local _, host, rest = web_address(input)
    local video = youtube_video_id(host, rest)
    if video then
        local list, index, single = youtube_catalog.watch_list(video, rest)
        if not list or mp.get_property('stream-open-filename') ~= input then return end
        if not mp.set_property('stream-open-filename', single) then return end
        local raw = mp.get_property_native('file-local-options/ytdl-raw-options', {})
        if standalone and raw['no-playlist'] == nil then
            mp.set_property_native(key, {provider='youtube', id=mp.get_property_native('playlist/0/id'),
                content_id=video, playlist_id=list, index=index})
        end
        return
    end
    if not standalone then return end
    local page, content_id = bilibili_page(expanded_short_page or mp.get_property('path'))
    local id = mp.get_property_native('playlist/0/id')
    if id and content_id and content_id:sub(1, 2) ~= 'ss' then
        local part = content_id:sub(1, 2) == 'BV' and (tonumber(page:match('%?p=(%d+)$')) or 1) or nil
        mp.set_property_native(key, {provider='bilibili', id=id, content_id=content_id, part=part})
    end
end)

-- File-local source metadata is available here even if opening the stream fails.
mp.add_hook('on_load', 50, function()
    failure_source = capture_media_origin(false)
end)
mp.register_event("end-file", function(event)
    initial_media = false
    origin_active = false
    frame_pending = false
    release_hold()
    if event.reason ~= "stop" then reload_pending = false; reload_marks = nil end
    local resume_position = network_resume.ended(event)
    if resume_position then
        if event.reason == 'error' then
            feedback_client.show('暂时无法续播\n连接恢复后，请重新加载当前媒体', 'error')
        else
            show_resume_position(resume_position)
        end
    elseif event.reason == "error" then
        -- Never echo backend errors: they may contain private paths or URLs.
        local source = playback_entry_id and playback_entry_id == event.playlist_entry_id and failure_source
        local message
        if source == 'youtube' then
            message = "无法播放此 YouTube 视频\n请检查 yt-dlp 和网络代理"
        elseif source == 'page' then
            message = "播放失败\n请回到原网页，再用外部播放器播放"
        elseif source == 'url' then
            message = "无法播放此网址\n请重新获取媒体直链后打开"
        elseif (event.error or event.file_error) == "unrecognized file format" then
            message = "不支持此格式\n请换一个文件"
        else
            message = "播放失败\n请检查文件或网址"
        end
        feedback_client.show(message, 'error')
    end
    playback_entry_id, failure_source = nil, nil
end)
mp.register_event("file-loaded", function()
    failure_source = capture_media_origin(true)
    if reload_marks and mp.get_property("path") == reload_marks.path then
        mark = reload_marks.mark
        mp.commandv("no-osd", "set", "ab-loop-count", reload_marks.count)
        mp.commandv("no-osd", "set", "ab-loop-a", reload_marks.a or "no")
        mp.commandv("no-osd", "set", "ab-loop-b", reload_marks.b or "no")
    end
    reload_marks = nil
    if reload_pending then reload_pending = false; mp.set_property_bool("pause", false) end
end)
mp.observe_property("focused", "bool", function(_, focused)
    if focused == false then release_hold() end
end)
mp.register_event("shutdown", function()
    release_hold()
    if window_scale_timer then window_scale_timer:kill(); window_scale_timer = nil end
    for path, request in pairs(path_requests) do mp.abort_async_command(request); os.remove(path) end
end)
capture_media_origin(true)

-- Report sustained underruns only after network VOD has started playing.
local buffering_key = 'user-data/mpvnet/feedback/buffering'
local network_vod, buffering_visible = false, false

local function waiting_for_cache()
    return network_vod and mp.get_property_bool('paused-for-cache') and not mp.get_property_bool('pause')
end

local buffering_timer = mp.add_timeout(1, function()
    if waiting_for_cache() then
        buffering_visible = true
        mp.set_property_native(buffering_key, '正在缓冲…')
    end
end)
buffering_timer:kill()

local function update_buffering()
    if waiting_for_cache() then
        if not buffering_visible and not buffering_timer:is_enabled() then buffering_timer:resume() end
    else
        buffering_timer:kill()
        if buffering_visible then
            buffering_visible = false
            mp.set_property_native(buffering_key, '')
        end
    end
end

local function clear_buffering()
    network_vod = false
    update_buffering()
end

mp.register_event('playback-restart', function()
    network_vod = mp.get_property_bool('demuxer-via-network') and mp.get_property_number('duration', 0) > 0
    update_buffering()
end)
mp.observe_property('paused-for-cache', 'bool', update_buffering)
mp.observe_property('pause', 'bool', update_buffering)
mp.register_event('end-file', clear_buffering)
mp.register_event('shutdown', clear_buffering)
