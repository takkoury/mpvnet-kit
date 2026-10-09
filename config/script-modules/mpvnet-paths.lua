-- Optional machine-local path data. Keep mpvnet-local.conf out of public exports.
local mp = require('mp')
local utils = require('mp.utils')
local options = {capture_root = '', ffmpeg_path = '', python_path = '', mpv_path = ''}
require('mp.options').read_options(options, 'mpvnet-local')
local paths = {options = options}

function paths.powershell()
    local root = os.getenv('SystemRoot') or os.getenv('WINDIR')
    return root and utils.join_path(root, 'System32/WindowsPowerShell/v1.0/powershell.exe') or 'powershell.exe'
end

function paths.capture_payload(payload)
    for _, name in ipairs({'capture_root', 'ffmpeg_path'}) do
        if options[name] ~= '' then payload[name] = options[name] end
    end
    return payload
end

local function executable(path)
    if type(path) ~= 'string' or path == '' or path:find('%z') then return nil end
    local info = utils.file_info(path)
    return info and info.is_file and path or nil
end

function paths.thumbnail_backend(configured)
    if options.mpv_path ~= '' then return options.mpv_path, 'local-config' end
    if configured ~= 'mpv' and configured ~= '' then return configured, 'thumbfast-config' end
    local frontend = executable(mp.get_property_native('user-data/frontend/process-path'))
    if frontend then return frontend, 'frontend' end
    -- mpv.net can omit frontend/process-path at script startup. Query only our
    -- numeric PID, with fixed code; no media, paths or settings become shell code.
    local pid = tonumber(mp.get_property_number('pid', 0))
    if pid and pid > 0 and pid == math.floor(pid) then
        local result = mp.command_native({name = 'subprocess', playback_only = false,
            capture_stdout = true, capture_stderr = true, args = {paths.powershell(),
                '-NoProfile', '-NonInteractive', '-Command',
                '[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false);' ..
                '[Diagnostics.Process]::GetProcessById(' .. string.format('%.0f', pid) .. ').MainModule.FileName'}})
        local own = result and result.status == 0 and executable((result.stdout or ''):gsub('[\r\n]+$', ''))
        if own then return own, 'current-process' end
    end
    local config = mp.command_native({'expand-path', '~~/'})
    local parent = type(config) == 'string' and config:gsub('[/\\]+$', ''):match('^(.*)[/\\][^/\\]+$')
    local portable = parent and executable(utils.join_path(parent, 'mpvnet.exe'))
    if portable then return portable, 'portable-parent' end
    return configured, 'unresolved'
end

return paths
