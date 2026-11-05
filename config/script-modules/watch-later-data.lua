-- Read mpv watch-later records without interpreting saved playback options.
local mp = require('mp')
local utils = require('mp.utils')
local M = {}
local max_files, max_file_bytes, max_bytes = 2048, 64 * 1024, 2 * 1024 * 1024

local function valid_path(path)
    return type(path) == 'string' and path:match('%S') and not path:find('[%z\1-\31\127]')
end

local function append_leaf(directory, name)
    if directory:match('[\\/]$') then return directory .. name end
    return directory .. '/' .. name
end

function M.source()
    local path = mp.get_property('current-watch-later-dir')
    if not valid_path(path) then return nil end
    if path:match('^%a:[\\/]') or path:match('^[\\/][\\/]') then return path end
    local cwd = mp.get_property('working-directory')
    if not valid_path(cwd) then return nil end
    local drive = cwd:match('^(%a:)')
    if path:match('^[\\/]') then return drive and drive .. path or nil end
    local relative_drive, relative_path = path:match('^(%a:)(.*)$')
    if relative_drive then
        if not drive or drive:lower() ~= relative_drive:lower() then return nil end
        path = relative_path
    end
    return path == '' and cwd or append_leaf(cwd, path)
end

local function valid_leaf(name)
    if not valid_path(name) or name:find('[\\/:*?"<>|]') or name:match('[. ]$') then return false end
    local base = name:match('^[^.]*'):upper():gsub(' +$', '')
    return base ~= 'CON' and base ~= 'PRN' and base ~= 'AUX' and base ~= 'NUL' and
        not base:match('^COM[1-9]$') and not base:match('^LPT[1-9]$')
end

local function display_parts(path)
    local host, suffix = path:match('^[%w+.-]+://([^/?#]*)(.*)$')
    if host then
        host = host:match('[^@]*$') -- Omit URL user info from display labels.
        path = suffix:match('^[^?#]*'):gsub('/+$', '')
    else
        path = path:gsub('\\', '/'):gsub('/+$', '')
    end
    local directory, name = path:match('^(.*)/([^/]+)$')
    local parent = directory and (directory:match('[^/]+$') or '/') or ''
    if host and (parent == '' or parent == '/') then parent = host end
    local title = name or (path ~= '' and path) or host
    return title and title:match('%S') and title or '未命名媒体', parent
end

local function date_text(mtime)
    -- Lua on Windows accepts nonnegative time_t values through year 3000.
    if type(mtime) ~= 'number' or not (mtime >= 0 and mtime <= 32535215999) then return nil end
    local ok, date = pcall(os.date, '%Y-%m-%d', math.floor(mtime))
    if ok and type(date) == 'string' and date ~= '' then return '保存于 ' .. date end
end

local function count(value)
    return type(value) == 'number' and value >= 0 and value <= max_files and value == math.floor(value)
        and value or 0
end

function M.parse(reply)
    local skipped = reply.skipped
    local io_errors, encoding, oversized = count(skipped.io), count(skipped.encoding), count(skipped.too_large)
    local records, seen, titles, no_path, bytes = {}, {}, {}, 0, 0
    for _, item in ipairs(reply.files) do
        if type(item) ~= 'table' or not valid_leaf(item.name) or seen[item.name] or
            type(item.content) ~= 'string' then
            io_errors = io_errors + 1
        elseif #item.content > max_file_bytes or bytes + #item.content > max_bytes then
            oversized = oversized + 1
        elseif item.content:find('%z') then
            encoding = encoding + 1
        else
            seen[item.name] = true
            bytes = bytes + #item.content
            -- The helper has validated UTF-8. Only parsing strips the optional
            -- BOM and the CR of a CRLF line. Comparisons retain all bytes.
            local first = item.content:match('^[^\n]*'):gsub('^\239\187\191', ''):gsub('\r$', '')
            if first ~= '# redirect entry' then
                local path = first:match('^# (.+)$')
                local date = date_text(item.mtime)
                if not valid_path(path) then
                    no_path = no_path + 1
                elseif not date then
                    io_errors = io_errors + 1
                else
                    local title, parent = display_parts(path)
                    local row = {title=title, parent_text=parent, date_text=date, history_path=path}
                    records[#records+1] = {name=item.name, content=item.content, mtime=item.mtime, row=row}
                    if titles[title] == nil then titles[title] = path
                    elseif titles[title] ~= path then titles[title] = false end
                end
            end
        end
    end
    table.sort(records, function(a, b)
        if a.mtime ~= b.mtime then return a.mtime > b.mtime end
        return a.name < b.name
    end)
    for _, record in ipairs(records) do
        if titles[record.row.title] ~= false then record.row.parent_text = '' end
    end
    local notices = {}
    if io_errors > 0 then notices[#notices+1] = '有 ' .. io_errors .. ' 条保存记录无法读取。' end
    if encoding > 0 then notices[#notices+1] = '有 ' .. encoding .. ' 条记录含无效 UTF-8 或空字节。' end
    if oversized > 0 then
        notices[#notices+1] = '有 ' .. oversized .. ' 条记录超出读取限制（单条 64 KiB，总计 2 MiB）。'
    end
    if no_path > 0 and #records > 0 then notices[#notices+1] = '已跳过 ' .. no_path .. ' 条缺少媒体路径的记录。' end
    return records, {notice=table.concat(notices, ' '), no_path=no_path > 0,
        unreadable=io_errors + encoding + oversized > 0}
end

function M.matches(source, record)
    if not source or not valid_leaf(record.name) then return false end
    local file = io.open(append_leaf(source, record.name), 'rb')
    if not file then return false end
    local current, err = file:read(#record.content + 1)
    file:close()
    return not err and current == record.content
end

function M.run(source, done)
    local helper = mp.command_native({'expand-path', '~~/helpers/watch-later-store.ps1'})
    if not valid_path(helper) then done({ok=false}); return end
    local args = {'powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', helper, '-Path', source}
    local finished = false
    local function finish(success, result)
        if finished then return end
        finished = true
        local reply = success and type(result) == 'table' and result.status == 0 and
            type(result.stdout) == 'string' and utils.parse_json(result.stdout)
        if type(reply) ~= 'table' or (reply.ok == true and reply.missing ~= true and
            (type(reply.files) ~= 'table' or #reply.files > max_files or type(reply.skipped) ~= 'table')) then
            reply = {ok=false}
        end
        done(reply)
    end
    local ok, command = pcall(mp.command_native_async,
        {name='subprocess', args=args, playback_only=false, capture_stdout=true, capture_stderr=true}, finish)
    if not ok or not command then finish(false) end
end

return M
