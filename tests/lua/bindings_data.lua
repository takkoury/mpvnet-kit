local function eq(actual, expected)
    assert(actual == expected, 'expected '..tostring(expected)..', got '..tostring(actual))
end
local function entry(key, cmd, priority, weak)
    return {key=key, cmd=cmd, priority=priority or 0, is_weak=weak == true}
end

local hooks, events, commands, messages, calls, loads = {}, {}, {}, {}, {}, {}
local source, opened, request = {}, false, nil
local read_action, close_action, command_action, missing_labels
local mp = {
    get_property_native=function(name, fallback)
        if name == 'input-bindings' then
            calls[#calls+1] = 'read'
            if read_action then read_action() end
            -- A real exclusive section has higher priority until close restores it.
            if opened then return {entry('A', 'script-binding track_selection/track-selector-1', 99)} end
            return source
        end
        return fallback
    end,
    command_native=function(args)
        eq(args[1], 'expand-path')
        return args[2]
    end,
    command=function(command)
        assert(not opened, 'command executed before input release')
        calls[#calls+1] = 'execute'
        commands[#commands+1] = command
        if command_action then return command_action() end
        return true
    end,
    add_key_binding=function(key, name, callback) eq(key, nil); hooks[name] = callback end,
    observe_property=function(name) assert(name ~= 'input-bindings', 'exclusive bindings must not trigger refresh') end,
    register_event=function(name, callback) events[name] = callback end,
    osd_message=function(message) messages[#messages+1] = message end,
}
package.loaded.mp = mp

local renderer = {
    open=function(options)
        assert(not opened, 'previous panel is still active')
        opened, request = true, options
        calls[#calls+1] = 'open:'..options.kind
        return true
    end,
    close=function()
        if not opened then return end
        opened = false
        calls[#calls+1] = 'close'
        request.close()
        if close_action then
            local callback = close_action
            close_action = nil
            callback()
        end
    end,
    is_open=function() return opened end,
    update=function() error('unexpected refresh') end,
}
local function dofile(path)
    loads[#loads+1] = path
    if path == '~~/script-modules/track-selector.lua' then return renderer end
    if path == '~~/script-modules/bindings-data.lua' then return make_bindings_data() end
    if path == '~~/script-modules/user-shortcuts.lua' then
        if missing_labels then error('missing static action labels') end
        return make_shortcut_model()
    end
    error('unexpected source read')
end

-- CONTROLLER IS INSERTED HERE

local Data = make_bindings_data()
local custom = [[no-osd set volume 61 ; script-message-to sample send "合成; 自定义" 'https://test.invalid/?secret=sample']]

function effective_commands_and_labels()
    local list = {
        entry('B', 'set volume 10', 20, true),
        entry('A', 'ignore', 1, true),
        entry('C', 'cycle mute', 1),
        entry('D', 'set volume 21', 1, true),
        entry('E', 'set volume 50', -1),
        entry('B', 'set volume 11', 2),
        entry('B', custom, 3),
        entry('B', 'set volume 12', 3), -- Equal rank keeps native list order.
        entry('A', 'ignore', 2),
        entry('A', 'set volume 30', 40, true),
        entry('D', 'set volume 22', 2, true),
        entry('Ctrl+F1', 'script-binding sample/custom', 0),
    }
    local effective = Data.effective(list)
    local rows, targets = Data.rows(effective, make_shortcut_model().catalog('').by_command)
    eq(effective.A, nil); eq(effective.E, nil); eq(#rows, 4)
    eq(rows[1].time_text, 'B'); eq(rows[1].title, custom); eq(rows[1].action_command, custom)
    eq(rows[2].time_text, 'C'); eq(rows[2].title, '静音／取消静音'); eq(rows[2].action_command, 'cycle mute')
    eq(rows[3].time_text, 'Ctrl+F1'); eq(rows[3].title, 'script-binding sample/custom')
    eq(rows[4].action_command, 'set volume 22')
    rows[1].action_command = 'set volume 100'
    eq(targets[1].key, 'B'); eq(targets[1].cmd, custom); eq(list[7].cmd, custom)
end

function invalid_entries_do_not_become_rows()
    eq(Data.effective(false), nil)
    local rows = Data.rows(Data.effective({
        false, 'invalid', {}, entry({}, 'cycle mute'), entry('', 'cycle mute'),
        entry(' ', 'cycle mute'), entry('A\0B', 'cycle mute'), entry('C', false),
        entry('D', '  '), entry('D', 'cycle mute', 10, true),
        entry('E', 'cmd\0truncated'), entry('F', 'cmd', '1'),
        entry('G', 'cmd', math.huge), entry('H', 'cmd', 0/0),
        {key='I', cmd='cmd', priority=1}, {key='J', cmd='cmd', priority=1, is_weak='false'},
        entry('K', 'ignore'), entry('L', 'script-binding test/synthetic'),
    }))
    eq(#rows, 1); eq(rows[1].time_text, 'L')
end

function snapshot_and_replay_take_place_after_input_restoration()
    eq(#loads, 0)
    hooks['select-audio']()
    source = {entry('Z', 'set volume 50'), entry('A', custom)}
    calls = {}
    hooks['select-binding']()
    eq(table.concat(calls, ','), 'close,read,open:bindings')
    eq(request.current_id, 0); eq(#request.tracks, 2)
    eq(request.tracks[1].time_text, 'A'); eq(request.tracks[1].action_command, custom)
    -- Unrelated entries and native order can change; the same raw pair still works.
    source = {entry('A', custom, 3), entry('Z', 'set volume 52'), entry('0', 'set volume 55')}
    request.tracks[1].action_command = 'set volume 100'
    calls = {}
    eq(request.submit(1), true)
    eq(table.concat(calls, ','), 'close,read,execute')
    eq(#commands, 1); eq(commands[1], custom); eq(#messages, 0)
    eq(request.submit(1), false); eq(#commands, 1)
end

function reassigned_removed_and_ignored_keys_do_not_execute()
    for _, latest in ipairs({{entry('A', 'set volume 52')}, {}, {entry('A', 'ignore', 9)},
        {entry('A', '  ', 1), entry('A', 'set volume 50')}}) do
        source = {entry('A', 'set volume 50')}
        hooks['select-binding']()
        source = latest
        eq(request.submit(1), false); eq(opened, false)
        eq(messages[#messages], '该快捷键已变化，请重新打开选择器。')
    end
    eq(#commands, 0); eq(#messages, 4)
end

function execute_can_open_a_new_selector()
    source = {entry('A', 'script-binding sample/open-audio')}
    hooks['select-binding']()
    local previous = request
    command_action = function() hooks['select-audio'](); return true end
    eq(previous.submit(1), true); eq(request.kind, 'audio'); eq(opened, true)
    previous.close()
    eq(request.kind, 'audio'); eq(opened, true)
    eq(previous.submit(1), false); eq(#commands, 1)

    -- If a multi-command action opens a panel before returning a failure,
    -- the failure must not cover that new panel with an old selector message.
    hooks['select-binding']()
    command_action = function() hooks['select-audio'](); return nil, custom end
    eq(request.submit(1), false); eq(request.kind, 'audio'); eq(opened, true); eq(#messages, 0)
end

function replacement_and_media_events_retire_old_callbacks()
    source = {entry('A', custom)}
    hooks['select-binding']()
    local previous = request
    hooks['select-binding']()
    previous.close(); eq(request.submit(100), false); eq(opened, true)
    eq(previous.submit(1), false); eq(opened, true)
    previous = request
    events['start-file']()
    hooks['select-binding']()
    eq(previous.submit(1), false); eq(opened, true)

    close_action = function() hooks['select-audio']() end
    eq(request.submit(1), false); eq(request.kind, 'audio'); eq(opened, true)

    hooks['select-binding']()
    read_action = events['end-file']
    eq(request.submit(1), false); eq(opened, false); eq(#commands, 0); eq(#messages, 0)
end

function retry_and_failure_messages_do_not_echo_commands()
    source = false
    hooks['select-binding']()
    local previous = request
    eq(request.state.empty_title, '未能读取快捷键'); eq(request.state.can_retry, true)
    source = {entry('A', 'cycle mute')}
    missing_labels = true
    previous.retry()
    eq(request.tracks[1].title, 'cycle mute'); eq(request.tracks[1].action_command, 'cycle mute')
    local current = request
    previous.retry(); eq(request, current)

    command_action = function() return nil, custom end
    eq(request.submit(1), false); eq(messages[1], '未能执行该快捷键，请重试。')
    hooks['select-binding']()
    command_action = function() error(custom) end
    eq(request.submit(1), false); eq(messages[2], messages[1])
    hooks['select-binding']()
    read_action = function() error(custom) end
    eq(request.submit(1), false); eq(messages[3], '未能核对快捷键，请重新打开选择器。')
    eq(#commands, 2)

    read_action, source = nil, {entry('A', 'ignore')}
    hooks['select-binding']()
    eq(request.state.empty_title, '没有可执行的快捷键'); eq(#request.tracks, 0)
end
