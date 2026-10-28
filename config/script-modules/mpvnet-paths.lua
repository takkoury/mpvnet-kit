-- Optional machine-local path data. Keep mpvnet-local.conf out of public exports.
local mp = require('mp')
local utils = require('mp.utils')
local options = {capture_root = '', ffmpeg_path = '', python_path = '', mpv_path = ''}
require('mp.options').read_options(options, 'mpvnet-local')
local paths = {options = options}

-- Match mp.options line semantics. Preserve the source file in the storage
-- helper; this reader only exposes the four supported machine-local values.
function paths.parse_local(raw)
    if type(raw)~='string' or #raw>256*1024 then return nil,'本机路径配置无效或超过 256 KiB' end
    local values,seen={capture_root='',ffmpeg_path='',python_path='',mpv_path=''},{}
    for line in (raw..'\n'):gmatch('(.-)\n') do
        line=line:gsub('\r$','')
        if line:sub(1,1)~='#' then
            local name,value=line:match('^([^=]+)=(.*)$')
            if values[name]~=nil then
                if seen[name] then return nil,'本机路径配置有重复项目；未覆盖原配置' end
                seen[name]=true;values[name]=value
            end
        end
    end
    return values
end

function paths.capture_root()
    local path=mp.command_native({'expand-path','~~/script-opts/mpvnet-local.conf'})
    local file,_,errno=io.open(path,'rb')
    if not file then
        if errno==2 and not utils.file_info(path) then return '' end
        return options.capture_root
    end
    local raw=file:read(256*1024+1);file:close()
    local values=paths.parse_local(raw)
    return values and values.capture_root or options.capture_root
end

function paths.powershell()
    local root = os.getenv('SystemRoot') or os.getenv('WINDIR')
    return root and utils.join_path(root, 'System32/WindowsPowerShell/v1.0/powershell.exe') or 'powershell.exe'
end

function paths.capture_payload(payload)
    local root=paths.capture_root()
    if root~='' then payload.capture_root=root end
    if options.ffmpeg_path~='' then payload.ffmpeg_path=options.ffmpeg_path end
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
