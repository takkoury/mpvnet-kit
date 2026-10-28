-- Playback options own their load/startup boundary. The settings controller
-- publishes preferences but never mutates a live decoder or track selection.
local mp=require('mp')
local model=dofile(mp.command_native({'expand-path','~~/script-modules/user-settings.lua'}))
local function option(id,kind,timing)
    local field=assert(model.field(id))
    local function read()
        if kind=='number' then return mp.get_property_number(id,field.default) end
        if kind=='boolean' then return mp.get_property_bool(id,field.default) end
        return mp.get_property(id,field.default)
    end
    model.owner(mp,{
        id=id,property=id,initialize_on_load=field.first_media==true,
        default_source=field.first_media and '宿主首次播放前设置' or '播放器启动配置',read=read,
        write=function(value)
            local name=timing=='next-media' and 'file-local-options/'..id or id
            if kind=='string' or kind=='choice' then return mp.set_property(name,value) end
            return mp.set_property_native(name,value)
        end,
    })
end
for _,id in ipairs({'slang','sub-visibility','alang','hwdec','volume','mute','fullscreen','ontop'}) do
    local field=model.field(id);option(id,field.kind,field.timing)
end
