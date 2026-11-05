-- Adapt mpv's JSON-lines history without changing the loadfile argument.
local mp = require('mp')
local utils = require('mp.utils')
local M = {}
local default_format = '%Y-%m-%d %H:%M:%S'

function M.options()
    local opts = {history_date_format=default_format, hide_history_duplicates=true}
    require('mp.options').read_options(opts, 'select')
    return opts
end

local function display(value)
    return (value:gsub('[%z\1-\31\127]', ' '))
end

local function parts(path)
    local host, suffix = path:match('^[%w+.-]+://([^/?#]*)(.*)$')
    if host then
        host = host:match('[^@]*$') -- Do not use URL user info as a label.
        path = suffix:match('^[^?#]*'):gsub('/+$', '')
    else
        path = path:gsub('\\', '/'):gsub('/+$', '')
    end
    local directory, name = path:match('^(.*)/([^/]+)$')
    local parent = directory and (directory:match('[^/]+$') or '/') or ''
    if host and (parent == '' or parent == '/') then parent = host end
    return name or (path ~= '' and path) or host or '', parent
end

local function valid_format(format)
    if type(format) ~= 'string' or not format:match('%S') or format:find('%z') or
        format == '*t' or format == '!*t' then return false end
    -- An invalid conversion may invoke the Windows CRT's invalid-parameter
    -- handler before Lua can catch it. Validate directives before os.date.
    local start = 1
    while true do
        local at = format:find('%', start, true)
        if not at then return true end
        local code = format:sub(at+1, at+1)
        if code == '' or not ('aAbBcCdDeFgGhHIjmMnprRStTuUVwWxXyYzZ%'):find(code, 1, true) then return false end
        start = at+2
    end
end

local function format_date(format, timestamp)
    -- Windows time_t is supported through the end of year 3000.
    if type(timestamp) ~= 'number' or not (timestamp >= 0 and timestamp <= 32535215999) or
        timestamp ~= math.floor(timestamp) then return nil end
    local ok, date = pcall(os.date, format, timestamp)
    if ok and type(date) == 'string' and date:match('%S') then return display(date) end
end

local function has_json_nul(line)
    if line:find('%z') then return true end
    local start = 1
    while true do
        local at = line:find('\\u0000', start, true)
        if not at then return false end
        local before = at-1
        while before > 0 and line:byte(before) == 92 do before = before-1 end
        if (at-1-before)%2 == 0 then return true end
        start = at+6
    end
end

function M.parse(content, opts)
    local format = opts.history_date_format
    local format_fallback = not valid_format(format)
    if format_fallback then format = default_format end
    local entries, skipped = {}, 0
    -- The file is otherwise compared byte for byte. Only the display parser
    -- strips the optional UTF-8 BOM or accepts a final unterminated line.
    local lines = content:gsub('^\239\187\191', '')
    if lines ~= '' then
        if lines:sub(-1) ~= '\n' then lines = lines .. '\n' end
        for line in lines:gmatch('([^\n]*)\n') do
            -- mpv uses C strings in parse_json; a decoded NUL could otherwise
            -- turn a malformed path into a different, playable path.
            local entry = not has_json_nul(line) and utils.parse_json(line)
            local path, date = type(entry) == 'table' and entry.path, nil
            if type(path) == 'string' and path ~= '' and not path:find('%z') then
                date = format_date(format, entry.time)
                if not date and format ~= default_format then
                    date = format_date(default_format, entry.time)
                    if date then format_fallback = true end
                end
            end
            if date then
                local name, parent = parts(path)
                local title = type(entry.title) == 'string' and display(entry.title) or ''
                if not title:match('%S') or entry.title == path then title = display(name) end
                if not title:match('%S') then title = '未命名媒体' end
                entries[#entries+1] = {title=title, date_text=date, parent_text=display(parent), history_path=path}
            else
                skipped = skipped+1
            end
        end
    end

    local rows, seen, titles = {}, {}, {}
    for i = #entries, 1, -1 do
        local entry = entries[i]
        if opts.hide_history_duplicates == false or not seen[entry.history_path] then
            local earlier = titles[entry.title]
            if earlier == nil then titles[entry.title] = entry.history_path
            elseif earlier ~= entry.history_path then titles[entry.title] = false end
            rows[#rows+1] = entry
            seen[entry.history_path] = true
        end
    end
    for _, row in ipairs(rows) do
        if titles[row.title] ~= false then row.parent_text = '' end
    end
    local notices = {}
    if skipped > 0 then notices[#notices+1] = '已跳过 ' .. skipped .. ' 条无效记录。' end
    if format_fallback then notices[#notices+1] = '时间格式无效，已使用默认格式。' end
    return rows, table.concat(notices, ' ')
end

function M.source()
    local configured = mp.get_property('watch-history-path')
    if type(configured) ~= 'string' or configured == '' or configured:find('%z') then return nil end
    local path = mp.command_native({'expand-path', configured})
    if type(path) == 'string' and path ~= '' and not path:find('%z') then
        return {configured=configured, path=path}
    end
end

function M.same_source(a, b)
    return a ~= nil and b ~= nil and a.configured == b.configured and a.path == b.path
end

function M.matches(source, content)
    -- Only a bounded binary read on submit, with an extra byte to detect an
    -- appended record even if the original snapshot is still an exact prefix.
    local file = io.open(source.path, 'rb')
    if not file then return nil end
    local current, err = file:read(#content+1)
    file:close()
    if err then return nil end
    return current == content
end

function M.run(operation, source, hash, done)
    local helper = mp.command_native({'expand-path', '~~/helpers/history-store.ps1'})
    if not source or type(helper) ~= 'string' or helper == '' then done({ok=false}); return end
    local args = {'powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', helper, '-Operation', operation, '-Path', source.path}
    if hash then args[#args+1]='-ExpectedHash'; args[#args+1]=hash end
    local finished = false
    local function finish(success, result)
        if finished then return end
        finished = true
        local reply = success and type(result) == 'table' and result.status == 0 and
            type(result.stdout) == 'string' and utils.parse_json(result.stdout)
        if type(reply) ~= 'table' then reply = {ok=false} end
        if reply.ok == true and operation == 'Read' and reply.missing ~= true and
            (type(reply.content) ~= 'string' or type(reply.hash) ~= 'string' or #reply.hash ~= 64 or
                not reply.hash:match('^%x+$')) then reply = {ok=false} end
        done(reply)
    end
    local ok, command = pcall(mp.command_native_async,
        {name='subprocess', args=args, playback_only=false, capture_stdout=true, capture_stderr=true}, finish)
    if not ok or not command then finish(false) end
end

return M
