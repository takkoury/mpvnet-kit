-- User overrides are separate from managed input.conf and apply in mpv's default
-- section. JSON never supplies commands, only stable catalog IDs and key names.
local mp = require('mp')
local utils = require('mp.utils')
local model = dofile(mp.command_native({'expand-path', '~~/script-modules/user-shortcuts.lua'}))
local paths = dofile(mp.command_native({'expand-path', '~~/script-modules/mpvnet-paths.lua'}))
local settings_path = mp.command_native({'expand-path', '~~/mpvnet-user.json'})
local helper_path = mp.command_native({'expand-path', '~~/helpers/shortcuts-window.ps1'})
local input_path = mp.command_native({'expand-path', '~~/input.conf'})
local powershell = paths.powershell()
local token = string.format('%.0f-%.0f', mp.get_property_number('pid', 0), mp.get_time() * 1000000)
local sequence, revision_number, save_serial = 0, 0, 0
local revision, observed_raw, observed_exists, observed_error = '', nil, nil, nil
local document, effective, catalog
local repairable, editable_actions = false, nil
local error_text, save_error = '', ''
local saving, editor_running, editor_visible, closing = false, false, false, false
local refresh_id = ''
local owned = {}

local function encode(value) return utils.format_json(value) end
local function decode(value) return utils.parse_json(value) end
local function read(path)
    local file, _, errno = io.open(path, 'rb')
    if not file then
        if errno == 2 and not utils.file_info(path) then return '', false end
        return nil, nil, '无法读取用户配置；请检查文件权限'
    end
    local raw = file:read(model.max_bytes + 1)
    local closed = file:close()
    if not raw or not closed then return nil, nil, '读取用户配置失败' end
    if #raw > model.max_bytes then return nil, nil, '配置文件超过 256 KiB 限制' end
    return raw, true
end

local function publish()
    local state = effective or {actions={}, forward_keys={}, opening_keys={}}
    mp.set_property_native('user-data/mpvnet/shortcuts', {
        schema=1, revision=revision, actions=state.actions, forward_keys=state.forward_keys,
        opening_keys=state.opening_keys, error=error_text, save_error=save_error, saving=saving,
        save_serial=save_serial, editor_token=token, editor_visible=editor_visible, refresh_id=refresh_id,
        repairable=repairable, editable_actions=editable_actions or state.actions,
    })
end

local function apply(mapping)
    local previous = effective
    local plan = model.plan(catalog, previous, mapping)
    -- A held key must finish its old action before its command changes. Release
    -- only changed keys, so edits to unrelated fields cannot stop seeking.
    for _, item in ipairs(plan) do
        local old = previous and previous.by_key[item.key]
        if (old and old.command or 'ignore') ~= item.command then mp.commandv('no-osd', 'keyup', item.key) end
    end
    for _, item in ipairs(plan) do
        if not mp.commandv('keybind', item.key, item.command) then
            -- Command failures are rare, but must not leave a partly changed map.
            if previous then
                for _, old in ipairs(model.plan(catalog, mapping, previous)) do mp.commandv('keybind', old.key, old.command) end
            end
            return nil, '播放器拒绝了快捷键映射；已尝试恢复原绑定'
        end
    end
    effective = mapping
    return true
end

local function reload(force)
    if closing or not catalog then return end
    local raw, exists, read_error = read(settings_path)
    if not force and raw == observed_raw and exists == observed_exists and read_error == observed_error then return end
    observed_raw, observed_exists, observed_error = raw, exists, read_error
    revision_number = revision_number + 1; revision = token .. ':' .. tostring(revision_number)
    repairable, editable_actions = false, nil
    if read_error then error_text = read_error; document = nil; publish(); return end
    local parsed, err
    if exists and raw == '' then err = '用户配置文件为空；未修改文件'
    else parsed, err = model.document(raw, decode) end
    if parsed then
        local mapping, detail; mapping, err, detail = model.resolve(catalog, parsed)
        if mapping then
            local ok; ok, err = apply(mapping)
            if ok then document = parsed; error_text = ''; publish(); return end
        elseif detail and detail.kind == 'mapping-conflict' then
            -- Upgrades can introduce a new default on a user's valid custom
            -- key. Keep the complete draft and CAS bytes editable, while actual
            -- playback retains the last valid map (startup uses defaults).
            document, repairable, editable_actions = parsed, true, detail.actions
            error_text = err; publish(); return
        end
    end
    document = nil; error_text = err or '用户配置无效；继续使用上一组有效绑定'; publish()
end

local function remove_owned(path)
    if path and owned[path] then os.remove(path); owned[path] = nil end
end

local function request_file(kind, contents)
    local temp = os.getenv('TEMP') or os.getenv('TMP')
    if not temp or temp == '' then return nil, '找不到系统临时目录' end
    sequence = sequence + 1
    local path = utils.join_path(temp, 'mpvnet-shortcuts-' .. token .. '-' .. tostring(sequence) .. '-' .. kind .. '.json')
    local file = io.open(path, 'wb')
    if not file then return nil, '无法创建快捷键请求文件' end
    owned[path] = true
    local written, closed = file:write(contents), file:close()
    if not written or not closed then remove_owned(path); return nil, '无法写入快捷键请求文件' end
    return path
end

local function launch(operation, path, callback)
    mp.command_native_async({name='subprocess', args={
        powershell, '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', helper_path,
        '-Operation', operation, '-RequestPath', path,
    }, capture_stdout=true, capture_stderr=false, playback_only=false}, function(ok, result)
        remove_owned(path)
        if not closing then callback(ok, result) end
    end)
end

local function finish_save(message)
    saving = false; save_error = message or ''; save_serial = save_serial + 1; publish()
end

local function save(received_token, expected_revision, proposed, reset)
    if received_token ~= token or closing then return end
    if saving then
        save_error = '上一项保存仍在进行，请稍后重试'; save_serial = save_serial + 1; publish(); return
    end
    -- Refresh before comparing: another player or external editor may have saved.
    reload(false)
    if expected_revision ~= revision then finish_save('配置已被其他窗口修改；请重新载入后保存'); return end
    if not document or (error_text ~= '' and not repairable) then finish_save(error_text ~= '' and error_text or '用户配置当前不可写'); return end
    local next_raw, err = model.prepare(catalog, document, proposed or '', decode, encode, reset)
    if not next_raw then finish_save(err); return end
    local request = '{"schema":1,"settings_path":' .. encode(settings_path)
        .. ',"expected_exists":' .. (observed_exists and 'true' or 'false')
        .. ',"expected_text":' .. encode(observed_raw or '') .. ',"document_text":' .. encode(next_raw:gsub('^\239\187\191', '')) .. '}'
    local path; path, err = request_file('save', request)
    if not path then finish_save(err); return end
    saving = true; save_error = ''; publish()
    launch('Save', path, function(ok, result)
        local response = result and utils.parse_json(result.stdout or '')
        if not ok or not result or result.status ~= 0 or type(response) ~= 'table' or response.ok ~= true then
            local message = response and response.conflict == true and '配置已被其他窗口修改；请重新载入后保存'
                or '保存失败；原配置与当前绑定保持不变'
            finish_save(message)
            return
        end
        reload(true)
        finish_save(error_text ~= '' and '文件已保存，但重新载入失败：' .. error_text or '')
    end)
end

local function open()
    if closing then return end
    if editor_running then
        editor_visible = true; publish()
        mp.commandv('script-message', 'mpvnet-shortcuts-show', token)
        return
    end
    local pipe = mp.get_property('options/input-ipc-server', '')
    if pipe == '' then
        pipe = '\\\\.\\pipe\\mpvnet-shortcuts-' .. token
        if not mp.set_property('options/input-ipc-server', pipe) then
            save_error = '无法建立当前播放器的 IPC 通道'; publish(); return
        end
    end
    local path, err = request_file('editor', encode({schema=1, pipe=pipe,
        parent_pid=mp.get_property_number('pid', 0), script=mp.get_script_name(), token=token, settings_path=settings_path}))
    if not path then save_error = err; publish(); return end
    editor_running, editor_visible = true, true; publish()
    launch('Editor', path, function(ok, result)
        editor_running, editor_visible = false, false
        if not ok or not result or result.status ~= 0 then save_error = '无法打开快捷键窗口' end
        publish()
    end)
end

mp.add_key_binding(nil, 'open', open)
mp.register_script_message('editor-ready', function(received_token)
    if received_token == token and not closing then editor_visible = true; publish() end
end)
mp.register_script_message('editor-refresh', function(received_token, id)
    if received_token ~= token or closing or saving or type(id) ~= 'string' or #id < 1 or #id > 64
        or not id:match('^[A-Za-z0-9%-]+$') then return end
    refresh_id = id; reload(false); publish()
end)
mp.register_script_message('editor-close', function(received_token)
    if received_token == token then editor_visible = false; publish() end
end)
mp.register_script_message('save', function(received_token, expected_revision, proposed)
    save(received_token, expected_revision, proposed, false)
end)
mp.register_script_message('reset', function(received_token, expected_revision)
    save(received_token, expected_revision, '', true)
end)
mp.register_event('shutdown', function()
    closing, editor_visible = true, false
    mp.commandv('script-message', 'mpvnet-shortcuts-close', token)
    for path in pairs(owned) do remove_owned(path) end
end)

local input, exists = read(input_path)
if input and exists then
    catalog = model.catalog(input)
    effective = model.resolve(catalog, model.document('', decode))
    reload(true)
else
    error_text = '无法读取受管 input.conf，未应用用户快捷键'
    publish()
end
mp.add_periodic_timer(1, function() if not saving then reload(false) end end)
