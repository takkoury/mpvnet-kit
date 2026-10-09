-- https://github.com/itKelis/MPV-Play-BiliBili-Comments
-- Local compatibility changes 2026-10-07: subtitle ownership and playback-bound callbacks.
-- Upstream GPLv3 license is retained in LICENSE.

local mp = require 'mp'
local utils = require 'mp.utils'
local options = require 'mp.options'

local o = {
	--是否自动显示弹幕
	autoplay = true,
	--最小弹幕数量
	mincount = 1,
	--弹幕字体
	fontname = "sans-serif",
	--弹幕字体大小
	fontsize = "50",
	--弹幕不透明度(0-1)
	opacity = "0.95",
	--滚动弹幕显示的持续时间 (秒)
	duration_marquee = "10",
	--静止弹幕显示的持续时间 (秒)
	duration_still = "5",
	--保留底部多少高度的空白区域 (取值0.0-1.0)
	percent = "0.75",
	--弹幕屏蔽的关键词文件路径，支持绝对和相对路径
	filter_file = "",
	--是否对低帧率视频自动添加fps滤镜，以保证滚动弹幕流畅
	fps_vf = false,
	--是否在osd显示日志
	log_osd = false,
	--是否使用Danmu2Ass.py，为false时使用Danmu2Ass.exe
	use_python = true,
	-- python可执行文件路径，默认为环境变量的python，若无法运行请指定 python[.exe] 的路径
	python_path = "python",
}

options.read_options(o, "bilibiliAssert")
local paths = dofile(mp.command_native({'expand-path', '~~/script-modules/mpvnet-paths.lua'}))
if paths.options.python_path ~= '' then o.python_path = paths.options.python_path end

local danmu_file = nil
local danmu_open = false
local danmu_sid = nil
local secondary_state = nil
local generation = 0
local pending_request = nil
local output_prefix = "bilibili-" .. (mp.get_property("pid") or "mpv") .. "-"
	.. os.time() .. "-" .. tostring(mp.get_time()):gsub("%W", "")

local function secondary_id()
	local value = tostring(mp.get_property("secondary-sid", "no"))
	if value == "no" or value == "false" then return nil end
	if value == "auto" then return mp.get_property_number("current-tracks/sub2/id") end
	local id = tonumber(value)
	if id then return id > 0 and id or nil end
	return -1 -- Unknown selection: preserve it rather than take the slot.
end

local function cancel_request()
	local token = pending_request
	pending_request = nil
	if token then mp.abort_async_command(token) end
end

local function get_cid()
	local cid, danmaku_id = nil, nil
	local tracks = mp.get_property_native("track-list")
	for _, track in ipairs(tracks) do
		if track["lang"] == "danmaku" then
			cid = track["external-filename"]:match("/(%d-)%.xml$")
			danmaku_id = track["id"]
			break
		end
	end
	return cid, danmaku_id
end

local function get_sub_ids()
	local ids = {}
	for _, track in ipairs(mp.get_property_native("track-list") or {}) do
		if track["type"] == "sub" then ids[track["id"]] = true end
	end
	return ids
end

local function file_exists(path)
	if path then
		local meta = utils.file_info(path)
		return meta and meta.is_file
	end
	return false
end

-- Log function: log to both terminal and MPV OSD (On-Screen Display)
local function log(string, secs)
	mp.msg.info(string)

	if o.log_osd then
		secs = secs or 2.5
		mp.osd_message(string, secs)
	end
end

-- load function
local function load_danmu(file)
	if not file_exists(file) then mp.osd_message("DANMAKU LOAD FAILED", 1) return end
	local secondary_sid = mp.get_property("secondary-sid", "no")
	if secondary_id() then mp.osd_message("SECONDARY SUBTITLE OCCUPIED", 1) return end
	local primary_sid = mp.get_property("sid", "no")
	local previous_ids = get_sub_ids()
	mp.commandv("sub-add", file, "auto", "Bilibili Danmaku")
	if mp.get_property("sid") ~= primary_sid then
		mp.set_property("sid", primary_sid)
	end
	local added_sid = nil
	for _, track in ipairs(mp.get_property_native("track-list") or {}) do
		if track["type"] == "sub" and not previous_ids[track["id"]]
			and track["title"] == "Bilibili Danmaku" then added_sid = track["id"] break end
	end
	if not added_sid then mp.osd_message("DANMAKU LOAD FAILED", 1) return end
	secondary_state = {
		sid = secondary_sid,
		visibility = mp.get_property_native("secondary-sub-visibility"),
		ass_override = mp.get_property_native("secondary-sub-ass-override"),
	}
	danmu_sid = added_sid
	mp.set_property_native("secondary-sub-visibility", false)
	mp.set_property_native("secondary-sub-ass-override", false)
	mp.set_property_native("secondary-sid", danmu_sid)
	local approximatedDanmukuCount = math.floor((utils.file_info(file)["size"] - 850) / 120)
	log(file ..
		' [' .. utils.file_info(file)["size"] ..
		'][' .. approximatedDanmukuCount .. ']')
	if o.autoplay and approximatedDanmukuCount >= o.mincount then
		Danmaku_show()
	end
end

-- check if danmaku exists, load if true
local function Danmaku_check()
	local cid = mp.get_opt('cid')

	if cid == nil then
		local path = mp.get_property("path")
		if path and not path:find('^%a[%w.+-]-://') and not (path:find('bilibili.com') or path:find('bilivideo.com')) then
			return
		end

		local danmaku_id = nil
		cid, danmaku_id = get_cid()

		if danmaku_id ~= nil and cid ~= nil then
			mp.commandv('sub-remove', danmaku_id)
		end
	end

	Danmaku_process(cid)
end

-- call Danmu2Ass executable
function Danmaku_process(cid)
	if cid == nil then return end
	if not o.use_python then mp.osd_message("DANMAKU LOAD FAILED", 1) return end
	local secondary_sid = secondary_id()
	if secondary_sid and secondary_sid ~= danmu_sid then
		mp.osd_message("SECONDARY SUBTITLE OCCUPIED", 1) return
	end
	Danmaku_terminate()
	generation = generation + 1
	local request_generation = generation
	local media_path = mp.get_property("path")
	mp.osd_message("LOADING DANMAKU", 1)

	-- get danmaku directory
	local danmaku_dir = os.getenv("TEMP") or "/tmp/"
	local output_path = utils.join_path(danmaku_dir, output_prefix .. "-" .. generation .. ".ass")
	-- get script directory
	local directory = mp.get_script_directory()
	local py_path = utils.join_path(directory, 'Danmu2Ass.py')
	local exe_path = utils.join_path(directory, 'Danmu2Ass.exe')

	-- no need to convert forwardslashes and backslashes

	local dw = 1920
	local dh = 1080
	local aspect = mp.get_property_number('width', 16) / mp.get_property_number('height', 9)
	if aspect > dw / dh then
		dh = math.floor(dw / aspect)
	elseif aspect < dw / dh then
		dw = math.floor(dh * aspect)
	end
	-- choose to use python or .exe
	local arg = nil
	if o.use_python then
		arg = {
			o.python_path, py_path,
			'-d', danmaku_dir,
			'-o', output_path,
			'-s', '' .. dw .. 'x' .. dh,
			'-fn', o.fontname,
			'-fs', o.fontsize,
			'-a', o.opacity,
			'-dm', o.duration_marquee,
			'-ds', o.duration_still,
			'-flf', mp.command_native({ "expand-path", o.filter_file }),
			'-p', tostring(math.floor(o.percent * dh)),
			'-r', cid,
		}
	else
		arg = {
			exe_path,
			'-d', danmaku_dir,
			'-s', '' .. dw .. 'x' .. dh,
			'-fn', o.fontname,
			'-fs', o.fontsize,
			'-a', o.opacity,
			'-dm', o.duration_marquee,
			'-ds', o.duration_still,
			'-flf', mp.command_native({ "expand-path", o.filter_file }),
			'-p', tostring(math.floor(o.percent * dh)),
			'-r', cid,
		}
	end

	-- run python to get comments
	pending_request = mp.command_native_async({
		name = 'subprocess',
		playback_only = true,
		capture_stdout = true,
		args = arg,
	}, function(res, val, err)
		if request_generation == generation then pending_request = nil end
		if request_generation ~= generation or mp.get_property("path") ~= media_path then
			os.remove(output_path) return -- This callback owns only its unique output file.
		end
		if res and val and val.status == 0 then
			danmu_file = output_path
			load_danmu(danmu_file)
		else
			os.remove(output_path)
			log("DANMAKU LOAD FAILED: " .. tostring(err or (val and val.status)))
			mp.osd_message("DANMAKU LOAD FAILED", 1)
		end
	end)
end

-- toggle danmaku visibility
function Danmaku_toggle()
	if not danmu_file or not danmu_sid or secondary_id() ~= danmu_sid then mp.osd_message("NO DANMAKU", 1) return end

	if danmu_open then
		Danmaku_unshow()
	elseif secondary_id() == danmu_sid then
		Danmaku_show()
	end
	mp.osd_message(danmu_open and "DANMAKU ON" or "DANMAKU OFF", 1)
end

-- remove danmaku
function Danmaku_terminate()
	generation = generation + 1
	cancel_request()
	if not danmu_file then return end
	log('FILE ENDED')
	if file_exists(danmu_file) then
		os.remove(danmu_file)
	end
	if secondary_state and secondary_id() == danmu_sid then
		mp.set_property("secondary-sid", secondary_state.sid)
		mp.set_property_native("secondary-sub-visibility", secondary_state.visibility)
		mp.set_property_native("secondary-sub-ass-override", secondary_state.ass_override)
	end
	for _, track in ipairs(mp.get_property_native("track-list") or {}) do
		if track["id"] == danmu_sid and track["title"] == "Bilibili Danmaku" then
			mp.commandv("sub-remove", danmu_sid) break
		end
	end
	danmu_file = nil
	danmu_open = false
	danmu_sid = nil
	secondary_state = nil
	mp.commandv('vf', 'remove', '@Danmaku-FPS')
end

-- hide danmaku
function Danmaku_unshow()
	if not danmu_sid or secondary_id() ~= danmu_sid then return end
	log('DANMAKU OFF')
	danmu_open = false
	mp.set_property_native("secondary-sub-visibility", false)
	mp.commandv('vf', 'remove', '@Danmaku-FPS')
end

-- show danmaku
function Danmaku_show()
	if not danmu_sid or secondary_id() ~= danmu_sid then return end
	log('DANMAKU ON')
	danmu_open = true
	mp.set_property_native("secondary-sub-visibility", true)
	Add_fps_vf()
end

function Add_fps_vf()
	if not danmu_open or not o.fps_vf then return end

	local video_fps = mp.get_property_number("container-fps", 30)
	local video_speed = mp.get_property_number("speed", 1)

	if video_fps < 45 and video_speed < 1.5 then
		mp.commandv('vf', 'append', '@Danmaku-FPS:lavfi="fps=fps=60:round=down"')
	else
		mp.commandv('vf', 'remove', '@Danmaku-FPS')
	end
end

mp.register_event("file-loaded", Danmaku_check)
mp.register_event("end-file", Danmaku_terminate)
mp.observe_property("speed", nil, Add_fps_vf)

mp.register_script_message('load-danmaku', Danmaku_process)
mp.add_key_binding(nil, 'toggle', Danmaku_toggle)
