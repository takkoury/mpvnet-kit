-- The action catalog owns commands; user JSON can only select keys for these IDs.
local M = {max_bytes = 256 * 1024}
local definitions = {
    {'danmaku.toggle', '字幕与弹幕', '显示／隐藏弹幕', 'script-binding bilibiliAssert/toggle'},
    {'playback.pause', '播放与定位', '播放／暂停', 'script-binding playback_feedback/space'},
    {'playback.seek-back', '播放与定位', '后退 3 秒', 'script-binding playback_feedback/seek-back'},
    {'playback.seek-forward', '播放与定位', '前进 3 秒', 'script-binding playback_feedback/seek-forward'},
    {'playback.seek-back-small', '播放与定位', '后退 1 秒', 'script-binding playback_feedback/seek-back-small'},
    {'playback.seek-forward-small', '播放与定位', '前进 1 秒', 'script-binding playback_feedback/seek-forward-small'},
    {'playback.seek-back-large', '播放与定位', '后退 10 秒', 'script-binding playback_feedback/seek-back-large'},
    {'playback.seek-forward-large', '播放与定位', '前进 10 秒', 'script-binding playback_feedback/seek-forward-large'},
    {'playback.frame-back', '播放与定位', '上一帧', 'no-osd frame-back-step'},
    {'playback.frame-forward', '播放与定位', '下一帧', 'script-binding playback_feedback/frame-forward'},
    {'playback.reload', '播放与定位', '重新加载当前媒体', 'script-binding playback_feedback/reload'},
    {'playback.speed-down', '播放与定位', '降低速度', 'script-binding playback_feedback/speed-down'},
    {'playback.speed-up', '播放与定位', '提高速度', 'script-binding playback_feedback/speed-up'},
    {'playback.speed-reset', '播放与定位', '恢复 1 倍速度', 'script-binding playback_feedback/speed-reset'},
    {'subtitle.toggle', '字幕与弹幕', '显示／隐藏普通字幕', 'script-binding subtitle_controls/toggle'},
    {'subtitle.select-line', '字幕与弹幕', '选择字幕行', 'script-binding select/select-subtitle-line', true},
    {'subtitle.seek-prev', '字幕与弹幕', '跳到上一句字幕', 'script-binding subtitle_controls/seek-prev'},
    {'subtitle.seek-next', '字幕与弹幕', '跳到下一句字幕', 'script-binding subtitle_controls/seek-next'},
    {'subtitle.delay-down', '字幕与弹幕', '字幕提前 0.1 秒', 'script-binding subtitle_controls/delay-down'},
    {'subtitle.delay-up', '字幕与弹幕', '字幕延后 0.1 秒', 'script-binding subtitle_controls/delay-up'},
    {'subtitle.delay-reset', '字幕与弹幕', '字幕延迟归零', 'script-binding subtitle_controls/delay-reset'},
    {'subtitle.adjust', '字幕与弹幕', '调整字幕位置与字号', 'script-binding subtitle_controls/adjust-mode', true},
    {'subtitle.copy', '字幕与弹幕', '复制当前字幕', 'script-binding subtitle_controls/copy'},
    {'playback.save-mark', '循环与标记', '保存当前位置标记', 'script-binding playback_feedback/save-mark'},
    {'playback.jump-mark', '循环与标记', '跳回标记位置', 'script-binding playback_feedback/jump-mark'},
    {'playback.ab-loop', '循环与标记', '设置／清除 A-B 循环', 'script-binding playback_feedback/ab-loop'},
    {'playback.file-loop', '循环与标记', '开关单文件循环', 'script-binding playback_feedback/file-loop'},
    {'playlist.previous', '播放与定位', '上一个文件', 'script-binding playlist_controls/previous'},
    {'playlist.next', '播放与定位', '下一个文件', 'script-binding playlist_controls/next'},
    {'window.fullscreen', '窗口与界面', '全屏／退出全屏', 'script-binding playback_feedback/fullscreen'},
    {'window.ontop', '窗口与界面', '置顶／取消置顶', 'script-binding playback_feedback/ontop'},
    {'window.scale-reset', '窗口与界面', '恢复 100% 窗口尺寸', 'script-binding playback_feedback/window-100'},
    {'tools.media-info', '工具与设置', '媒体信息', 'script-binding playback_feedback/media-info', true},
    {'tools.stats', '工具与设置', '显示／隐藏播放统计', 'script-binding stats/display-stats-toggle', true},
    {'window.osc', '窗口与界面', '切换控制栏显示方式', 'script-binding playback_feedback/osc-visibility'},
    {'tools.console', '工具与设置', '控制台', 'script-binding console/enable', true},
    {'tools.copy-time', '工具与设置', '复制当前时间', 'script-binding playback_feedback/copy-time'},
    {'tools.clipboard-url', '工具与设置', '打开剪贴板中的网址', 'script-binding playback_feedback/clipboard-url'},
    {'playlist.toggle', '窗口与界面', '显示／隐藏播放列表侧窗', 'script-binding playlist_controls/toggle'},
}
-- New entries have no key literals. Defaults still come only from input.conf;
-- native defaults are command coverage, never an extra default-key source.
local additions = {
    {'file.open', '文件', '打开文件…', 'script-message-to mpvnet open-files', true},
    {'file.open-clipboard', '文件', '打开剪贴板中的文件或网址', 'script-message-to mpvnet open-clipboard', true},
    {'file.open-disc', '文件', '打开 DVD／蓝光光盘或目录…', 'script-message-to mpvnet open-optical-media', true},
    {'file.append', '文件', '追加文件到播放列表…', 'script-message-to mpvnet open-files append', true},
    {'file.append-clipboard', '文件', '从剪贴板追加文件或网址', 'script-message-to mpvnet open-clipboard append', true},
    {'file.open-location', '文件', '打开文件所在位置／来源网页', 'script-binding playback_feedback/open-media-path', true},
    {'file.copy-location', '文件', '复制文件路径／来源网址', 'script-binding playback_feedback/copy-media-path'},
    {'file.history', '文件', '播放历史…', 'script-binding select/select-watch-history', true},
    {'file.watch-later', '文件', '稍后继续播放…', 'script-binding select/select-watch-later', true},
    {'file.quit', '文件', '退出播放器', 'quit'},
    {'file.quit-watch-later', '文件', '保存进度并退出', 'quit-watch-later'},
    {'playback.stop', '播放与定位', '停止播放', 'stop'},
    {'playlist.first', '播放与定位', '跳到列表首项', 'script-message-to mpvnet playlist-first'},
    {'playlist.last', '播放与定位', '跳到列表末项', 'script-message-to mpvnet playlist-last'},
    {'chapter.previous', '播放与定位', '上一章节', 'add chapter -1'},
    {'chapter.next', '播放与定位', '下一章节', 'add chapter 1'},
    {'chapter.select', '播放与定位', '选择章节…', 'script-binding select/select-chapter', true},
    {'edition.select', '播放与定位', '选择媒体版本（Edition）…', 'script-binding select/select-edition', true},
    {'playback.seek-back-5', '播放与定位', '后退 5 秒', 'script-message-to playback_feedback seek -5'},
    {'playback.seek-forward-5', '播放与定位', '前进 5 秒', 'script-message-to playback_feedback seek 5'},
    {'playback.seek-back-30', '播放与定位', '后退 30 秒', 'script-message-to playback_feedback seek -30'},
    {'playback.seek-forward-30', '播放与定位', '前进 30 秒', 'script-message-to playback_feedback seek 30'},
    {'playback.seek-back-60', '播放与定位', '后退 1 分钟', 'script-message-to playback_feedback seek -60'},
    {'playback.seek-forward-60', '播放与定位', '前进 1 分钟', 'script-message-to playback_feedback seek 60'},
    {'playback.seek-back-300', '播放与定位', '后退 5 分钟', 'script-message-to playback_feedback seek -300'},
    {'playback.seek-forward-300', '播放与定位', '前进 5 分钟', 'script-message-to playback_feedback seek 300'},
    {'playback.revert-seek', '播放与定位', '撤销上次跳转', 'script-binding playback_feedback/revert-seek'},
    {'playback.native-seek-mark', '循环与标记', '保存原生跳转撤销标记', 'revert-seek mark'},
    {'playback.show-time', '播放与定位', '显示播放时间与时长', 'script-message-to playback_feedback show-time'},
    {'playlist.shuffle', '循环与标记', '打乱播放列表', 'playlist-shuffle'},
    {'playlist.loop', '循环与标记', '开关整个列表循环', 'cycle-values loop-playlist inf no'},
    {'playback.speed-half', '播放与定位', '当前速度减半（×0.5）', 'multiply speed 0.5'},
    {'playback.speed-double', '播放与定位', '当前速度加倍（×2）', 'multiply speed 2.0'},
    {'playback.speed-multiply-down', '播放与定位', '相对减速（÷1.1）', 'multiply speed 1/1.1'},
    {'playback.speed-multiply-up', '播放与定位', '相对加速（×1.1）', 'multiply speed 1.1'},
    {'playback.speed-add-down', '播放与定位', '降低速度 0.25 倍', 'script-message-to playback_feedback add-speed -0.25'},
    {'playback.speed-add-up', '播放与定位', '提高速度 0.25 倍', 'script-message-to playback_feedback add-speed 0.25'},
    {'playback.speed-0.5', '播放与定位', '设置 0.5 倍速度', 'script-message-to playback_feedback set-speed 0.5'},
    {'playback.speed-0.75', '播放与定位', '设置 0.75 倍速度', 'script-message-to playback_feedback set-speed 0.75'},
    {'playback.speed-1.25', '播放与定位', '设置 1.25 倍速度', 'script-message-to playback_feedback set-speed 1.25'},
    {'playback.speed-1.5', '播放与定位', '设置 1.5 倍速度', 'script-message-to playback_feedback set-speed 1.5'},
    {'playback.speed-2', '播放与定位', '设置 2 倍速度', 'script-message-to playback_feedback set-speed 2'},
    {'subtitle.select', '字幕与弹幕', '选择普通字幕…', 'script-binding subtitle_controls/select', true},
    {'subtitle.cycle-next', '字幕与弹幕', '下一条普通字幕轨', 'script-binding subtitle_controls/cycle-next'},
    {'subtitle.cycle-prev', '字幕与弹幕', '上一条普通字幕轨', 'script-binding subtitle_controls/cycle-prev'},
    {'subtitle.load', '字幕与弹幕', '加载外挂字幕…', 'script-message-to mpvnet load-sub', true},
    {'subtitle.reset-adjustment', '字幕与弹幕', '恢复字幕位置与字号', 'script-binding subtitle_controls/reset-adjustment'},
    {'subtitle.position-up', '字幕与弹幕', '上移字幕（1 个百分点）', 'script-binding subtitle_controls/position-up'},
    {'subtitle.position-down', '字幕与弹幕', '下移字幕（1 个百分点）', 'script-binding subtitle_controls/position-down'},
    {'subtitle.size-up', '字幕与弹幕', '增大字幕字号（小步 0.05 倍）', 'script-binding subtitle_controls/size-up'},
    {'subtitle.size-down', '字幕与弹幕', '减小字幕字号（小步 0.05 倍）', 'script-binding subtitle_controls/size-down'},
    {'subtitle.size-up-large', '字幕与弹幕', '增大字幕字号（原生大步 0.1 倍）', 'add sub-scale 0.1'},
    {'subtitle.size-down-large', '字幕与弹幕', '减小字幕字号（原生大步 0.1 倍）', 'add sub-scale -0.1'},
    {'subtitle.ass-override', '字幕与弹幕', '开关 SSA／ASS 样式覆盖', 'cycle-values sub-ass-override force no'},
    {'subtitle.select-native', '字幕与弹幕', '原生主字幕轨选择…', 'script-binding select/select-sid', true},
    {'subtitle.select-secondary', '字幕与弹幕', '原生次字幕轨选择…', 'script-binding select/select-secondary-sid', true},
    {'danmaku.renderer-overlay', '字幕与弹幕', '弹幕：固定字号与流畅滚动（试用，本实例）', 'script-message-to bilibiliAssert renderer overlay', false, true},
    {'danmaku.renderer-ass', '字幕与弹幕', '弹幕：恢复原 ASS（本实例）', 'script-message-to bilibiliAssert renderer ass', false, true},
    {'audio.select', '音频', '选择音轨…', 'script-binding select/select-aid', true},
    {'audio.next', '音频', '下一条音轨', 'script-message-to mpvnet cycle-audio'},
    {'audio.previous', '音频', '上一条音轨', 'cycle audio down'},
    {'audio.device', '音频', '选择音频设备…', 'script-binding select/select-audio-device', true},
    {'audio.load', '音频', '加载外挂音频…', 'script-message-to mpvnet load-audio', true},
    {'audio.mute', '音频', '静音／取消静音', 'cycle mute'},
    {'audio.volume-up', '音频', '增加音量 2', 'add volume 2'},
    {'audio.volume-down', '音频', '减少音量 2', 'add volume -2'},
    {'audio.volume-up-large', '音频', '增加音量 5', 'no-osd add volume 5'},
    {'audio.volume-down-large', '音频', '减少音量 5', 'no-osd add volume -5'},
    {'audio.volume-reset', '音频', '恢复 100% 音量', 'no-osd set volume 100'},
    {'audio.delay-down', '音频', '音频提前 0.1 秒', 'add audio-delay -0.1'},
    {'audio.delay-up', '音频', '音频延后 0.1 秒', 'add audio-delay 0.1'},
    {'audio.only', '音频', '仅音频／恢复视频', 'script-binding playback_feedback/audio-only'},
    {'video.enhancement-original', '画面', '画面增强：原始画面（Original）', 'script-message-to enhancement_controls set-preset OFF'},
    {'video.enhancement-scaling', '画面', '画面增强：高质量缩放（Scaling）', 'script-message-to enhancement_controls set-preset QUALITY'},
    {'video.enhancement-deband', '画面', '画面增强：去色带（Deband）', 'script-message-to enhancement_controls set-preset SMOOTH'},
    {'video.enhancement-anime-light', '画面', '画面增强：动画增强·轻（Anime4K-L）', 'script-message-to enhancement_controls set-preset ANIME_LIGHT'},
    {'video.enhancement-anime-strong', '画面', '画面增强：动画增强·强（Anime4K-S）', 'script-message-to enhancement_controls set-preset ANIME_STRONG'},
    {'video.select', '画面', '选择视频轨…', 'script-binding select/select-vid', true},
    {'video.aspect', '画面', '切换宽高比', 'cycle-values video-aspect-override 16:9 4:3 2.35:1 0 -1'},
    {'video.rotate', '画面', '旋转画面', 'cycle-values video-rotate 90 180 270 0'},
    {'video.deinterlace', '画面', '开关去隔行', 'cycle deinterlace'},
    {'video.zoom-in', '画面', '放大画面 0.1', 'add video-zoom 0.1'},
    {'video.zoom-out', '画面', '缩小画面 0.1', 'add video-zoom -0.1'},
    {'video.pan-left', '画面', '向左平移画面', 'add video-pan-x -0.01'},
    {'video.pan-right', '画面', '向右平移画面', 'add video-pan-x 0.01'},
    {'video.pan-up', '画面', '向上平移画面', 'add video-pan-y -0.01'},
    {'video.pan-down', '画面', '向下平移画面', 'add video-pan-y 0.01'},
    {'video.panscan-down', '画面', '减少裁切填充', 'add panscan -0.1'},
    {'video.panscan-up', '画面', '增加裁切填充', 'add panscan 0.1'},
    {'video.reset-pan-scan', '画面', '恢复画面缩放与平移', 'set video-zoom 0; set video-pan-x 0; set video-pan-y 0'},
    {'video.contrast-down', '画面', '降低对比度', 'add contrast -1'},
    {'video.contrast-up', '画面', '提高对比度', 'add contrast 1'},
    {'video.brightness-down', '画面', '降低亮度', 'add brightness -1'},
    {'video.brightness-up', '画面', '提高亮度', 'add brightness 1'},
    {'video.gamma-down', '画面', '降低伽马', 'add gamma -1'},
    {'video.gamma-up', '画面', '提高伽马', 'add gamma 1'},
    {'video.saturation-down', '画面', '降低饱和度', 'add saturation -1'},
    {'video.saturation-up', '画面', '提高饱和度', 'add saturation 1'},
    {'video.hwdec', '画面', '开关硬件解码', 'cycle-values hwdec auto no'},
    {'capture.screenshot', '截图与片段', '保存源画面 PNG', 'script-binding capture_controls/screenshot'},
    {'capture.clip-point', '截图与片段', '设置片段起点／终点并导出', 'script-binding capture_controls/clip-point'},
    {'capture.format-webp', '截图与片段', '片段导出格式：WebP', 'script-message-to capture_controls set-default-format webp'},
    {'capture.format-gif', '截图与片段', '片段导出格式：GIF', 'script-message-to capture_controls set-default-format gif'},
    {'capture.format-mp4', '截图与片段', '片段导出格式：MP4', 'script-message-to capture_controls set-default-format mp4'},
    {'capture.copy-latest', '截图与片段', '复制最近导出片段', 'script-binding capture_controls/copy-latest'},
    {'capture.open-folder', '截图与片段', '打开截图与片段目录', 'script-binding capture_controls/open-folder', true},
    {'capture.native-subtitles', '截图与片段', '原生截图（包含字幕）', 'async screenshot'},
    {'capture.native-video', '截图与片段', '原生截图（不含字幕）', 'async screenshot video'},
    {'window.border', '窗口与界面', '显示／隐藏窗口边框', 'cycle border'},
    {'window.enlarge', '窗口与界面', '放大窗口', 'script-message-to mpvnet scale-window 1.2'},
    {'window.shrink', '窗口与界面', '缩小窗口', 'script-message-to mpvnet scale-window 0.8'},
    {'window.scale-half', '窗口与界面', '窗口尺寸：50%', 'script-message-to mpvnet window-scale 0.5'},
    {'window.scale-double', '窗口与界面', '窗口尺寸：200%', 'script-message-to mpvnet window-scale 2.0'},
    {'window.scale-triple', '窗口与界面', '窗口尺寸：300%', 'script-message-to mpvnet window-scale 3.0'},
    {'window.move-left', '窗口与界面', '窗口靠左', 'script-message-to mpvnet move-window left'},
    {'window.move-right', '窗口与界面', '窗口靠右', 'script-message-to mpvnet move-window right'},
    {'window.move-top', '窗口与界面', '窗口靠上', 'script-message-to mpvnet move-window top'},
    {'window.move-bottom', '窗口与界面', '窗口靠下', 'script-message-to mpvnet move-window bottom'},
    {'window.move-center', '窗口与界面', '窗口居中', 'script-message-to mpvnet move-window center'},
    {'window.minimize', '窗口与界面', '最小化／恢复窗口', 'cycle window-minimized'},
    {'window.maximize', '窗口与界面', '最大化／恢复窗口（非全屏）', 'cycle window-maximized'},
    {'window.persistent-progress', '窗口与界面', '显示／隐藏常驻进度条', 'script-binding modernz/progress-toggle'},
    {'tools.media-info-osd', '工具与设置', '原生媒体信息（屏幕文字）', 'script-message-to mpvnet show-media-info osd', true},
    {'tools.media-info-dialog', '工具与设置', '原生媒体信息（对话框）', 'script-message-to mpvnet show-media-info msgbox', true},
    {'tools.progress', '工具与设置', '显示原生播放进度', 'show-progress'},
    {'tools.selector-menu', '工具与设置', '屏幕内主菜单…', 'script-binding select/menu', true},
    {'tools.selector-playlist', '工具与设置', '原生播放列表选择器…', 'script-binding select/select-playlist', true},
    {'tools.selector-tracks', '工具与设置', '全部轨道选择器…', 'script-binding select/select-track', true},
    {'tools.selector-bindings', '工具与设置', '屏幕内快捷键选择器…', 'script-binding select/select-binding', true},
    {'tools.selector-properties', '工具与设置', '屏幕内播放器属性…', 'script-binding select/show-properties', true},
    {'tools.config-editor', '工具与设置', '打开原生配置编辑器…', 'script-message-to mpvnet show-conf-editor', true},
    {'tools.shortcuts-editor', '工具与设置', '打开用户快捷键窗口…', 'script-binding user_shortcuts/open', true},
    {'tools.native-input-editor', '工具与设置', '打开原生快捷键编辑器（高级）…', 'script-message-to mpvnet show-input-editor', true},
    {'tools.edit-mpv-conf', '工具与设置', '编辑 mpv.conf', 'script-message-to mpvnet edit-conf-file mpv.conf', true},
    {'tools.edit-input-conf', '工具与设置', '编辑 input.conf', 'script-message-to mpvnet edit-conf-file input.conf', true},
    {'tools.open-config-folder', '工具与设置', '打开配置目录', 'script-message-to mpvnet open-conf-folder', true},
    {'tools.commands', '工具与设置', '诊断：命令列表', 'script-message-to mpvnet show-commands', true},
    {'tools.bindings-editor', '工具与设置', '诊断：在编辑器查看有效快捷键', 'script-message-to mpvnet show-bindings', true},
    {'tools.bindings-osd', '工具与设置', '诊断：在屏幕查看有效快捷键', 'script-binding stats/display-page-4-toggle', true},
    {'tools.keys', '工具与设置', '诊断：支持的按键', 'script-message-to mpvnet show-keys', true},
    {'tools.protocols', '工具与设置', '诊断：支持的协议', 'script-message-to mpvnet show-protocols', true},
    {'tools.decoders', '工具与设置', '诊断：解码器列表', 'script-message-to mpvnet show-decoders', true},
    {'tools.demuxers', '工具与设置', '诊断：解封装器列表', 'script-message-to mpvnet show-demuxers', true},
    {'tools.profiles', '工具与设置', '诊断：查看配置方案', 'script-message-to mpvnet show-profiles', true},
    {'system.register-video', '工具与设置', '系统集成：注册视频文件关联', 'script-message-to mpvnet reg-file-assoc video', true},
    {'system.register-audio', '工具与设置', '系统集成：注册音频文件关联', 'script-message-to mpvnet reg-file-assoc audio', true},
    {'system.register-image', '工具与设置', '系统集成：注册图片文件关联', 'script-message-to mpvnet reg-file-assoc image', true},
    {'system.unregister', '工具与设置', '系统集成：取消文件关联', 'script-message-to mpvnet reg-file-assoc unreg', true},
    {'system.add-path', '工具与设置', '系统集成：将 mpv.net 加入 PATH', 'script-message-to mpvnet add-to-path', true},
    {'system.remove-path', '工具与设置', '系统集成：从 PATH 移除 mpv.net', 'script-message-to mpvnet remove-from-path', true},
    {'help.mpv', '工具与设置', '帮助：mpv 官网', 'script-message-to mpvnet shell-execute https://mpv.io', true},
    {'help.mpvnet', '工具与设置', '帮助：mpv.net 项目主页', 'script-message-to mpvnet shell-execute https://github.com/mpvnet-player/mpv.net', true},
    {'help.mpv-manual', '工具与设置', '帮助：mpv 使用手册', 'script-message-to mpvnet shell-execute https://mpv.io/manual/stable', true},
    {'help.mpvnet-manual', '工具与设置', '帮助：mpv.net 使用手册', 'script-message-to mpvnet shell-execute https://github.com/mpvnet-player/mpv.net/blob/main/docs/manual.md', true},
    {'help.awesome-mpv', '工具与设置', '帮助：mpv 扩展资源', 'script-message-to mpvnet shell-execute https://github.com/stax76/awesome-mpv', true},
    {'help.about', '工具与设置', '关于 mpv.net', 'script-message-to mpvnet show-about', true},
    {'tools.context-menu', '工具与设置', '打开右键菜单（鼠标需离开控制栏）', 'script-message-to mpvnet show-menu', true},
}
for _, def in ipairs(additions) do definitions[#definitions+1] = def end

-- Fixed semantic aliases keep one function in the editor. These are never
-- interpreted from user JSON, and never alter the command of an existing ID.
local command_aliases = {
    {'script-binding playback_feedback/toggle-pause', 'playback.pause'},
    {'script-message-to mpvnet play-pause', 'playback.pause'}, {'cycle pause', 'playback.pause'},
    {'playlist-prev', 'playlist.previous'}, {'playlist-next', 'playlist.next'},
    {'frame-step', 'playback.frame-forward'}, {'frame-back-step', 'playback.frame-back'},
    {'script-binding modernz/fullscreen-video-double-click', 'window.fullscreen'},
    {'cycle fullscreen', 'window.fullscreen'}, {'cycle ontop', 'window.ontop'}, {'osd-msg cycle ontop', 'window.ontop'},
    {'script-message-to mpvnet window-scale 1.0', 'window.scale-reset'},
    {'script-message-to mpvnet window-scale 1', 'window.scale-reset'},
    {'script-binding osc/visibility', 'window.osc'}, {'script-binding modernz/visibility', 'window.osc'},
    {'script-message-to mpvnet cycle-subtitles', 'subtitle.cycle-next'},
    {'cycle sub-visibility', 'subtitle.toggle'}, {'add sub-delay -0.1', 'subtitle.delay-down'},
    {'add sub-delay 0.1', 'subtitle.delay-up'}, {'add sub-pos -1', 'subtitle.position-up'}, {'add sub-pos 1', 'subtitle.position-down'},
    {'set speed 1', 'playback.speed-reset'}, {'script-message-to playback_feedback set-speed 1', 'playback.speed-reset'},
    {'script-message-to playback_feedback set-speed 1 quiet', 'playback.speed-reset'},
    {'ab-loop', 'playback.ab-loop'}, {'cycle-values loop-file inf no', 'playback.file-loop'},
    {'osd-msg cycle-values loop-file inf no', 'playback.file-loop'},
    {'no-osd seek -1 exact', 'playback.seek-back-small'}, {'no-osd seek 1 exact', 'playback.seek-forward-small'},
    {'seek -5', 'playback.seek-back-5'}, {'seek 5', 'playback.seek-forward-5'},
    {'no-osd seek -5 exact', 'playback.seek-back-5'}, {'no-osd seek 5 exact', 'playback.seek-forward-5'},
    {'no-osd seek -5', 'playback.seek-back-5'}, {'no-osd seek 5', 'playback.seek-forward-5'},
    {'seek -30', 'playback.seek-back-30'}, {'seek 30', 'playback.seek-forward-30'},
    {'seek -60', 'playback.seek-back-60'}, {'seek 60', 'playback.seek-forward-60'},
    {'seek -300', 'playback.seek-back-300'}, {'seek 300', 'playback.seek-forward-300'},
    {'script-message-to playback_feedback seek -10 relative+exact', 'playback.seek-back-large'},
    {'script-message-to playback_feedback seek 10 relative+exact', 'playback.seek-forward-large'},
    {'revert-seek', 'playback.revert-seek'}, {'no-osd sub-seek -1', 'subtitle.seek-prev'}, {'no-osd sub-seek 1', 'subtitle.seek-next'},
    {'no-osd cycle mute', 'audio.mute'},
    {'cycle audio', 'audio.next'}, {'script-binding stats/display-page-1-toggle', 'tools.stats'},
    {'osd-msg screenshot video', 'capture.native-video'},
}

local names = {
    space='Space', enter='Enter', ['return']='Enter', tab='Tab', bs='BS', backspace='BS',
    home='Home', ['end']='End', pgup='PGUP', pageup='PGUP', pgdwn='PGDWN', pagedown='PGDWN',
    left='Left', right='Right', up='Up', down='Down', esc='Esc', escape='Esc', del='Del', delete='Del',
}
local shifted = {}
local plain, upper = '`1234567890-=[]\\;\',./', '~!@#$%^&*()_+{}|:"<>?'
for i = 1, #plain do shifted[plain:sub(i,i)] = upper:sub(i,i) end
local reserved = {Esc=true, Up=true, Down=true, Del=true, ['Ctrl+f']=true, ['Alt+F4']=true, _=true}

function M.normalize_key(raw)
    if type(raw) ~= 'string' or #raw == 0 or #raw > 48 or raw:find('%s') then return nil end
    local mods = {}
    while true do
        local prefix, rest = raw:match('^([^+]+)%+(.+)$')
        if not prefix then break end
        prefix = prefix:lower()
        if (prefix ~= 'ctrl' and prefix ~= 'alt' and prefix ~= 'shift') or mods[prefix] then return nil end
        mods[prefix], raw = true, rest
    end
    local base = names[raw:lower()]
    if not base then
        local f = raw:match('^[Ff](%d+)$')
        if f and tonumber(f) >= 1 and tonumber(f) <= 24 and tostring(tonumber(f)) == f then base = 'F' .. f end
    end
    if not base and #raw == 1 and raw:byte() >= 33 and raw:byte() <= 126 then base = raw end
    if not base then return nil end
    if (base == 'Esc' or base == 'Up' or base == 'Down' or base == 'Del') and next(mods) then return nil end
    if base:match('^%a$') then
        if mods.ctrl or mods.alt then base = base:lower()
        elseif mods.shift then base, mods.shift = base:upper(), nil end
    elseif #base == 1 and mods.shift then
        base, mods.shift = shifted[base] or base, nil
    end
    return (mods.ctrl and 'Ctrl+' or '') .. (mods.alt and 'Alt+' or '')
        .. (mods.shift and 'Shift+' or '') .. base
end

function M.is_reserved(key) return reserved[key] == true end

local function copy(values)
    local result = {}; for i, value in ipairs(values) do result[i] = value end; return result
end

function M.catalog(input)
    input = input:gsub('^\239\187\191', '')
    local catalog = {actions={}, by_id={}, by_command={}, baseline={}, foreign={}, command_sources={}}
    local menu_commands = {}
    for line in (input .. '\n'):gmatch('(.-)\r?\n') do
        local command = line:match('^%s*_%s+(.+)%s+#menu:')
        if command then menu_commands[command:gsub('%s+$', '')] = true end
    end
    for _, def in ipairs(definitions) do
        -- Trial renderer APIs only exist in its separate branch. Presence of the
        -- exact managed menu command opts in; arbitrary menu text is not code.
        if not def[6] or menu_commands[def[4]] then
            local action = {id=def[1], group=def[2], label=def[3], command=def[4],
                focus_main=def[5] == true, default_keys={}}
            catalog.actions[#catalog.actions+1], catalog.by_id[action.id], catalog.by_command[action.command] = action, action, action
            catalog.command_sources[action.command] = {id=action.id, command=action.command, kind='exact'}
        end
    end
    for _, alias in ipairs(command_aliases) do
        local action = catalog.by_id[alias[2]]
        if action then
            catalog.by_command[alias[1]] = action
            catalog.command_sources[alias[1]] = {id=action.id, command=action.command, kind='equivalent'}
        end
    end
    local order = {}
    for line in (input .. '\n'):gmatch('(.-)\r?\n') do
        if not line:match('^%s*#') then
            local raw, command = line:match('^%s*(%S+)%s+(.+)$')
            if raw and raw ~= '_' then
                local key = M.normalize_key(raw)
                command = command:gsub('%s+#.*$', ''):gsub('%s+$', '')
                if key then
                    if not catalog.baseline[key] then order[#order+1] = key end
                    catalog.baseline[key] = command
                end
            end
        end
    end
    for _, key in ipairs(order) do
        local command = catalog.baseline[key]
        local action = catalog.by_command[command]
        if action then action.default_keys[#action.default_keys+1] = key
        elseif command ~= 'ignore' then catalog.foreign[key] = true end
    end
    return catalog
end

-- Validate JSON structure, but preserve unknown values as raw text when saving.
-- This avoids losing null, empty objects/arrays or future fields in Lua's tables.
local function utf8_valid(text)
    local i = 1
    while i <= #text do
        local a, b, c, d = text:byte(i, i+3)
        local count = 1
        if a < 128 then count = 1
        elseif a >= 194 and a <= 223 and b and b >= 128 and b <= 191 then count = 2
        elseif a >= 224 and a <= 239 and b and c and b >= 128 and b <= 191 and c >= 128 and c <= 191
            and (a ~= 224 or b >= 160) and (a ~= 237 or b <= 159) then count = 3
        elseif a >= 240 and a <= 244 and b and c and d and b >= 128 and b <= 191
            and c >= 128 and c <= 191 and d >= 128 and d <= 191
            and (a ~= 240 or b >= 144) and (a ~= 244 or b <= 143) then count = 4
        else return false end
        i = i + count
    end
    return true
end

function M.parse(raw, decode)
    if type(raw) ~= 'string' or #raw > M.max_bytes then return nil, '配置文件超过 256 KiB 限制' end
    if not utf8_valid(raw) then return nil, '配置文件不是有效 UTF-8' end
    local i = raw:sub(1,3) == '\239\187\191' and 4 or 1
    local function space() local _, last = raw:find('^[ \t\r\n]*', i); i = (last or i-1)+1 end
    local function fail() error('invalid-json', 0) end
    local function string_node()
        local first = i; i = i + 1
        while i <= #raw do
            local c = raw:byte(i)
            if c == 34 then
                i = i + 1
                local ok, value = pcall(decode, raw:sub(first, i-1))
                if not ok or type(value) ~= 'string' then fail() end
                return {kind='string', first=first, last=i-1, value=value}
            elseif c == 92 then
                local escape = raw:sub(i+1, i+1)
                if escape == 'u' then
                    local digits = raw:sub(i+2, i+5)
                    if #digits ~= 4 or not digits:match('^%x%x%x%x$') then fail() end
                    local unit = tonumber(digits, 16); i = i + 6
                    if unit >= 0xD800 and unit <= 0xDBFF then
                        local low = raw:sub(i+2, i+5)
                        if raw:sub(i,i+1) ~= '\\u' or not low:match('^%x%x%x%x$') then fail() end
                        local low_unit = tonumber(low,16)
                        if low_unit < 0xDC00 or low_unit > 0xDFFF then fail() end
                        i = i + 6
                    elseif unit >= 0xDC00 and unit <= 0xDFFF then fail() end
                elseif escape ~= '' and ('"\\/bfnrt'):find(escape,1,true) then i = i + 2
                else fail() end
            elseif c < 32 then fail()
            else i = i + 1 end
        end
        fail()
    end
    local value
    value = function(depth)
        if depth > 64 then fail() end
        space(); local first, c = i, raw:sub(i,i)
        if c == '"' then return string_node() end
        if c == '{' or c == '[' then
            local object = c == '{'
            local node = {kind=object and 'object' or 'array', first=first, members={}, values={}}
            local close = object and '}' or ']'; i = i + 1; space()
            if raw:sub(i,i) ~= close then
                while true do
                    local key, key_first
                    if object then
                        if raw:sub(i,i) ~= '"' then fail() end
                        key_first = i; key = string_node().value; space()
                        if node.values[key] or raw:sub(i,i) ~= ':' then fail() end
                        i = i + 1
                    end
                    local item = value(depth+1)
                    if object then
                        node.values[key] = item
                        node.members[#node.members+1] = {key=key, first=key_first, node=item}
                    else node.values[#node.values+1] = item end
                    space(); c = raw:sub(i,i)
                    if c == close then break end
                    if c ~= ',' then fail() end
                    i = i + 1; space()
                end
            end
            i = i + 1; node.last = i-1; return node
        end
        for _, literal in ipairs({'true','false','null'}) do
            if raw:sub(i,i+#literal-1) == literal then
                i = i + #literal; return {kind=literal, first=first, last=i-1}
            end
        end
        if c == '-' then i = i + 1 end
        c = raw:sub(i,i)
        if c == '0' then i = i + 1
        elseif c:match('^[1-9]$') then repeat i = i + 1 until not raw:sub(i,i):match('^%d$')
        else fail() end
        if raw:sub(i,i) == '.' then
            i = i + 1; if not raw:sub(i,i):match('^%d$') then fail() end
            repeat i = i + 1 until not raw:sub(i,i):match('^%d$')
        end
        c = raw:sub(i,i)
        if c == 'e' or c == 'E' then
            i = i + 1; c = raw:sub(i,i); if c == '+' or c == '-' then i = i + 1 end
            if not raw:sub(i,i):match('^%d$') then fail() end
            repeat i = i + 1 until not raw:sub(i,i):match('^%d$')
        end
        return {kind='number', first=first, last=i-1, value=tonumber(raw:sub(first,i-1))}
    end
    local ok, node = pcall(value, 0)
    if not ok then return nil, '配置文件不是有效 JSON（请检查编码、重复字段或格式）' end
    space(); if i <= #raw then return nil, '配置文件包含多余 JSON 内容' end
    return node
end

function M.document(raw, decode)
    if raw == '' then return {raw='', shortcuts={kind='object', members={}, values={}}} end
    local root, err = M.parse(raw, decode)
    if not root then return nil, err end
    if root.kind ~= 'object' then return nil, '用户配置必须是 JSON 对象' end
    local schema = root.values.schema
    if not schema or schema.kind ~= 'number' or schema.value ~= 1 then return nil, '不支持的用户配置 schema；未修改文件' end
    local shortcuts = root.values.shortcuts or {kind='object', members={}, values={}}
    if shortcuts.kind ~= 'object' then return nil, 'shortcuts 必须是 JSON 对象' end
    return {raw=raw, root=root, shortcuts=shortcuts}
end

function M.resolve(catalog, document)
    local result = {actions={}, by_key={}, forward_keys={}, opening_keys={}}
    local conflict
    for _, action in ipairs(catalog.actions) do
        local keys = copy(action.default_keys)
        local override = document.shortcuts.values[action.id]
        if override then
            if override.kind ~= 'array' or #override.values > 2 then return nil, action.label .. '：每个动作须为最多两个键的数组' end
            keys = {}
            for _, node in ipairs(override.values) do
                local key = node.kind == 'string' and M.normalize_key(node.value)
                if not key then return nil, action.label .. '：不支持的键名' end
                if reserved[key] then return nil, key .. ' 为窗口局部保留键' end
                if catalog.foreign[key] then return nil, key .. ' 已被 input.conf 中的其他动作占用' end
                keys[#keys+1] = key
            end
        end
        local item = {id=action.id, label=action.label, group=action.group, command=action.command,
            default_keys=copy(action.default_keys), keys=keys, focus_main=action.focus_main}
        result.actions[#result.actions+1] = item
        for _, key in ipairs(keys) do
            if result.by_key[key] then
                conflict = conflict or key .. ' 同时分配给“' .. result.by_key[key].label .. '”与“' .. action.label .. '”'
            else
                result.by_key[key] = item
                result.forward_keys[#result.forward_keys+1] = key
                if item.focus_main then result.opening_keys[#result.opening_keys+1] = key end
            end
        end
    end
    if conflict then return nil, conflict, {kind='mapping-conflict', actions=result.actions} end
    return result
end

local function same(a,b)
    if #a ~= #b then return false end
    for i, key in ipairs(a) do if b[i] ~= key then return false end end
    return true
end

function M.prepare(catalog, document, proposed, decode, encode, reset)
    local shortcuts = {kind='object', members={}, values={}}
    if not reset then
        local err; shortcuts, err = M.parse(proposed, decode)
        if not shortcuts then return nil, err end
        if shortcuts.kind ~= 'object' then return nil, '快捷键覆盖必须是 JSON 对象' end
        for id in pairs(shortcuts.values) do
            if not catalog.by_id[id] then return nil, '保存内容包含未知动作 ID' end
        end
    end
    local effective, err = M.resolve(catalog, {shortcuts=shortcuts})
    if not effective then return nil, err end
    local fields = {}
    for _, member in ipairs(document.shortcuts.members) do
        if not catalog.by_id[member.key] then fields[#fields+1] = document.raw:sub(member.first, member.node.last) end
    end
    for _, action in ipairs(effective.actions) do
        if not same(action.keys, action.default_keys) then
            local values = {}; for _, key in ipairs(action.keys) do values[#values+1] = encode(key) end
            fields[#fields+1] = encode(action.id) .. ':[' .. table.concat(values, ',') .. ']'
        end
    end
    local replacement = '{' .. table.concat(fields, ',') .. '}'
    local raw
    if document.raw == '' then raw = '{"schema":1,"shortcuts":' .. replacement .. '}'
    elseif document.root.values.shortcuts then
        local old = document.root.values.shortcuts
        raw = document.raw:sub(1,old.first-1) .. replacement .. document.raw:sub(old.last+1)
    else
        raw = document.raw:sub(1,document.root.last-1) .. (#document.root.members > 0 and ',' or '')
            .. '"shortcuts":' .. replacement .. document.raw:sub(document.root.last)
    end
    if #raw > M.max_bytes then return nil, '保存后的配置超过 256 KiB 限制' end
    return raw, effective
end

function M.plan(catalog, previous, next_mapping)
    local result, final = {}, {}
    -- Restore retired custom keys from the actual managed baseline, then derive
    -- the final default-section mapping. Local forced sections stay above it.
    if previous then
        for key in pairs(previous.by_key) do final[key] = catalog.baseline[key] or 'ignore' end
    end
    for _, action in ipairs(catalog.actions) do
        for _, key in ipairs(action.default_keys) do final[key] = 'ignore' end
    end
    for key, action in pairs(next_mapping.by_key) do final[key] = action.command end
    for key, command in pairs(final) do result[#result+1] = {key=key, command=command} end
    table.sort(result, function(a,b) return a.key < b.key end)
    return result
end

return M
