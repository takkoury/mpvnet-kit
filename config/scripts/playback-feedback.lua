-- Focused playback actions shared by input.conf and ModernZ.
-- No property observer emits OSD: feedback belongs to explicit user actions.
local mp = require("mp")
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
local mark
local reload_marks
local window_scale_timer
local info_active, info_request = false, nil
local path_requests = {}
local path_sequence = 0
-- One in-memory association only; never retain request headers or infer a page from CID/CDN.
local origin_path, origin_page, origin_active

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

local function bilibili_page(value)
    local address, host, rest = web_address(value)
    if not address or not site_host(host, 'bilibili.com') then return end
    local path = rest:match('^([^?#]*)')
    local bvid = path:match('^/video/(BV%w+)/?$')
    if bvid and #bvid == 12 then
        local page = 'https://www.bilibili.com/video/' .. bvid .. '/'
        -- External Player 1.2.7 strips query parameters; only preserve P if metadata actually supplied it.
        for item in (rest:match('%?([^#]*)') or ''):gmatch('[^&]+') do
            local part = item:match('^p=([1-9]%d*)$')
            if part then return page .. '?p=' .. part end
        end
        return page
    end
    local episode = path:match('^/bangumi/play/(ep[1-9]%d*)/?$') or path:match('^/bangumi/play/(ss[1-9]%d*)/?$')
    if episode then return 'https://www.bilibili.com/bangumi/play/' .. episode end
end

local function capture_media_origin()
    origin_active = false
    local path = mp.get_property('path')
    local _, host = web_address(path)
    if not site_host(host, 'bilivideo.com') then return end
    local page = bilibili_page(mp.get_property('file-local-options/referrer'))
    if not page then
        local headers = mp.get_property_native('file-local-options/http-header-fields', {})
        for _, header in ipairs(type(headers) == 'table' and headers or {}) do
            if type(header) == 'string' and (header:match('^%s*([^:]+):') or ''):lower() == 'referer' then
                page = bilibili_page(header:match('^[^:]+:%s*(.-)%s*$'))
                if page then break end
            end
        end
    end
    -- The same unchanged global Referer on a different CDN input is not evidence of that media's page.
    if page and (not origin_page or page ~= origin_page or path == origin_path) then
        origin_path, origin_page, origin_active = path, page, true
    end
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
    mp.osd_message(time_text(current, hours) .. " / " .. time_text(total, hours), 1)
end

local function show_speed()
    local speed = mp.get_property_number("speed", 1)
    local number = string.format(speed % 1 == 0 and "%.1f" or "%g", speed)
    mp.osd_message("SPEED: ×" .. number, 1)
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
    mp.osd_message(paused and "PAUSE" or "PLAY", 1)
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
    mp.osd_message(enabled and "ON TOP" or "ON TOP OFF", 1)
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
    mp.osd_message("WINDOW 100%", 1)
end)
mp.add_key_binding(nil, "media-info", function()
    local path = mp.get_property("path")
    if info_active or not path then return end
    local file = not path:find("://", 1, true) and utils.file_info(path)
    if file and file.is_file then
        -- Keep the accepted rich native dialog for actual local files.
        mp.commandv("script-message-to", "mpvnet", "show-media-info", "msgbox")
        return
    end
    local title = mp.get_property("media-title", "Media")
    -- Technical URL titles can contain access tokens. Never send the input URL or headers.
    if title:find("://", 1, true) or title == mp.get_property("filename") then
        title = title:gsub("[?#].*$", "")
    end
    local width = mp.get_property_number("video-params/w")
    local height = mp.get_property_number("video-params/h")
    local fields = {
        {label = "TITLE", value = title},
        {label = "DURATION", value = time_text(mp.get_property_number("duration"), true)},
        {label = "VIDEO FORMAT", value = mp.get_property("video-format", "--")},
        {label = "RESOLUTION", value = width and height and string.format("%d × %d", width, height) or "--"},
        {label = "FRAME RATE", value = mp.get_property("container-fps", "--")},
        {label = "AUDIO CODEC", value = mp.get_property("audio-codec-name", "--")},
        {label = "SAMPLE RATE", value = mp.get_property("audio-params/samplerate", "--")},
        {label = "CHANNELS", value = mp.get_property("audio-params/channel-count", "--")},
    }
    local helper = mp.command_native({"expand-path", "~~/helpers/media-info-window.ps1"})
    info_active = true
    info_request = mp.command_native_async({name = "subprocess", args = {
        paths.powershell(), "-NoProfile", "-STA", "-ExecutionPolicy", "Bypass", "-File", helper,
        "-ParentPid", tostring(mp.get_property_number("pid")),
    }, stdin_data = utils.format_json({fields = fields}), capture_stderr = true, playback_only = false},
    function(success, result, error)
        info_active, info_request = false, nil
        if not success or (result and result.status ~= 0) then
            mp.msg.warn("Media info window failed: " .. tostring(error or (result and result.stderr)))
        end
    end)
end)
mp.add_key_binding(nil, "osc-visibility", function()
    local mode = mp.get_property_native("user-data/osc/visibility") == "never" and "auto" or "never"
    mp.commandv("script-message-to", "modernz", "osc-visibility", mode, "yes")
    if mode == "auto" then mp.commandv("script-message-to", "modernz", "osc-show") end
end)
mp.add_key_binding(nil, "copy-time", function()
    local current = mp.get_property_number("time-pos")
    if not current or current < 0 or current ~= current or current == math.huge then
        mp.osd_message("NO TIME", 1)
        return
    end
    -- Round the full timestamp before splitting so milliseconds carry across minutes/hours.
    local milliseconds = math.floor(current * 1000 + 0.5)
    local seconds = math.floor(milliseconds / 1000)
    local text = time_text(seconds, true) .. string.format(".%03d", milliseconds % 1000)
    local ok = mp.set_property("clipboard/text", text)
    mp.osd_message(ok and "TIME COPIED" or "TIME COPY FAILED", 1)
end)
mp.add_key_binding(nil, "copy-media-path", function()
    local address, kind = media_address()
    local ok = address and mp.set_property("clipboard/text", address)
    mp.osd_message(kind .. (ok and " COPIED" or " COPY FAILED"), 1)
end)
mp.add_key_binding(nil, "open-media-path", function()
    local address, kind = media_address()
    if not address then mp.osd_message(kind .. " OPEN FAILED", 1); return end
    -- Windows mpv subprocess stdin_data is unreliable; transport data in one owned UTF-8 JSON file.
    path_sequence = path_sequence + 1
    local directory = os.getenv("TEMP") or os.getenv("TMP")
    local absolute = directory and (directory:match("^%a:[\\/]") or directory:match("^\\\\"))
    local metadata = absolute and utils.file_info(directory)
    if not metadata or not metadata.is_dir then mp.osd_message(kind .. " OPEN FAILED", 1); return end
    local request_path = utils.join_path(directory, "mpvnet-path-" .. tostring(mp.get_property_number("pid")) .. "-" .. tostring(mp.get_time()):gsub("%W", "") .. "-" .. path_sequence .. ".json")
    local file = io.open(request_path, "wb")
    if not file then mp.osd_message(kind .. " OPEN FAILED", 1); return end
    local written = file:write(utils.format_json({operation = kind == "URL" and "url" or "reveal", address = address}))
    local closed = file:close()
    if not written or not closed then os.remove(request_path); mp.osd_message(kind .. " OPEN FAILED", 1); return end
    local helper = mp.command_native({"expand-path", "~~/helpers/media-path-action.ps1"})
    path_requests[request_path] = mp.command_native_async({name = "subprocess", args = {
        paths.powershell(), "-NoProfile", "-NonInteractive", "-STA", "-ExecutionPolicy", "Bypass", "-File", helper, "-RequestPath", request_path,
    }, capture_stderr = true, playback_only = false}, function(success, result)
        path_requests[request_path] = nil
        os.remove(request_path)
        if not success or not result or result.status ~= 0 then mp.osd_message(kind .. " OPEN FAILED", 1) end
    end)
end)
mp.add_key_binding(nil, "clipboard-url", function()
    -- Read only on this explicit action; reject local paths and multiple clipboard lines.
    local text = mp.get_property("clipboard/text")
    if not text then return end
    text = text:match("^%s*(.-)%s*$")
    if text:find("%s") or text:find("%c") then return end
    local scheme, authority = text:match("^([%a][%w+.-]*)://([^/?#]+)")
    if not scheme or not authority or (scheme:lower() ~= "http" and scheme:lower() ~= "https") then return end
    mp.commandv("no-osd", "loadfile", text, "replace")
end)
mp.add_key_binding(nil, "save-mark", function()
    local current = mp.get_property_number("time-pos")
    if not current or not mp.get_property("path") then return end
    mark = current
    mp.osd_message("MARK " .. time_text(mark, true), 1)
end)
mp.add_key_binding(nil, "jump-mark", function()
    if mark == nil then mp.osd_message("NO MARK", 1); return end
    seek(mark, "absolute+exact")
end)
mp.add_key_binding(nil, "ab-loop", function()
    if not mp.get_property("path") then return end
    local a = mp.get_property_number("ab-loop-a")
    local b = mp.get_property_number("ab-loop-b")
    if a and b then
        mp.commandv("no-osd", "set", "ab-loop-a", "no")
        mp.commandv("no-osd", "set", "ab-loop-b", "no")
        mp.osd_message("A-B LOOP OFF", 1)
        return
    end
    local current = mp.get_property_number("time-pos")
    if not current then return end
    if a then
        if current <= a then
            mp.osd_message("LOOP B MUST FOLLOW A", 1)
            return
        end
        mp.commandv("no-osd", "set", "ab-loop-count", "inf")
        mp.commandv("no-osd", "set", "ab-loop-b", current)
        mp.osd_message("A-B LOOP", 1)
    else
        mp.commandv("no-osd", "set", "ab-loop-b", "no")
        mp.commandv("no-osd", "set", "ab-loop-a", current)
        mp.osd_message("LOOP A · " .. time_text(current, true), 1)
    end
end)
mp.add_key_binding(nil, "file-loop", function()
    local value = mp.get_property("loop-file", "no")
    local enabled = value ~= "no" and value ~= "0"
    mp.commandv("no-osd", "set", "loop-file", enabled and "no" or "inf")
    mp.osd_message(enabled and "FILE LOOP OFF" or "FILE LOOP", 1)
end)
mp.add_key_binding(nil, "reload", function()
    local path = mp.get_property("path")
    if not path then return end
    release_hold()
    reload_pending = true
    -- Preserve only this explicit Reload of the same input; no media history/cache.
    reload_marks = {path = path, mark = mark, a = mp.get_property_number("ab-loop-a"),
        b = mp.get_property_number("ab-loop-b"), count = mp.get_property("ab-loop-count", "inf")}
    -- Reuse the playlist entry, including its external audio and per-entry options.
    mp.commandv("no-osd", "playlist-play-index", "current")
    mp.set_property_bool("pause", false)
end)
-- Callable without allocating an unspecified physical shortcut.
mp.add_key_binding(nil, "revert-seek", function()
    seek_pending = true
    seek_timer:kill(); seek_timer:resume()
    mp.commandv("script-message-to", "modernz", "osc-show")
    mp.commandv("no-osd", "revert-seek")
end)
mp.add_key_binding(nil, "audio-only", function()
    if saved_video ~= nil then
        local restore = saved_video
        saved_video = nil
        for _, track in ipairs(mp.get_property_native("track-list", {})) do
            if track.type == "video" and (restore == "auto" or tostring(track.id) == tostring(restore)) then
                mp.commandv("no-osd", "set", "vid", restore)
                return
            end
        end
    else
        local vid = mp.get_property_native("vid")
        if vid ~= nil and vid ~= "no" and vid ~= false and mp.get_property_native("current-tracks/video") then
            saved_video = vid
            mp.commandv("no-osd", "set", "vid", "no")
        elseif vid == "no" or vid == false then
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
mp.register_event("start-file", function()
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
mp.register_event("end-file", function(event)
    origin_active = false
    frame_pending = false
    release_hold()
    if event.reason ~= "stop" then reload_pending = false; reload_marks = nil end
end)
mp.register_event("file-loaded", function()
    capture_media_origin()
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
    if info_request then mp.abort_async_command(info_request); info_request = nil end
    for path, request in pairs(path_requests) do mp.abort_async_command(request); os.remove(path) end
end)
capture_media_origin()
