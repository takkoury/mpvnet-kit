-- The screen menu exposes fixed bindings; player data only controls visibility.
local M = {}
local bitmap_codecs = {
    dvd_subtitle=true, dvb_subtitle=true, hdmv_pgs_subtitle=true, xsub=true,
    vobsub=true, pgs=true, dvbsub=true, dvdsub=true,
}

local function array(value)
    return type(value) == 'table' and value or {}
end

local function positive_integer(value)
    return type(value) == 'number' and value > 0 and value < math.huge and value == math.floor(value)
end

function M.snapshot(get)
    local counts = {sub=0, audio=0, video=0}
    local sub = get('current-tracks/sub')
    local current_sub_id = type(sub) == 'table' and sub.id
    local has_current_sub = false
    for _, track in ipairs(array(get('track-list'))) do
        if type(track) == 'table' and counts[track.type] and positive_integer(track.id) then
            counts[track.type] = counts[track.type] + 1
            if track.type == 'sub' and track.id == current_sub_id then has_current_sub = true end
        end
    end
    local text_sub = has_current_sub and
        type(sub.codec) == 'string' and sub.codec:match('%S') and not bitmap_codecs[sub.codec:lower()]
    local playlist_count = get('playlist-count')
    local has_chapter = false
    for _, chapter in ipairs(array(get('chapter-list'))) do
        local time = type(chapter) == 'table' and chapter.time
        if type(time) == 'number' and time >= 0 and time < math.huge then
            has_chapter = true
            break
        end
    end
    local edition_count = 0
    for _, edition in ipairs(array(get('edition-list'))) do
        if type(edition) == 'table' then edition_count = edition_count + 1 end
    end
    local disc = get('current-demuxer') == 'disc'
    local filename = get('filename')
    local has_file = type(filename) == 'string' and filename:match('%S') and not filename:find('%z')

    local rows, targets = {}, {}
    local function item(id, title, binding, available)
        if available then
            rows[#rows + 1] = {id=id, title=title}
            targets[id] = binding
        end
    end
    -- IDs name actions and remain stable when earlier rows are hidden.
    item(1, '主字幕轨', 'track_selection/select-primary', counts.sub > 0)
    item(2, '次字幕轨', 'track_selection/select-secondary', counts.sub > 1)
    item(3, '字幕行', 'track_selection/select-subtitle-line', text_sub)
    item(4, '音轨', 'track_selection/select-audio', counts.audio > 1)
    item(5, '视频轨', 'track_selection/select-video', counts.video > 1)
    item(6, '播放列表（屏幕内）', 'select/select-playlist', positive_integer(playlist_count) and playlist_count > 1)
    item(7, '章节', 'track_selection/select-chapter', has_chapter)
    item(8, disc and '标题（光盘）' or '媒体版本', 'track_selection/select-edition', edition_count > 1)
    item(9, '音频设备', 'track_selection/select-device', counts.audio > 0)
    item(10, '执行快捷键动作', 'track_selection/select-binding', true)
    item(11, '播放历史', 'track_selection/select-history', true)
    item(12, '稍后继续播放', 'track_selection/select-watch-later', true)
    item(13, '播放统计', 'stats/display-page-1-toggle', true)
    item(14, '文件信息（统计）', 'stats/display-page-5-toggle', has_file)
    item(15, '常用设置', 'user_settings/open', true)
    item(16, '快捷键帮助（统计）', 'stats/display-page-4-toggle', true)
    item(17, 'mpv 在线文档', 'select/open-docs', true)
    return rows, targets
end

return M
