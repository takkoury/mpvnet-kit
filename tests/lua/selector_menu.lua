-- Exercise the actual screen menu and shared controller with a host/renderer double.
local properties, bindings, observers, events = {}, {}, {}, {}
local commands, messages, requests, updates = {}, {}, {}, {}
local opened, request, command_hook, update_hook, module_missing, read_failure
local notify_on_open, close_hook
local function eq(actual, expected)
    assert(actual == expected, 'expected '..tostring(expected)..', got '..tostring(actual))
end
local function notify(name)
    assert(observers[name], 'property is not observed: '..name)(name, properties[name])
end
local function put(name, value, silent)
    properties[name] = value
    if not silent then notify(name) end
end
local mp = {
    get_property_native=function(name, default)
        if name == read_failure then error('private property failure') end
        if properties[name] ~= nil then return properties[name] end
        return default
    end,
    add_key_binding=function(key, name, fn) eq(key, nil); bindings[name] = fn end,
    observe_property=function(name, kind, fn)
        eq(kind, 'native'); eq(observers[name], nil); observers[name] = fn
        -- mpv delivers an initial notification even if the property is absent.
        fn(name, properties[name])
    end,
    register_event=function(name, fn) events[name] = fn end,
    command_native=function(args)
        eq(args[1], 'expand-path'); return args[2]
    end,
    commandv=function(...)
        eq(opened, false)
        commands[#commands + 1] = {...}
        if command_hook then return command_hook(...) end
        return true
    end,
    osd_message=function(message) messages[#messages + 1] = message end,
}
package.loaded.mp = mp
local renderer = {
    open=function(options)
        assert(not opened, 'old panel must release input before opening another')
        opened, request = true, options
        requests[#requests + 1] = options
        if notify_on_open and options.kind == 'menu' then
            for _, name in ipairs(notify_on_open) do notify(name) end
        end
        return true
    end,
    close=function()
        opened = false
        -- Retirement must precede this synchronous old close callback.
        if request then request.close() end
        if close_hook then close_hook() end
    end,
    is_open=function() return opened end,
    update=function(rows, current, notice, state)
        assert(opened)
        request.tracks, request.current_id, request.notice, request.state = rows, current, notice, state
        updates[#updates + 1] = rows
        if update_hook then update_hook() end
    end,
}
local dofile = function(path)
    if path == '~~/script-modules/selector-menu.lua' then
        if module_missing then error('private module path') end
        return make_menu()
    end
    eq(path, '~~/script-modules/track-selector.lua')
    return renderer
end

-- COMPLETE SOURCE IS INSERTED HERE

local observed = {'track-list', 'current-tracks/sub', 'playlist-count', 'chapter-list',
    'edition-list', 'current-demuxer', 'filename'}
local subtitle = {type='sub', id=1, codec='ass'}
local audio = {type='audio', id=1, codec='aac'}
local static = {type='video', id=1, image=true, albumart=true}
local all_tracks = {subtitle, {type='sub', id=2}, audio, {type='audio', id=2}, static, {type='video', id=2}}
local tools_only = '10,11,12,13,15,16,17'
local function setup_all()
    properties = {['track-list']=all_tracks, ['current-tracks/sub']=subtitle, ['playlist-count']=2,
        ['chapter-list']={{time=0}}, ['edition-list']={{id=0},{id=1}}, filename='中文.mkv'}
end
local function ids(rows)
    local result = {}
    for _, row in ipairs(rows) do
        assert(type(row.id) == 'number' and row.id > 0 and row.id == math.floor(row.id))
        result[#result + 1] = row.id
        for key in pairs(row) do assert(key == 'id' or key == 'title', 'unexpected row data: '..key) end
    end
    return table.concat(result, ',')
end
local function title(id)
    for _, row in ipairs(request.tracks) do if row.id == id then return row.title end end
end
local function open_menu()
    bindings.menu()
    eq(opened, true); eq(request.kind, 'menu'); eq(request.current_id, 0); eq(request.notice, '')
    return request
end

local function all_whitelisted_actions_dispatch_after_close()
    setup_all()
    local expected = {
        {'主字幕轨', 'track_selection/select-primary'},
        {'次字幕轨', 'track_selection/select-secondary'},
        {'字幕行', 'track_selection/select-subtitle-line'},
        {'音轨', 'track_selection/select-audio'},
        {'视频轨', 'track_selection/select-video'},
        {'播放列表（屏幕内）', 'select/select-playlist'},
        {'章节', 'track_selection/select-chapter'},
        {'媒体版本', 'track_selection/select-edition'},
        {'音频设备', 'track_selection/select-device'},
        {'执行快捷键动作', 'track_selection/select-binding'},
        {'播放历史', 'track_selection/select-history'},
        {'稍后继续播放', 'track_selection/select-watch-later'},
        {'播放统计', 'stats/display-page-1-toggle'},
        {'文件信息（统计）', 'stats/display-page-5-toggle'},
        {'常用设置', 'user_settings/open'},
        {'快捷键帮助（统计）', 'stats/display-page-4-toggle'},
        {'mpv 在线文档', 'select/open-docs'},
    }
    for id, item in ipairs(expected) do
        local menu = open_menu()
        eq(#menu.tracks, #expected); eq(menu.tracks[id].id, id); eq(menu.tracks[id].title, item[1])
        eq(menu.submit(id), true); eq(opened, false); eq(#commands, id)
        eq(#commands[id], 2); eq(commands[id][1], 'script-binding'); eq(commands[id][2], item[2])
        eq(menu.submit(id), false); eq(#commands, id)
    end
end

local function visibility_uses_live_media_and_preserves_ids()
    open_menu()
    eq(ids(request.tracks), tools_only)
    put('track-list', {static})
    eq(ids(request.tracks), tools_only)
    put('track-list', {static, audio, subtitle})
    eq(ids(request.tracks), '1,9,'..tools_only)
    put('current-tracks/sub', {type='sub', id=1, codec='HDMV_PGS_SUBTITLE'})
    eq(title(3), nil)
    put('current-tracks/sub', {type='sub', id=1, codec='dvb_subtitle'})
    eq(title(3), nil)
    put('current-tracks/sub', subtitle)
    eq(ids(request.tracks), '1,3,9,'..tools_only)
    put('track-list', {static, audio}) -- Current-track notification may lag removal.
    eq(ids(request.tracks), '9,'..tools_only)
    put('track-list', all_tracks)
    eq(ids(request.tracks), '1,2,3,4,5,9,'..tools_only)
    put('playlist-count', 1); eq(title(6), nil)
    put('playlist-count', 2); eq(title(6), '播放列表（屏幕内）')
    put('chapter-list', {{time=0}}); eq(title(7), '章节')
    put('chapter-list', {}); eq(title(7), nil)
    put('edition-list', {{id=0}}); eq(title(8), nil)
    put('edition-list', {{id=0},{id=1}}); eq(title(8), '媒体版本')
    put('current-demuxer', 'disc'); eq(title(8), '标题（光盘）')
    put('filename', 'https://example.test/clip.mkv'); eq(title(14), '文件信息（统计）')
    put('filename', nil); eq(title(14), nil)
    put('current-tracks/sub', nil); eq(title(3), nil)
    eq(ids(request.tracks), '1,2,4,5,6,8,9,'..tools_only)
    eq(#commands, 0); eq(#requests, 1)
end

local function malformed_sources_cannot_add_rows_or_commands()
    properties = {['track-list']={false, {type={}}, {type='audio', id='1'}, {type='video', id=math.huge},
        {type='sub', id=-1}}, ['current-tracks/sub']={id=1,codec=false}, ['playlist-count']='9',
        ['chapter-list']={false, {time='0'}, {time=math.huge}, {time=-1}},
        ['edition-list']={true,'not a row'}, ['current-demuxer']={}, filename='bad\0name.mkv'}
    local menu = open_menu()
    eq(ids(menu.tracks), tools_only)
    for _, id in ipairs({'10', 'select/open-docs', {}, false, 0, -1, 1.5, 0/0, math.huge, 18}) do
        local ok, hint = menu.submit(id)
        eq(ok, false); assert(hint:find('不可用', 1, true))
    end
    eq(menu.submit(nil), false)
    eq(#commands, 0); eq(#messages, 0); eq(#updates, 0)
    for _, name in ipairs(observed) do put(name, false) end
    eq(ids(menu.tracks), tools_only); eq(#updates, 0)
end

local function refresh_is_in_place_and_rejects_stale_and_never_presented_rows()
    setup_all(); notify_on_open = observed
    local menu = open_menu()
    eq(#updates, 0)
    put('filename', 'new.mkv')
    eq(#updates, 0)
    local stale_playlist_id = menu.tracks[6].id
    put('playlist-count', 1, true)
    update_hook = function() notify('filename') end
    eq(menu.submit(stale_playlist_id), false)
    eq(#updates, 1); eq(#requests, 1); eq(request, menu); eq(opened, true)
    eq(menu.tracks[6].id, 7); eq(menu.current_id, 0); eq(#commands, 0)
    eq(menu.submit(stale_playlist_id), false); eq(#updates, 1)
    put('playlist-count', 2, true)
    eq(menu.submit(stale_playlist_id), false)
    eq(#updates, 2); eq(#commands, 0)
    eq(menu.submit(stale_playlist_id), true)
    eq(commands[1][2], 'select/select-playlist')
end

local function retirement_prevents_old_actions_and_can_open_child_inline()
    setup_all()
    local cancelled = open_menu()
    renderer.close()
    eq(cancelled.submit(17), false); cancelled.retry(); eq(#commands, 0)
    local first = open_menu()
    local second = open_menu()
    first.close(); eq(first.submit(10), false); eq(request, second); eq(opened, true)
    events['start-file'](); eq(second.submit(15), false); eq(opened, false)
    local third = open_menu()
    events['end-file'](); eq(third.submit(6), false); eq(opened, false)
    local current = open_menu()
    command_hook = function(command, binding)
        eq(command, 'script-binding'); eq(binding, 'track_selection/select-audio')
        bindings['select-audio']()
        return true
    end
    eq(current.submit(4), true)
    eq(request.kind, 'audio'); eq(opened, true); eq(#request.tracks, 2); eq(#commands, 1)
    local child = request
    local previous_updates = #updates
    current.close(); current.retry(); eq(current.submit(4), false)
    put('filename', nil); put('playlist-count', 0)
    eq(request, child); eq(opened, true); eq(#updates, previous_updates); eq(#commands, 1)
    events.shutdown(); eq(opened, false)
end

local function failure_stays_in_chinese_and_uses_the_same_retryable_panel()
    module_missing = true
    local menu = open_menu()
    eq(#menu.tracks, 0); eq(menu.state.can_retry, true); eq(menu.state.empty_title, '未能读取屏幕内主菜单')
    eq(#messages, 0)
    module_missing = false; setup_all()
    menu.retry(); eq(#requests, 1); eq(menu.state.can_retry, nil); eq(#menu.tracks, 17)
    read_failure = 'filename'
    eq(menu.submit(17), false)
    eq(#commands, 0); eq(menu.state.can_retry, true)
    read_failure = nil; menu.retry(); eq(#menu.tracks, 17)
    command_hook = function() error('private command failure') end
    eq(menu.submit(17), false)
    eq(#commands, 1); eq(opened, false); eq(messages[1], '未能执行该菜单项，请重试。')

    local second = open_menu()
    close_hook = function() close_hook = nil; events['start-file']() end
    eq(second.submit(15), false); eq(#commands, 1); eq(opened, false)
end
