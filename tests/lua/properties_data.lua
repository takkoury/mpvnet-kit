local function eq(actual, expected)
    assert(actual == expected, 'expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
end

local ARRAY, MAP = {type='ARRAY'}, {type='MAP'}
local function array(items) return setmetatable(items, ARRAY) end
local function map(items) return setmetatable(items, MAP) end
local function native_string(value)
    if type(value) == 'string' then return '"' .. value .. '"' end
    if type(value) == 'table' then
        eq(next(value), nil)
        return '{}'
    end
    return tostring(value)
end

local hooks, events, readers = {}, {}, {}
local data, reads, writes, commands, messages, logs, calls = {}, {}, {}, {}, {}, {}, {}
local level, opened, request = 'all=warn', false, nil
local read_action, write_action, close_action, escape_action, open_failure
local mp = {
    ARRAY=ARRAY, MAP=MAP,
    get_property_native=function(name, fallback)
        reads[name] = (reads[name] or 0) + 1
        if read_action then
            local value = read_action(name)
            if value ~= nil then return value end
        end
        if name == 'msg-level' then
            local levels = map({})
            for key, value in level:gmatch('([^=,]+)=([^,]+)') do levels[key] = value end
            return levels
        end
        if data[name] ~= nil then return data[name] end
        return fallback, 'property unavailable'
    end,
    get_property=function(name) eq(name, 'msg-level'); return level end,
    set_property=function(name, value)
        eq(name, 'msg-level')
        writes[#writes+1] = value
        level = value
        if write_action then write_action(value) end
        return true
    end,
    command_native=function(args)
        if args[1] == 'expand-path' then return args[2] end
        eq(args[1], 'escape-ass')
        assert(not opened, 'detail escaped before input release')
        calls[#calls+1] = 'escape'
        if escape_action then return escape_action(args[2]) end
        return args[2]:gsub('{', '\\{')
    end,
    commandv=function(...)
        assert(not opened, 'detail shown before input release')
        calls[#calls+1] = 'show'
        commands[#commands+1] = {...}
        return true
    end,
    msg={info=function(text)
        assert(not opened, 'detail logged before input release')
        calls[#calls+1] = 'info'
        logs[#logs+1] = text
    end},
    add_key_binding=function(key, name, callback) eq(key, nil); hooks[name] = callback end,
    observe_property=function(name, _, callback) readers[name] = callback end,
    register_event=function(name, callback) events[name] = callback end,
    osd_message=function(message) messages[#messages+1] = message end,
}
package.loaded.mp = mp
package.loaded['mp.utils'] = {to_string=native_string}

local renderer = {
    open=function(options)
        assert(not opened, 'previous selector was not closed')
        if open_failure then return false, open_failure end
        opened, request = true, options
        calls[#calls+1] = 'open:' .. options.kind
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
    if path == '~~/script-modules/track-selector.lua' then return renderer end
    if path == '~~/script-modules/properties-data.lua' then return make_properties_data() end
    error('unexpected source read')
end

-- CONTROLLER IS INSERTED HERE

local Data = make_properties_data()
local private = 'https://test.invalid/synthetic?secret=sample'
local function items(rows)
    local by_name = {}
    for id, row in ipairs(rows) do
        eq(row.id, id)
        assert(not by_name[row.title], 'duplicated path')
        by_name[row.title] = row.property_value
        if id > 1 then assert(rows[id-1].title < row.title, 'unsorted properties') end
    end
    return by_name
end

function flattens_native_values_and_paths()
    data = {
        ['property-list']=array({'track-list', 'object', 'missing', 'current-tracks',
            'msg-level', 'current-tracks/audio', 'missing'}),
        ['track-list']=array({map({id=41, selected=false}), map({id=83, selected=true})}),
        object=map({[1]='numeric map key', ['2']='string map key', ['a/b']='slash', ['\194\146a0']='control key',
            ['a%2Fb']='percent', ['']='empty key', empty='', zero=0, empty_map=map({}),
            empty_array=array({}), nested=map({disabled=false})}),
        ['current-tracks']=map({audio=map({id=41, selected=false})}),
        ['current-tracks/audio']=map({id=999, selected=true}),
        ['current-tracks/video']=false,
        ['current-tracks/sub']=map({id=72}),
    }
    local rows, targets, code = Data.snapshot()
    eq(code, nil); eq(level, 'all=warn'); eq(table.concat(writes, ','), 'all=warn,cplayer=no,all=warn')
    local values = items(rows)
    eq(values['track-list/0/id'], '41'); eq(values['track-list/1/id'], '83')
    eq(values['track-list/0/selected'], 'false'); eq(values['track-list/1/selected'], 'true')
    eq(values['object/1'], '"numeric map key"'); eq(values['object/2'], '"string map key"')
    eq(values['object/a%2Fb'], '"slash"'); eq(values['object/a%252Fb'], '"percent"')
    eq(values['object/%C2%92a0'], '"control key"')
    eq(values['object/%'], '"empty key"'); eq(values['object/empty'], '""')
    eq(values['object/zero'], '0'); eq(values['object/empty_array'], '{}'); eq(values['object/empty_map'], '{}')
    eq(values['object/nested/disabled'], 'false'); eq(values.missing, 'nil')
    eq(values['msg-level/all'], '"warn"'); eq(values['msg-level/cplayer'], nil)
    eq(values['current-tracks/audio/id'], '41'); eq(values['current-tracks/audio/selected'], 'false')
    eq(values['current-tracks/video'], 'false'); eq(values['current-tracks/sub/id'], '72')
    eq(values['current-tracks/sub2'], 'nil')
    eq(reads['object/nested/disabled'], nil); eq(reads['current-tracks/audio'], nil)
    eq(reads.missing, 1); eq(reads['property-list'], 1)
    eq(targets[1].title, rows[1].title); eq(targets[1].value, rows[1].property_value)
    rows[1].property_value = 'renderer mutation'; assert(targets[1].value ~= rows[1].property_value)
    eq(#messages, 0); eq(#commands, 0); eq(#logs, 0)
end

function option_roots_preserve_the_original_log_level()
    level = 'all=warn,cplayer=debug'
    data = {['property-list']=array({'options', 'file-local-options', 'sample'})}
    read_action = function(name)
        if name == 'options' or name == 'file-local-options' then
            return map({['msg-level']=map({cplayer=level:match('cplayer=([a-z]+)')}), pause=false})
        end
        if name == 'sample' then eq(level, 'all=warn,cplayer=no'); return true end
    end
    local values = items(Data.snapshot())
    eq(values['options/msg-level/cplayer'], '"debug"')
    eq(values['file-local-options/msg-level/cplayer'], '"debug"')
    eq(values['options/pause'], 'false'); eq(values.sample, 'true')
    eq(reads.options, 1); eq(reads['file-local-options'], 1)
    eq(level, 'all=warn,cplayer=debug')
end

function failures_restore_the_borrowed_level()
    level, data = '', {['property-list']=array({'boom'}), boom=true}
    read_action = function(name)
        if name == 'boom' then eq(level, 'cplayer=no'); error(private) end
    end
    local rows, _, code = Data.snapshot()
    eq(rows, nil); eq(code, 'read'); eq(level, ''); eq(#writes, 2)

    read_action = function(name) if name == 'boom' then level = 'all=trace'; error(private) end end
    rows, _, code = Data.snapshot()
    eq(rows, nil); eq(code, 'read'); eq(level, 'all=trace'); eq(#writes, 3)

    read_action = nil
    write_action = function(value) if value:find('cplayer=no', 1, true) then error(private) end end
    rows, _, code = Data.snapshot()
    eq(rows, nil); eq(code, 'read'); eq(level, 'all=trace'); eq(#writes, 5)

    write_action = function(value) if value == 'all=trace' then error(private) end end
    rows, _, code = Data.snapshot()
    eq(rows, nil); eq(code, 'restore'); eq(#writes, 7)

    write_action, level = nil, 'cplayer=debug,all=warn,vo/gpu=error'
    read_action = function(name)
        if name == 'boom' then eq(level, 'all=warn,vo/gpu=error,cplayer=no') end
    end
    rows, _, code = Data.snapshot()
    assert(rows); eq(code, nil); eq(level, 'cplayer=debug,all=warn,vo/gpu=error'); eq(#writes, 9)

    level = 'all=warn,vo/gpu=error,cplayer=no'
    rows, _, code = Data.snapshot()
    assert(rows); eq(code, nil); eq(level, 'all=warn,vo/gpu=error,cplayer=no'); eq(#writes, 9)

    level, read_action = 'custom,prefix=error', nil
    rows, _, code = Data.snapshot()
    eq(rows, nil); eq(code, 'read'); eq(#writes, 9)
    eq(#logs, 0); eq(#messages, 0)
end

function refuses_cyclic_and_oversized_data()
    local function refuses(value, expected)
        data = {['property-list']=array({'sample'}), sample=value}
        local rows, targets, code = Data.snapshot()
        eq(rows, nil); eq(targets, nil); eq(code, expected); eq(level, 'all=warn')
    end
    local cyclic = {}; cyclic.self = cyclic
    refuses(cyclic, 'cycle')
    local deep = 'end'
    for _=1,33 do deep = {branch=deep} end
    refuses(deep, 'limit')
    local wide = {}
    for i=1,20000 do wide[i] = true end
    refuses(array(wide), 'limit')
    refuses(string.rep('x', 65537), 'limit')
    local total = {}
    for i=1,150 do total[i] = string.rep('x', 60000) end
    refuses(array(total), 'limit')

    -- The same table used under two names is not a cycle.
    local common = map({value=7})
    data = {['property-list']=array({'shared'}), shared=map({one=common, two=common})}
    local values = items(Data.snapshot())
    eq(values['shared/one/value'], '7'); eq(values['shared/two/value'], '7')
end

function selects_the_original_value_as_literal_detail()
    local text = string.rep('x', 105) .. [[${path}{\bord80}; quit]] .. '\194\146a0\0\27'
    data = {['property-list']=array({'a'}), a=text, ['vo-configured']=true}
    hooks['show-properties']()
    eq(request.kind, 'properties'); eq(request.current_id, 0); eq(#commands, 0); eq(#logs, 0)
    local display = string.rep('x', 105) .. [[${path}{\bord80}; quit\x92a0\x00\x1B]]
    eq(request.tracks[1].title, 'a'); eq(request.tracks[1].property_value, '"' .. display .. '"')
    local panel = request
    data.a = 'new value'
    request.tracks[1].property_value = 'renderer mutation'
    readers['track-list']('track-list')
    eq(reads.a, 1)
    eq(panel.submit(0), false); eq(opened, true)
    calls = {}
    eq(panel.submit(1), true); eq(table.concat(calls, ','), 'close,escape,show')
    eq(reads.a, 1); eq(#logs, 0); eq(#commands, 1)
    local command = commands[1]
    eq(command[1], 'expand-properties'); eq(command[2], 'show-text'); eq(command[4], 20000)
    local safe = string.rep('x', 105) .. [[$\{path}\{\bord80}; quit\x92a0\x00\x1B]]
    eq(command[3], '${osd-ass-cc/0}{\\fs9}$>a: "' .. safe .. '"')
    eq(panel.submit(1), false); eq(#commands, 1)

    data.a = 0
    hooks['show-properties'](); eq(request.submit(1), true)
    eq(commands[2][3], '${osd-ass-cc/0}$>a: 0')
end

function logs_only_a_chosen_detail_without_video_output()
    data = {['property-list']=array({'a', 'b'}), a=false, b=private, ['vo-configured']=false}
    hooks['show-properties'](); eq(#logs, 0); eq(#commands, 0)
    local panel = request
    calls = {}
    eq(panel.submit(1), true); eq(table.concat(calls, ','), 'close,info')
    eq(#logs, 1); eq(logs[1], 'a: false'); eq(#commands, 0)
    eq(panel.submit(2), false); eq(#logs, 1)
end

function invalidates_callbacks_on_retry_media_change_and_reentry()
    data = {['property-list']=false, a=private}
    hooks['show-properties'](); eq(#request.tracks, 0); eq(request.state.can_retry, true)
    local failed = request
    data['property-list'] = array({'a'})
    failed.retry(); eq(request.tracks[1].property_value, '"' .. private .. '"')
    local current = request
    failed.retry(); eq(request, current); eq(failed.submit(1), false)
    events['start-file'](); eq(opened, false); eq(current.submit(1), false)

    hooks['show-properties']()
    current = request
    close_action = function() hooks['select-audio']() end
    eq(current.submit(1), false); eq(request.kind, 'audio'); eq(opened, true)
    current.close(); eq(opened, true); eq(#logs, 0); eq(#commands, 0)

    hooks['show-properties']()
    current = request
    read_action = function(name) if name == 'vo-configured' then events['end-file']() end end
    eq(current.submit(1), false); eq(opened, false); eq(#logs, 0); eq(#commands, 0)

    read_action = function(name) if name == 'a' then events['end-file']() end end
    hooks['show-properties'](); eq(opened, false); eq(level, 'all=warn')
end

function failure_feedback_omits_native_diagnostics()
    data = {['property-list']=array({'a'}), a=private, ['vo-configured']=true}
    read_action = function(name) if name == 'a' then error(private) end end
    hooks['show-properties']()
    eq(request.state.empty_title, '未能读取播放器属性'); eq(request.state.can_retry, true)
    assert(not request.state.empty_hint:find(private, 1, true))
    eq(level, 'all=warn'); eq(#logs, 0)

    read_action = nil
    request.retry()
    escape_action = function() error(private) end
    eq(request.submit(1), false); eq(#messages, 1); eq(messages[1], '未能显示该属性，请重试。')
    eq(#logs, 0); eq(#commands, 0)

    open_failure = private
    hooks['show-properties'](); eq(messages[2], '无法打开播放器属性选择器，请重试。')
end
