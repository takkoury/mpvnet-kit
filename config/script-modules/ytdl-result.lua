-- Read the current extraction only. Callers keep the identity or track fields they need.
local M = {}

function M.read(mp, utils)
    local raw = mp.get_property_native('user-data/mpv/ytdl/json-subprocess-result/stdout')
    if type(raw) ~= 'string' or raw == '' or #raw > 24*1024*1024 then return end
    return utils.parse_json(raw) or false
end

function M.bilibili_part(data, bv, part)
    if type(data) ~= 'table' or data.extractor_key ~= 'BiliBili' or data.is_live then return end
    if data.entries or (data._type and data._type ~= 'video') then return end
    local id = bv .. '_p' .. part
    if data.id == id or (part == '1' and data.id == bv) then return id end
end

return M
