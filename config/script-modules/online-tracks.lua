-- yt-dlp owns extraction and stream selection. Keep only format descriptions,
-- never signed media URLs or request headers, in the current item's catalogue.
local M = {}
local ytdl_result = dofile(require('mp').command_native({'expand-path', '~~/script-modules/ytdl-result.lua'}))
local providers = {Youtube=true, BiliBili=true, BiliBiliBangumi=true}
local names = {en='英语', ['en-US']='英语（美国）', ja='日语', zh='中文', ['zh-Hans']='简体中文',
    ['zh-Hant']='繁体中文', fr='法语', ['fr-FR']='法语（法国）', de='德语', ['de-DE']='德语（德国）',
    es='西班牙语', ['es-US']='西班牙语（美国）', it='意大利语', pt='葡萄牙语', ['pt-BR']='葡萄牙语（巴西）',
    hi='印地语', id='印度尼西亚语', pl='波兰语', uk='乌克兰语', ko='韩语', ru='俄语'}

local function token(value)
    return type(value) == 'string' and #value <= 90 and value:match('^[%w_%-%.]+$') and value
end

local function description(f)
    if type(f) ~= 'table' or f.has_drm or not token(f.format_id) then return end
    if f.protocol ~= 'https' and f.protocol ~= 'http' and f.protocol ~= 'm3u8_native' and f.protocol ~= 'm3u8' then return end
    local height = tonumber(f.height)
    if f.acodec == 'none' and f.vcodec and f.vcodec ~= 'none' and height and height > 0 and height <= 32768 and height == math.floor(height) then
        return {kind='video', key=height, title=height..'p', id=f.format_id, protocol=f.protocol,
            width=f.width, height=height, fps=f.fps, codec=f.vcodec}
    end
    if f.vcodec ~= 'none' or f.acodec == 'none' then return end
    local lang = token(f.language)
    if f.language and not lang then return end
    local note = type(f.format_note)=='string' and f.format_note:lower() or ''
    local role = note:find('description',1,true) and '口述影像' or note:find('commentary',1,true) and '评论' or
        note:find('original',1,true) and '原声' or note:find('dubbed',1,true) and '配音' or ''
    local label = lang and (names[lang] or names[lang:match('^[^-]+')] or lang) or '语言未标注'
    return {kind='audio', lang=lang, role=role, title=label,
        id=f.format_id, protocol=f.protocol, codec=f.acodec, channels=f.audio_channels, rate=f.asr}
end

function M.catalog(data)
    if type(data) ~= 'table' or not providers[data.extractor_key] or data.is_live or
        type(data.formats) ~= 'table' or #data.formats > 4096 or type(data.requested_formats) ~= 'table' then return end
    local catalog = {media_id=data.id, video={}, audio={}, selected={}, choices={}}
    local formats, voices = {}, {}
    for _, f in ipairs(data.formats) do
        local d = description(f)
        if d then
            formats[#formats+1] = d
            if d.kind == 'audio' and d.role ~= '' then
                local lang = d.lang or ''
                local roles = voices[lang] or {}
                roles[d.role] = true
                voices[lang] = roles
            end
        end
    end
    local function identify(d)
        if d.kind ~= 'audio' then return end
        local roles = voices[d.lang or ''] or {}
        -- Some transports omit "dubbed" for the same language. A distinct
        -- commentary is never evidence that an unmarked track is commentary.
        if d.role == '' and not (roles['原声'] and roles['配音']) then
            d.role = roles['原声'] and '原声' or roles['配音'] and '配音' or ''
        end
        d.ambiguous_voice = roles['原声'] and roles['配音']
        d.key = (d.lang or '')..'/'..d.role
        if d.role ~= '' then d.title = d.title..' · '..d.role end
    end
    for _, f in ipairs(data.requested_formats) do
        local d = description(f)
        if not d or catalog.selected[d.kind] then return end
        identify(d)
        catalog.selected[d.kind] = d
    end
    if not catalog.selected.video or not catalog.selected.audio then return end
    local by_key = {video={}, audio={}}
    for _, d in ipairs(formats) do
        identify(d)
        local groups = by_key[d.kind]
        local previous = groups[d.key]
        -- yt-dlp orders formats from least to most preferred. Prefer a
        -- direct HTTPS rendition within the same height or language.
        if not previous or d.protocol == 'https' or previous.protocol ~= 'https' then
            groups[d.key] = d
        end
    end
    for _, kind in ipairs({'video','audio'}) do
        local chosen = catalog.selected[kind]
        if not by_key[kind][chosen.key] then return end
        for _, d in pairs(by_key[kind]) do
            catalog[kind][#catalog[kind]+1] = d
        end
        table.sort(catalog[kind], function(a,b)
            if kind == 'video' then return a.height > b.height end
            if (a.role == '原声') ~= (b.role == '原声') then return a.role == '原声' end
            return a.key < b.key
        end)
        for i,d in ipairs(catalog[kind]) do
            -- Native track IDs are signed C integers; virtual IDs never collide.
            d.row_id = 2^32 + (kind == 'audio' and 4096 or 0) + i
            catalog.choices[d.row_id] = d
        end
    end
    return catalog
end

function M.rows(catalog, kind, native)
    if not catalog or not catalog[kind] or #native ~= 1 or native[1].external then return native end
    local rows = {}
    for i,d in ipairs(catalog[kind]) do
        local chosen = d.key == catalog.selected[kind].key
        local row = {}
        if chosen then for k,v in pairs(native[1]) do row[k] = v end end
        row.id = chosen and native[1].id or d.row_id
        row.title, row.online, row.number_text = d.title, true, tostring(i)
        row.lang = d.lang or row.lang
        row.codec = row.codec or d.codec
        row['demux-w'] = row['demux-w'] or d.width
        row['demux-h'] = row['demux-h'] or d.height
        row['demux-fps'] = row['demux-fps'] or d.fps
        row['demux-channel-count'] = row['demux-channel-count'] or d.channels
        row['demux-samplerate'] = row['demux-samplerate'] or d.rate
        rows[#rows+1] = row
    end
    return rows
end

local function selector(d)
    local best = d.kind == 'video' and 'bestvideo' or 'bestaudio'
    local filter = d.height and ('[height='..d.height..']') or d.lang and ('[language='..d.lang..']') or ''
    -- YouTube's numeric suffix may be reassigned between extractions. Guard
    -- the ID with its language and retain explicit audio roles on fallback.
    local role_filter = {['评论']='commentary', ['口述影像']='description'}
    if d.ambiguous_voice then role_filter['原声'], role_filter['配音'] = 'original', 'dubbed' end
    if role_filter[d.role] then filter = filter..'[format_note*='..role_filter[d.role]..']' end
    return '('..d.id..filter..'/'..best..filter..'[protocol=https]/'..best..filter..')'
end

function M.format(pair)
    return selector(pair.video)..'+'..selector(pair.audio)
end

-- Resolve the viewer's choices against this episode's catalogue. Its original
-- selection is the fallback for each stream independently.
local function preferred_audio(tracks, choice)
    if not choice then return end
    local ordinary
    for _,track in ipairs(tracks) do
        if track.lang == choice.lang then
            if track.role == choice.role then return track end
            if choice.role ~= '评论' and choice.role ~= '口述影像' and
                track.role ~= '评论' and track.role ~= '口述影像' then ordinary = ordinary or track end
        end
    end
    return ordinary
end

local function episode_formats(c, choices)
    local video = c.selected.video
    for _,track in ipairs(c.video) do
        if track.height == choices.height then video = track; break end
    end
    local audio = preferred_audio(c.audio, choices.voice) or c.selected.audio
    if video.key ~= c.selected.video.key or audio.key ~= c.selected.audio.key then
        return {video=video, audio=audio}
    end
end

function M.read(mp, utils)
    local data = ytdl_result.read(mp, utils)
    if data == nil then return end
    return M.catalog(data) or false
end

-- An extracted dub can carry the original container language on every version.
-- Only attribute the website language to the unambiguous, active native stream.
function M.audio_label(catalog, tracks)
    if not catalog then return end
    local audio
    for _,track in ipairs(tracks) do
        if track.type == 'audio' then
            if audio or track.external or not track.selected then return end
            audio = track
        end
    end
    local selected = catalog.selected.audio
    if audio and selected.lang then return selected.title end
end

-- Bind a reload and its single recovery attempt to the original queue entry.
function M.new(mp, utils)
    local state = {}
    local catalog, pending, choices

    function state.catalog()
        if catalog ~= nil then return catalog or nil end
        catalog = M.read(mp, utils)
        return catalog or nil
    end

    local function entry()
        local pos = mp.get_property_number('playlist-pos', -1)
        if pos < 0 then return end
        return mp.get_property_native('playlist/'..pos..'/id'), mp.get_property('playlist/'..pos..'/filename')
    end

    local function same()
        local id, path = entry()
        return pending and pending.id == id and pending.path == path
    end

    local function remember(request)
        local selected = request.target[request.kind]
        choices = choices or {id=request.id, path=request.path}
        if request.kind == 'video' then
            choices.height = selected.height
        else
            choices.voice = selected.lang and {lang=selected.lang, role=selected.role} or nil
        end
        if not choices.height and not choices.voice then choices = nil end
    end

    function state.forget(kind)
        if not choices or (kind ~= 'audio' and kind ~= 'video') or not state.catalog() then return end
        if kind == 'video' then choices.height = nil else choices.voice = nil end
        if not choices.voice and not choices.height then choices = nil end
    end

    local function enter_playlist_item()
        if not choices then return end
        local id, path = entry()
        if id == choices.id and path == choices.path then return end
        -- mpv retains entry IDs when a queue is reordered or appended to.
        -- Opening even the same URL separately creates a fresh entry.
        for _,item in ipairs(mp.get_property_native('playlist', {})) do
            if id and item.id == choices.id and item.filename == choices.path then
                choices.id, choices.path = id, path
                return
            end
        end
        choices = nil
    end

    local function recover()
        if not same() then pending = nil; return end
        if pending.restoring then
            pending = nil
            mp.osd_message('原版本也无法播放，请重新打开视频。', 4)
            return
        end
        pending.restoring = true
        pending.loading = false
        if not mp.commandv('no-osd','playlist-play-index','current') then
            pending = nil
            mp.osd_message('未能重新打开原版本。', 3)
        end
    end

    function state.switch(kind, row_id)
        local c = state.catalog()
        local target = c and c.choices[row_id]
        if not target or target.kind ~= kind then return false,'该在线版本已失效，请重新选择。' end
        if pending then return false,'正在切换在线版本，请稍候。' end
        local id, path = entry()
        local position = mp.get_property_number('time-pos')
        if not id or path ~= mp.get_property('path') or not position or position < 0 or
            not mp.get_property_native('seekable') then return false,'当前播放项无法从原处续播。' end
        local pair = {video=c.selected.video, audio=c.selected.audio}
        pair[kind] = target
        -- A reload cannot recreate a file the viewer added during playback.
        for _,track in ipairs(mp.get_property_native('track-list', {})) do
            local restored_sub = track.type == 'sub' and (track.title == 'Bilibili Danmaku' or
                (track['external-filename'] or ''):match('^edl://!no_clip;!delay_open,media_type=sub'))
            if track.external and not restored_sub then
                return false,'当前有外挂轨道，重新取流会将它移除。'
            end
        end
        pending = {id=id, path=path, media_id=c.media_id, position=position, previous=c.selected, target=pair, kind=kind,
            video_off=mp.get_property('vid')=='no', audio_off=mp.get_property('aid')=='no'}
        if not mp.commandv('no-osd','playlist-play-index','current') then
            pending = nil
            return false,'未能切换当前播放项。'
        end
        mp.osd_message('正在切换到'..target.title..'…', 2)
        return true
    end

    mp.add_hook('on_load', 9, function()
        catalog = nil
        enter_playlist_item()
        if not same() then pending = nil; return end
        pending.loading = true
        if pending.kind or not pending.restoring then
            local pair = pending.restoring and pending.previous or pending.target
            mp.set_property('file-local-options/ytdl-format', M.format(pair))
        end
        if pending.position then
            mp.set_property('file-local-options/start', string.format('%.6f', pending.position))
            for kind,option in pairs({audio='aid', video='vid'}) do
                local off = pending[kind..'_off'] and (pending.restoring or pending.kind ~= kind)
                mp.set_property('file-local-options/'..option, off and 'no' or 'auto')
            end
        end
    end)
    local function apply_episode_choices()
        if pending or not choices then return end
        local c = state.catalog()
        local pair = c and episode_formats(c, choices)
        if not pair then return end
        local id, path = entry()
        if id ~= choices.id or path ~= choices.path or path ~= mp.get_property('path') or
            mp.get_property_number('playlist-playing-pos', -1) ~= mp.get_property_number('playlist-pos') then return end
        pending = {id=id, path=path, media_id=c.media_id, previous=c.selected, target=pair}
        if not mp.commandv('no-osd', 'playlist-play-index', 'current') then pending = nil end
    end
    -- The built-in hook extracts YouTube in on_load and can extract Bilibili
    -- in on_load_fail. Decide before mpv starts the default rendition.
    mp.add_hook('on_load', 45, apply_episode_choices)
    mp.add_hook('on_load_fail', 45, apply_episode_choices)
    mp.add_hook('on_preloaded', 45, function()
        if same() and pending.loading and pending.position then
            -- The upstream hook can apply the share URL's timestamp after extraction.
            mp.set_property('file-local-options/start', string.format('%.6f', pending.position))
        end
    end)
    mp.register_event('playback-restart', function()
        if not same() or not pending.loading then return end
        -- A failed automatic choice retries this episode using its original
        -- options. Its current default can change between extractions.
        if pending.restoring and not pending.kind then
            mp.osd_message('已改用本集默认版本。', 2)
            pending = nil
            return
        end
        local current = state.catalog()
        local pair = pending.restoring and pending.previous or pending.target
        if not current or current.media_id ~= pending.media_id or current.selected.audio.key ~= pair.audio.key or
            current.selected.video.key ~= pair.video.key or
            (mp.get_property('vid') ~= 'no' and mp.get_property_number('video-params/h') ~= pair.video.height) or
            (mp.get_property('aid') ~= 'no' and not mp.get_property_number('audio-params/samplerate')) then
            recover()
            return
        end
        if pending.restoring then
            mp.osd_message('切换失败，已回到原版本。', 2)
        elseif pending.kind then
            remember(pending)
            mp.osd_message('已切换到'..current.selected[pending.kind].title, 2)
        end
        pending = nil
    end)
    mp.register_event('end-file', function(event)
        catalog = nil
        if not pending or not pending.loading then return end
        if event.playlist_entry_id == pending.id and event.reason == 'error' then
            pending.failed = true
        else
            pending = nil
        end
    end)
    -- This hook runs after end-file and before mpv advances on an open error.
    mp.add_hook('on_after_end_file', 60, function()
        if pending and pending.failed then
            pending.failed = nil
            recover()
        end
    end)
    mp.register_event('idle', function() pending, choices = nil, nil end)
    return state
end

return M
