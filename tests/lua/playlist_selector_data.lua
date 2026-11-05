-- Use the actual controller and data module with a synthetic mpv queue.
local bindings, events, observers, commands, messages = {}, {}, {}, {}, {}
local first = {id=0, filename='D:\\甲\\同名.mkv', title='片段甲', current=true}
local second = {id=7, filename='https://example.invalid/片段?tag=${volume}#start', title='片段乙', playing=true}
local third = {id=12, filename='D:\\乙\\同名.mkv', title='   '}
local properties = {platform='windows', playlist={first, second, third},
    ['osd-playlist-entry']='title', ['playlist-pos']=0}
local panel, opened, update_count, on_close, on_play, failure = nil, false, 0
local function eq(actual, expected)
    assert(actual == expected, 'expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
end
local renderer = {
    open=function(request) assert(not opened); panel, opened = request, true; return true end,
    close=function()
        if not opened then return end
        opened = false
        panel.close()
        if on_close then local mutate = on_close; on_close = nil; mutate() end
    end,
    is_open=function() return opened end,
    update=function(rows, current, notice, state)
        assert(opened)
        update_count = update_count + 1
        panel.tracks, panel.current_id, panel.notice, panel.state = rows, current, notice, state
    end,
}
package.loaded.mp = {
    get_property_native=function(name) return properties[name] end,
    add_key_binding=function(_, name, fn) bindings[name] = fn end,
    register_event=function(name, fn) events[name] = fn end,
    observe_property=function(name, kind, fn) eq(kind, 'native'); observers[name] = fn end,
    unobserve_property=function(fn)
        for name, observer in pairs(observers) do if observer == fn then observers[name] = nil end end
    end,
    command_native=function(args) eq(args[1], 'expand-path'); return args[2] end,
    commandv=function(...)
        assert(not opened, 'shared input must be released before playing')
        eq(observers.playlist, nil); eq(observers['osd-playlist-entry'], nil)
        local args = {...}; eq(#args, 2); eq(args[1], 'playlist-play-index')
        commands[#commands + 1] = args[2]
        if on_play then on_play() end
        if failure then return nil, 'native error with D:/private/filename' end
        return true
    end,
    set_property=function() error('selector attempted a property write') end,
    set_property_native=function() error('selector attempted a property write') end,
    osd_message=function(message) messages[#messages + 1] = message end,
}
local dofile = function(path)
    if path == '~~/script-modules/track-selector.lua' then return renderer end
    eq(path, '~~/script-modules/playlist-selector-data.lua')
    return playlist_model
end

-- COMPLETE CONTROLLER IS INSERTED HERE

local function open()
    bindings['select-playlist']()
    assert(opened)
    eq(panel.kind, 'playlist')
    eq(panel.clear, nil)
    return panel
end

function names_modes_and_current_are_derived_without_mutating_entries()
    local request = open()
    local a, b, c = unpack(request.tracks)
    eq(a.title, '片段甲'); eq(b.title, '片段乙'); eq(c.title, '同名.mkv')
    eq(a.time_text, '1'); eq(b.time_text, '2'); eq(c.time_text, '3')
    assert(a.id > 0); eq(request.current_id, b.id); eq(request.state.reveal_id, b.id)
    eq(a.history_path, first.filename); eq(b.history_path, second.filename)
    properties['osd-playlist-entry'] = 'filename'
    observers['osd-playlist-entry']()
    eq(panel.tracks[1].title, '同名.mkv'); eq(panel.tracks[2].title, second.filename)
    eq(panel.tracks[1].id, a.id); eq(panel.state.reveal_id, nil)
    properties['osd-playlist-entry'] = 'both'
    observers['osd-playlist-entry']()
    eq(panel.tracks[1].title, '片段甲 (同名.mkv)')
    eq(panel.tracks[2].title, '片段乙 (' .. second.filename .. ')')
    eq(panel.tracks[3].title, '同名.mkv')
    eq(first.title, '片段甲'); eq(first.id, 0); eq(first.history_path, nil); eq(third.title, '   ')
    local snapshot = playlist_model.new()
    eq(snapshot({first}, nil, 'windows').rows[1].title, '同名.mkv')
    local paths = {{id=1, filename='D:\\影片\\片段\\/'}, {id=2, filename='/mnt/视频/测试/'},
        {id=3, filename='file:///D:/完整/来源.mkv'}, {id=4, filename='\\'}, {id=5, filename='file\\one.mkv'}}
    local windows = snapshot(paths, 'filename', 'windows').rows
    eq(windows[1].title, '片段'); eq(windows[2].title, '测试')
    eq(windows[3].title, paths[3].filename); eq(windows[4].title, '\\')
    eq(snapshot(paths, 'filename', 'linux').rows[5].title, 'file\\one.mkv')
end

function observers_refresh_only_meaningful_changes_and_keep_identities()
    local request = open()
    local a, b, c = unpack(request.tracks)
    observers.playlist(); observers['osd-playlist-entry'](); eq(update_count, 0)
    properties.playlist = {third, first, second}
    observers.playlist(); eq(update_count, 1)
    eq(panel.tracks[1].id, c.id); eq(panel.tracks[2].id, a.id); eq(panel.tracks[3].id, b.id)
    eq(panel.tracks[3].time_text, '3'); eq(panel.current_id, b.id); eq(panel.state.reveal_id, nil)
    second.title = '变化后的标题'; observers.playlist(); eq(update_count, 2)
    eq(panel.tracks[3].title, second.title); eq(panel.tracks[3].id, b.id)
    second.playing, first.playing = nil, true
    observers.playlist(); eq(update_count, 3); eq(panel.current_id, a.id); eq(panel.state.reveal_id, nil)
    first.current, second.current = nil, true
    observers.playlist(); eq(update_count, 3)
end

function submitted_identity_uses_latest_index_and_replays_current()
    local request = open()
    local id = request.current_id
    properties.playlist = {second, third, first} -- no notification yet
    on_play = function() events['start-file']() end
    assert(request.submit(id))
    eq(commands[1], 0); eq(#commands, 1); eq(#messages, 0); eq(opened, false)
    assert(not request.submit(id)); eq(#commands, 1)
end

function removal_replacement_and_duplicate_ids_cannot_inherit_old_selections()
    local request = open()
    local removed, replaced = request.tracks[1].id, request.tracks[2].id
    properties.playlist = {third, {id=7, filename='D:/replacement.mkv'}}
    assert(not request.submit(removed)); assert(opened); eq(#commands, 0)
    local replacement = panel.tracks[2].id
    assert(replacement ~= replaced and replacement ~= removed)
    assert(not request.submit(replaced)); eq(#commands, 0)
    properties.playlist = {first, third, {id=7, filename='D:/replacement.mkv'}, {id=7},
        false, {id=-1, filename='D:/bad'}, {id='7', filename='D:/bad'}, {filename='D:/bad'},
        {id=0.5, filename='D:/bad'}, {id=3, filename='bad\0name'}}
    assert(not request.submit(replacement)); eq(#commands, 0)
    eq(#panel.tracks, 2); assert(panel.tracks[1].id ~= removed)
    assert(panel.notice:find('已跳过', 1, true))
    properties.playlist = {third, {id=7, filename='D:/replacement.mkv'}}
    observers.playlist()
    assert(panel.tracks[2].id ~= replacement)
    assert(not request.submit(replacement)); eq(#commands, 0)
end

function empty_unavailable_and_retry_have_distinct_states()
    properties.playlist = {}
    local request = open()
    eq(request.state.empty_title, '播放列表为空'); eq(request.state.can_retry, nil)
    eq(#request.tracks, 0); eq(request.current_id, 0)
    assert(not request.submit(1)); eq(#commands, 0)
    properties.playlist = {[2]=first}
    observers.playlist(); eq(request.state.can_retry, true); eq(#request.tracks, 0)
    properties.playlist = nil
    request.retry(); eq(request.state.can_retry, true)
    properties.playlist = {{filename='D:/unknown.mkv'}}
    request.retry(); eq(request.state.can_retry, true)
    properties.playlist = {first}
    request.retry(); eq(request.state.can_retry, nil); eq(#request.tracks, 1)
    eq(request.current_id, 0)
end

function removal_and_reorder_during_close_are_rechecked()
    local request = open()
    on_close = function() properties.playlist = {third, first, second} end
    assert(request.submit(request.tracks[1].id)); eq(commands[1], 1)
    request = open()
    local id = request.tracks[3].id
    on_close = function() properties.playlist = {third, first, {id=7, filename='D:/replacement.mkv'}} end
    assert(not request.submit(id)); eq(#commands, 1); eq(opened, false)
    assert(messages[1]:find('请重新打开', 1, true))
end

function stale_callbacks_do_not_cross_sessions_and_errors_hide_details()
    local request = open()
    local observe = observers.playlist
    local id = request.tracks[1].id
    events['end-file']()
    eq(opened, false); eq(observers.playlist, nil); eq(observers['osd-playlist-entry'], nil)
    local next_panel = open()
    observe(); request.retry(); request.close()
    eq(update_count, 0); eq(panel, next_panel); assert(opened)
    assert(not request.submit(id)); eq(#commands, 0)
    failure = true
    assert(not next_panel.submit(next_panel.tracks[1].id))
    eq(commands[1], 0); eq(#messages, 1); eq(messages[1], '未能播放该条目，请重试。')
    eq(opened, false)
end
