-- Read the current extraction only. Callers keep the identity or track fields they need.
local M = {}

function M.read(mp, utils)
    local raw = mp.get_property_native('user-data/mpv/ytdl/json-subprocess-result/stdout')
    if type(raw) ~= 'string' or raw == '' or #raw > 24*1024*1024 then return end
    return utils.parse_json(raw) or false
end

-- Read during unload, before mpv releases this extraction. Match a complete
-- diagnostic for the expected extractor and input. Never display raw stderr.
function M.match_error(mp, extractor, id, pattern)
    if not id then return end
    local key = 'user-data/mpv/ytdl/json-subprocess-result/'
    if mp.get_property_number(key .. 'status', 0) == 0 then return end
    local err = mp.get_property_native(key .. 'stderr')
    if type(err) ~= 'string' then return end
    local prefix = 'ERROR: [' .. extractor .. '] ' .. id .. ': '
    for line in err:gmatch('[^\r\n]+') do
        if line:sub(1, #prefix) == prefix then
            local detail = line:sub(#prefix + 1):match(pattern)
            if detail then return detail end
        end
    end
end

function M.bilibili_part(data, bv, part)
    if type(data) ~= 'table' or data.extractor_key ~= 'BiliBili' or data.is_live then return end
    if data.entries or (data._type and data._type ~= 'video') then return end
    local id = bv .. '_p' .. part
    if data.id == id or (part == '1' and data.id == bv) then return id end
end

return M
