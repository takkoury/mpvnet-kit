# 配置说明

本文说明随包配置实际写入的值，以及当前脚本已提供的可调选项。操作说明见[功能与操作](features.md)，安装、更新和恢复见[安装](installation.md)。下面路径均相对于**播放器实际加载的配置目录**，例如 `C:\Apps\mpv.net\portable_config`；不要只改下载包里的文件而忘记实际配置。

“显式”表示发行包已经写入；“脚本默认”表示配置文件未写该项，脚本初始化时采用的值；“未指定”表示本包未设置播放器选项，实际值由播放器版本、启动参数、媒体或其他配置决定。本文不把未指定值猜作固定默认。

本页示例路径是通用示例，应换成自己机器上的路径。修改后保留自己的差异与备份；原始 manifest 只校验原发行文件。

快速定位：改输出目录与程序路径看第 3 节，调整界面看第 5 节，修改键位看第 6 节。

- [1. 配置文件与目录速查](#1-配置文件与目录速查)
- [2. 修改方法与生效规则](#2-修改方法与生效规则)
- [3. 本机路径与外部组件](#3-本机路径与外部组件)
- [4. 播放、音频、字幕与弹幕](#4-播放音频字幕与弹幕)
- [5. 界面外观与缩略图](#5-界面外观与缩略图)
- [6. 快捷键与鼠标动作](#6-快捷键与鼠标动作)
- [7. 截图、片段与播放列表](#7-截图片段与播放列表)
- [8. 增强与显示目标](#8-增强与显示目标)
- [9. 常用修改示例与个人维护](#9-常用修改示例与个人维护)

## 1. 配置文件与目录速查

| 文件或目录 | 负责内容 | 通常如何修改 |
| --- | --- | --- |
| [mpv.conf](../config/mpv.conf) | mpv 播放、渲染、OSD、目录队列 | 每行 `参数=值` |
| [mpvnet.conf](../config/mpvnet.conf) | mpv.net 宿主进程行为 | 每行 `参数=值` |
| [input.conf](../config/input.conf) | 键盘、视频区鼠标与禁用键 | 每行 `键 命令` |
| [modernz.conf](../config/script-opts/modernz.conf) | 控制栏外观、按钮、鼠标命令 | 不带 `modernz-` 前缀的选项名 |
| [thumbfast.conf](../config/script-opts/thumbfast.conf) | 缩略图子播放器 | 不带脚本前缀的选项名 |
| [bilibiliAssert.conf](../config/script-opts/bilibiliAssert.conf) | 弹幕显示与转换器 | 注意大小写和文件名 |
| [enhancement-controls.conf](../config/script-opts/enhancement-controls.conf) | Anime4K 档可用开关 | 当前只有 `anime_verified` |
| [mpvnet-local.conf.example](../config/script-opts/mpvnet-local.conf.example) | 本机目录、程序路径模板 | 从包内复制到实际配置目录的 `script-opts/mpvnet-local.conf` 后填写 |
| `scripts/`、`script-modules/` | Lua 实现 | 查默认值与实现边界，不是一般用户配置入口 |
| `helpers/` | Windows PowerShell 窗口、截图与导出实现 | 内部调用接口，不作为用户配置文件 |
| `shaders/anime4k/`、`fonts/` | 随包着色器与图标字体 | 保持目录结构和许可 |

公开仓库中的 `config/` 内容由安装工具放入实际配置目录，因此本文的 `script-opts/...` 对应公开包 `config/script-opts/...`。example 仅随包提供，安装工具不会部署它；真实本机 `mpvnet-local.conf` 需要自行创建，不在原包受管清单中。

## 2. 修改方法与生效规则

1. 先关闭自己的播放器实例，备份要改的文件。
2. 用文本编辑器编辑实际配置目录；保存为 UTF-8，每行一项，`#` 开头为注释。
3. 一次修改一个模块，重开播放器，用一个已知本地媒体观察结果。
4. 无效时核对文件位置、参数拼写、启动参数与日志，恢复备份后再继续。

为避免混淆，下文脚本表统一以**重启播放器**为文件修改的生效时机。多数脚本在初始化时 `read_options`；ModernZ 虽有选项更新回调，直接保存文件不等于它自动监视并重读磁盘。Ctrl+R 重新加载媒体也不等于重新加载脚本配置。

播放器选项可以在命令行、配置及运行时被覆盖；运行时菜单、键位或控制台改变属性通常只影响当前实例。脚本还会主动写入部分属性，不能假定删除一行即可恢复全部行为。例如 playback-feedback 启动时会再次关闭 `input-default-bindings`、清空 `osd-playing-msg`。

下面可用 `--参数=值` 做一次启动测试；它不是永久保存。需要持久值时写入相应文件。不同播放器版本的 mpv 选项以[官方手册](https://mpv.io/manual/stable/)为准；mpv.net 宿主选项以[mpv.net 文档](https://github.com/mpvnet-player/mpv.net/blob/main/docs/manual.md)为准，不能将两者任意互换。

脚本配置的布尔值使用 `yes` / `no`。表中数字例子是保守起点；除明确标出的边界外，不表示脚本验证了所有数值范围。字符串不应包上额外命令参数；路径选项只填路径。

默认图形安装器用于干净安装，可保留播放器状态和缓存，但不覆盖已有配置，也不自动更新或恢复；目录识别与保留条件见[安装指南](installation.md)。高级命令行安装/恢复工具另有逐文件哈希保护：修改 `mpv.conf`、`input.conf` 或脚本配置后，继续部署可能因差异拒绝；先保存自己的改动，再决定怎样合并。真实 `mpvnet-local.conf` 属于个人配置。

## 3. 本机路径与外部组件

| 参数 | 作用 | 当前默认与来源 | 可选值或边界 | 修改示例 |
| --- | --- | --- | --- | --- |
| `capture_root` | 截图和片段根目录 | 空值；example 模板 | 空值使用 Windows Pictures KnownFolder 下 Capture；非空为绝对目录 | `capture_root=D:\Media\Capture` |
| `ffmpeg_path` | 片段导出的 FFmpeg | 空值；example 模板 | 空值检查 PATH；非空为可执行文件绝对路径，不能附参数 | `ffmpeg_path=C:\Apps\FFmpeg\bin\ffmpeg.exe` |
| `python_path` | 弹幕转换用 Python | 空值；example 模板 | 空值沿用 bilibiliAssert 的 python_path；非空优先 | `python_path=C:\Apps\Python\python.exe` |
| `mpv_path` | 缩略图使用的播放器 | 空值；example 模板 | 非空优先于 thumbfast 选项；须为可执行文件路径 | `mpv_path=C:\Apps\mpv.net\mpvnet.exe` |

以上参数写入 `script-opts/mpvnet-local.conf`；生效时机：重启播放器。

本机路径非空时覆盖组件原选项，清空或删除该项恢复组件回退逻辑。请使用绝对路径；本机值一旦非空就优先使用，错误路径不会自动跳过并回退到另一份配置。`capture_root` 与 `ffmpeg_path` 支持盘符根路径或 UNC 路径；Python 路径仅在 `use_python=yes` 时使用。

路径含空格仍作为路径数据填写，不添加 `--...`、引号命令串或 PowerShell 表达式。

缩略图的回退顺序是：本机 `mpv_path` → thumbfast 非空且非 `mpv` 的显式路径 → frontend 提供的进程路径 → 当前播放器自身 PID 的可执行文件 → portable 配置父目录的 `mpvnet.exe` → 原值。发现发生在初始化阶段，不会持续扫描其他播放器进程。

PowerShell 从 `SystemRoot` / `WINDIR` 定位系统 Windows PowerShell，没有对应的本机可调字段。FFmpeg 只在片段导出时检查；源 PNG 和打开 Capture 目录不依赖 FFmpeg。弹幕需要 Python 能运行随包转换脚本，并能访问对应弹幕数据；网页入口由用户自己的浏览器和外部调用组件提供，本包没有 Cookie 配置入口。

当前兼容实现仅开放 Python 转换：`use_python=no` 会提示 `DANMAKU LOAD FAILED` 并停止该次转换。源码保留的旧 EXE 调用分支不会被这个开关启用；请保持 `use_python=yes`。

## 4. 播放、音频、字幕与弹幕

### 播放器显式配置

| 参数 | 作用 | 当前默认与来源 | 可选值或边界 | 修改示例 |
| --- | --- | --- | --- | --- |
| `osc` | 关闭 mpv 内置控制栏，使用 ModernZ | 显式 `no` | yes/no；本实现由 ModernZ 初始化再次强制 no，单改此行不能启用内置栏 | `osc=no` |
| `title-bar` | 原生窗口标题栏 | 显式 `no` | yes/no；宿主和无边框模式共同影响表现 | `title-bar=no` |
| `osd-align-x` | 文本反馈横向位置 | 显式 `left` | left/center/right | `osd-align-x=left` |
| `osd-align-y` | 文本反馈纵向位置 | 显式 `top` | top/center/bottom | `osd-align-y=top` |
| `osd-duration` | 播放器 OSD 默认持续毫秒数 | 显式 `1000` | 数值；脚本显式时长会另行覆盖 | `osd-duration=1500` |
| `osd-bar` | 音量/seek 等原生 OSD 条 | 显式 `no` | yes/no；不控制 ModernZ 控件 | `osd-bar=no` |
| `osd-on-seek` | 原生 seek 提示 | 显式 `no` | 采用官方选项值；脚本仍有自己的反馈 | `osd-on-seek=no` |
| `osd-playing-msg` | 加载媒体时的文字 | 显式空值；脚本也强制清空 | 本实现会覆盖此配置；不要依赖此项自定义开场信息 | `osd-playing-msg=` |
| `input-default-bindings` | mpv 默认绑定 | 显式 `no`；脚本再次强制关闭 | yes/no；本实现不能只改成 yes 恢复默认键 | `input-default-bindings=no` |
| `autocreate-playlist` | 从当前目录创建同类队列 | 显式 `same` | no/filter/same；具体支持依播放器版本 | `autocreate-playlist=same` |
| `directory-filter-types` | 目录队列文件类别 | 显式 `video,audio` | 播放器支持的类型列表；按手册检查 | `directory-filter-types=video,audio` |
| `directory-mode` | 如何处理目录条目 | 显式 `ignore` | auto/lazy/recursive/ignore；按版本手册检查 | `directory-mode=ignore` |
| `vo` | 渲染输出优先列表 | 显式 `gpu-next,gpu` | 逗号分隔驱动列表，首项不可用才回退；非强制单一驱动 | `vo=gpu-next,gpu` |
| `hwdec` | 主播放器硬件解码 | 显式 `auto-safe` | `auto-safe` 沿用随包策略，`no` 关闭硬解；其他后端见对应版本手册 | `hwdec=auto-safe` |
| `target-trc` | 渲染目标传递曲线 | 显式 `auto` | 可按实际显示链路选 srgb；不是 ICC 校准 | `target-trc=auto` |

以上参数写入 `mpv.conf`；生效时机：重启播放器。

| 参数 | 作用 | 当前默认与来源 | 可选值或边界 | 修改示例 |
| --- | --- | --- | --- | --- |
| `process-instance` | 每次新启动的实例模式 | 显式 `multi` | multi/single/queue；新实例/复用实例/复用实例并追加队列 | `process-instance=multi` |

以上参数写入 `mpvnet.conf`；生效时机：重启播放器。宿主模式说明见[官方 process-instance 文档](https://github.com/mpvnet-player/mpv.net/blob/main/docs/manual.md#--process-instancevalue)。

### 音频与普通字幕的可选追加项

以下项目**本包未指定**；表中是可以追加的示例，不能读成发行包默认。实际默认和完整合法值请查看播放器对应版本手册；外部调用也可能传入音轨或字幕选项。

| 参数 | 作用 | 当前默认与来源 | 可选值或边界 | 修改示例 |
| --- | --- | --- | --- | --- |
| `volume` | 初始音量 | 未指定 | 百分比；100 是示例，超过 100 需核播放器音量上限 | `volume=80` |
| `mute` | 初始静音 | 未指定 | yes/no | `mute=no` |
| `audio-delay` | 音频相对视频的延迟 | 未指定 | 秒；正值延迟音频，负值提前 | `audio-delay=0.1` |
| `alang` | 音轨语言偏好 | 未指定 | 逗号分隔语言偏好；匹配受媒体语言标记影响 | `alang=ja,en` |
| `slang` | 字幕语言偏好 | 未指定 | 逗号分隔语言偏好；不能保证文件含相应字幕 | `slang=zh,ja,en` |
| `sub-visibility` | 普通字幕显示开关 | 未指定 | yes/no；按钮会运行时切换 | `sub-visibility=yes` |
| `sub-delay` | 普通字幕延迟 | 未指定 | 秒；运行时 Alt+方向键可改变 | `sub-delay=0.1` |
| `sub-pos` | 普通字幕位置 | 未指定 | mpv 接受 0–150；本项目调整模式限制 0–100，超过 100 可能裁切字幕 | `sub-pos=90` |
| `sub-scale` | 普通字幕缩放 | 未指定 | 正数倍数；字幕格式及 ASS 样式影响结果 | `sub-scale=1.1` |
| `sub-font` | 文本字幕字体 | 未指定 | 已安装字体名；ASS 自带样式可能优先 | `sub-font=sans-serif` |

以上参数写入 `mpv.conf`；生效时机：重启播放器。

常用音频与字幕选项的完整定义见 [mpv 音频选项](https://mpv.io/manual/stable/#audio)和[字幕选项](https://mpv.io/manual/stable/#subtitles)。

普通字幕脚本管理主字幕，弹幕组件使用次字幕槽并保留原主字幕。已有次字幕时，弹幕会提示占用，而不是强行替换。不要把弹幕字体选项写成普通字幕字体选项。

字幕调整模式的延迟步长 0.1 秒、位置步长 1、缩放步长 0.05 是源码常量；没有 `subtitle-controls.conf` 的现成配置接口。字幕是否遵从字体/位置设置取决于格式，修改这些选项不等于强制改写 ASS 样式。

### 弹幕组件

下面除 `fps_vf` 与 `python_path` 为显式值，其余均来自当前 Lua 初始化默认（指本地随包源码，不是对所有上游版本的声明）；它们都可写入同一配置文件。修改显示选项后重启，再重新生成/加载弹幕，已生成 ASS 不会因保存配置自动重排。

| 参数 | 作用 | 当前默认与来源 | 可选值或边界 | 修改示例 |
| --- | --- | --- | --- | --- |
| `autoplay` | 符合条件时自动显示弹幕 | 脚本默认 `yes` | yes/no；仅在已识别弹幕数据时有效 | `autoplay=no` |
| `mincount` | 自动显示所需最低估计数量 | 脚本默认 `1` | 建议非负整数；不是每秒密度上限 | `mincount=10` |
| `fontname` | 弹幕字体 | 脚本默认 `sans-serif` | 已安装字体名 | `fontname=sans-serif` |
| `fontsize` | 弹幕字体大小 | 脚本默认 `50` | 正数；转换器按 ASS 尺寸使用，非 GUI 缩放百分比 | `fontsize=40` |
| `opacity` | 弹幕不透明度 | 脚本默认 `0.95` | 0–1；转换器没有完整范围保护 | `opacity=0.8` |
| `duration_marquee` | 滚动弹幕显示时长 | 脚本默认 `10` | 正数秒；增大通常滚动更慢 | `duration_marquee=12` |
| `duration_still` | 静止弹幕显示时长 | 脚本默认 `5` | 正数秒 | `duration_still=4` |
| `percent` | 底部保留空白比例 | 脚本默认 `0.75` | 0–1；源码传 floor(percent × 视频高度)，不是弹幕占屏比例 | `percent=0.5` |
| `filter_file` | 弹幕过滤词文件 | 脚本默认空 | 支持相对/绝对路径并经 expand-path；文件内容由转换器按正则读取 | `filter_file=D:\Media\danmaku-filter.txt` |
| `fps_vf` | 低帧率时添加 fps 滤镜 | 显式 `no`；脚本默认也为 no | yes/no；会改变播放滤镜，默认保留原帧率 | `fps_vf=no` |
| `log_osd` | 弹幕组件日志显示到 OSD | 脚本默认 `no` | yes/no | `log_osd=yes` |
| `use_python` | 选择 Python 转换器 | 脚本默认 `yes` | 保持 yes；当前兼容实现会拒绝 no | `use_python=yes` |
| `python_path` | 组件 Python 路径 | 显式 `python`；脚本默认相同 | PATH 名或可执行文件路径；本机配置非空时覆盖 | `python_path=C:\Apps\Python\python.exe` |

以上参数写入 `script-opts/bilibiliAssert.conf`；生效时机：重启播放器。

## 5. 界面外观与缩略图

### ModernZ 的布局、文字与可见性

下面“脚本默认”均可追加到现有 modernz.conf。优先调整 default 布局；定制增强入口和格式选择按当前布局实现，改成其他布局后需实际确认按钮是否仍在预期位置。

| 参数 | 作用 | 当前默认与来源 | 可选值或边界 | 修改示例 |
| --- | --- | --- | --- | --- |
| `layout` | 布局 | 显式 `default` | default/compact/mini/seekbar | `layout=default` |
| `icon_theme` | 图标主题 | 脚本默认 `fluent` | fluent/material | `icon_theme=material` |
| `icon_style` | 图标风格 | 脚本默认 `mixed` | mixed/filled/outline | `icon_style=outline` |
| `font` | 控制栏文字字体 | 脚本默认 `mpv-osd-symbols` | 字体名；图标另用 modernz-icons | `font=sans-serif` |
| `window_top_bar` | 窗口顶部控制栏 | 脚本默认 `auto` | auto/yes/no | `window_top_bar=auto` |
| `showwindowed` | 窗口模式显示控制栏 | 脚本默认 `yes` | yes/no | `showwindowed=yes` |
| `showfullscreen` | 全屏显示控制栏 | 脚本默认 `yes` | yes/no | `showfullscreen=yes` |
| `showonpause` | 暂停时唤出控制栏 | 脚本默认 `yes` | yes/no | `showonpause=yes` |
| `keeponpause` | 暂停期间保持显示 | 脚本默认 `no` | no/bottombar/both | `keeponpause=bottombar` |
| `hidetimeout` | 无鼠标活动后的隐藏等待 | 脚本默认 `1500` | 毫秒；保守用非负值 | `hidetimeout=2500` |
| `keep_with_cursor` | 指针在栏内时保持可见 | 脚本默认 `yes` | yes/no | `keep_with_cursor=yes` |
| `fadeduration` | 淡出时长 | 脚本默认 `200` | 毫秒；0 关闭淡出 | `fadeduration=100` |
| `fadein` | 淡入效果 | 脚本默认 `yes` | yes/no | `fadein=no` |
| `deadzonesize` | 顶部控件及其他布局的唤出死区 | 脚本默认 `0.75` | 0–1；越大触发区域越靠近控件；default 下方区域不受它控制 | `deadzonesize=0.75` |
| `deadzone_hide` | 进入死区的隐藏行为 | 脚本默认 `instant` | instant/timeout | `deadzone_hide=timeout` |
| `osc_on_seek` | seek 时显示控制栏 | 脚本默认 `yes` | yes/no | `osc_on_seek=no` |
| `osc_on_start` | 开始媒体时显示位置 | 脚本默认 `both` | no/bottom/top/both | `osc_on_start=bottom` |
| `mouse_seek_pause` | 拖动 seek 时暂停 | 脚本默认 `yes` | yes/no | `mouse_seek_pause=yes` |
| `vidscale` | 控制栏随视频缩放 | 脚本默认 `auto` | auto/yes/no；自动决定/随视频缩放/按窗口缩放 | `vidscale=auto` |
| `scalewindowed` | 窗口控制栏尺寸倍率 | 脚本默认 `1.0` | 正数；先小幅调整，避免超出窗口 | `scalewindowed=1.1` |
| `scalefullscreen` | 全屏控制栏尺寸倍率 | 脚本默认 `1.0` | 正数 | `scalefullscreen=1.1` |
| `show_title` | 显示媒体标题 | 脚本默认 `yes` | yes/no | `show_title=yes` |
| `title` | 标题内容模板 | 显式 `${filename}`；脚本默认 `${media-title}` | mpv 属性展开字符串 | `title=${media-title}` |
| `truncate_title` | 超长标题省略 | 显式 `yes`；脚本默认 no | yes/no | `truncate_title=yes` |
| `show_chapter_title` | 显示章节标题 | 显式 `no`；脚本默认 yes | yes/no | `show_chapter_title=yes` |
| `chapter_fmt` | 进度条悬停时的章节文字格式 | 脚本默认 `%s` | 格式字符串；no 关闭悬停章节名 | `chapter_fmt=no` |
| `time_format` | 时间格式 | 显式 `dynamic`；脚本默认相同 | dynamic/fixed | `time_format=fixed` |
| `timecurrent` | 显示当前时间而非剩余时间 | 显式 `yes`；脚本默认相同 | yes/no | `timecurrent=no` |
| `timems` | 显示毫秒 | 脚本默认 `no` | yes/no | `timems=yes` |
| `title_font_size` | 标题字号 | 脚本默认 `24` | 正数；布局坐标单位 | `title_font_size=22` |
| `chapter_title_font_size` | 章节字号 | 脚本默认 `16` | 正数；需开启 show_chapter_title 且媒体有章节 | `chapter_title_font_size=14` |
| `time_font_size` | 时间字号 | 脚本默认 `16` | 正数 | `time_font_size=18` |
| `tooltip_font_size` | 提示字号 | 脚本默认 `14` | 正数 | `tooltip_font_size=16` |
| `speed_font_size` | 速度字号 | 显式 `14`；脚本默认 16 | 正数 | `speed_font_size=16` |
| `sub_margins` | 显示控制栏时抬高字幕 | 脚本默认 `yes` | yes/no；字幕自身定位仍有影响 | `sub_margins=no` |
| `osd_margins` | 为 OSD 留控制栏空间 | 脚本默认 `no` | yes/no | `osd_margins=yes` |
| `dynamic_margins` | 随控制栏可见状态更新留白 | 脚本默认 `yes` | yes/no | `dynamic_margins=yes` |
| `visibility` | 初始化可见模式 | 脚本默认 `auto` | never/auto/always；Alt+O 为实例内切换 | `visibility=auto` |
| `persistent_progress` | 始终显示底部进度线 | 脚本默认 `no` | yes/no | `persistent_progress=yes` |
| `persistent_progress_height` | 常驻进度线高度 | 脚本默认 `17` | 数值；先启用 persistent_progress 才会显示 | `persistent_progress_height=10` |
| `seekbar_height` | 进度条尺寸档 | 脚本默认 `medium` | small/medium/large/xlarge | `seekbar_height=large` |
| `seekbarkeyframes` | 拖动时使用关键帧 seek | 脚本默认 `yes` | yes/no；自动模式会按媒体时长覆写此项，单独改它不保证生效 | `seekbarkeyframes=no` |
| `automatickeyframemode` | 根据时长启用关键帧模式 | 脚本默认 `yes` | yes/no | `automatickeyframemode=no` |
| `automatickeyframelimit` | 自动关键帧模式时长门槛 | 脚本默认 `600` | 秒；非负数作为保守设置 | `automatickeyframelimit=1200` |
| `seek_handle_size` | 进度手柄比例 | 脚本默认 `0.8` | 源码注释 0–1 | `seek_handle_size=0.7` |

以上参数写入 `script-opts/modernz.conf`；生效时机：重启播放器。

`show_chapter_title` 控制栏内章节标题，`chapter_fmt` 控制进度条悬停章节名，进度条标记另由 `nibble_color` 等选项控制。关闭栏内标题不会同时关闭后两者。

当前 `default` 布局的下方唤出区域固定在画面下半部，修改 `deadzonesize` 不会调整这个区域；该参数仍影响顶部窗口控件，其他布局也用它计算下方触发区域。源码还保留 `hide_volume_bar_trigger=1150` 的选项声明，但当前实现没有读取它作为隐藏阈值，追加该项不会改变音量条行为。

### 按钮开关与外观色彩

| 参数 | 作用 | 当前默认与来源 | 可选值或边界 | 修改示例 |
| --- | --- | --- | --- | --- |
| `audio_tracks_button` | 其他布局中的独立音轨按钮 | 显式 `no`；脚本默认 yes | yes/no；default 本身没有此按钮 | `audio_tracks_button=no` |
| `fullscreen_button` | 其他布局中的独立全屏按钮 | 显式 `no`；脚本默认 yes | yes/no；default 本身没有此按钮 | `fullscreen_button=no` |
| `loop_button` | 保留的循环按钮字段 | 显式 `no`；脚本默认 yes | 当前源码未消费此开关，修改无效果 | `loop_button=no` |
| `download_button` | 下载按钮 | 显式 `no`；脚本默认 yes | yes/no | `download_button=no` |
| `enhancement_button` | 增强按钮 | 显式 `yes`；脚本默认 yes | yes/no | `enhancement_button=yes` |
| `subtitles_button` | 字幕按钮 | 脚本默认 `yes` | yes/no | `subtitles_button=yes` |
| `track_nextprev_buttons` | 前后媒体按钮 | 脚本默认 `yes` | yes/no | `track_nextprev_buttons=yes` |
| `playlist_button` | Playlist 按钮 | 脚本默认 `yes` | yes/no | `playlist_button=yes` |
| `screenshot_button` | 截图按钮 | 脚本默认 `yes` | yes/no | `screenshot_button=yes` |
| `speed_button` | 速度按钮 | 脚本默认 `yes` | yes/no | `speed_button=yes` |
| `info_button` | 媒体信息按钮 | 脚本默认 `yes` | yes/no | `info_button=yes` |
| `ontop_button` | 置顶按钮 | 脚本默认 `yes` | yes/no | `ontop_button=yes` |
| `jump_buttons` | 前后 seek 按钮 | 脚本默认 `yes` | yes/no | `jump_buttons=yes` |
| `chapter_skip_buttons` | 章节前后按钮 | 脚本默认 `no` | yes/no | `chapter_skip_buttons=no` |
| `volume_control` | 音量控件 | 脚本默认 `yes` | yes/no | `volume_control=yes` |

以上参数写入 `script-opts/modernz.conf`；生效时机：重启播放器。

有效的按钮开关控制对应布局中的控件，键盘动作独立保留。当前 default 布局没有独立音轨/全屏按钮；选音轨可用音量图标中键，全屏可用 Enter/视频区双击。`loop_button` 只是未被当前布局消费的保留字段；键盘 A/B 与文件循环仍按快捷绑定执行。

`download_button=no` 保持本版不提供完整视频下载的范围。源码虽保留上游下载按钮选项，改成 yes 也需要上游依赖与行为检查；本文不把它作为已交付的新下载能力。

| 参数 | 作用 | 当前默认与来源 | 可选值或边界 | 修改示例 |
| --- | --- | --- | --- | --- |
| `seekbarfg_color` | 已播放进度 | 显式 `#1287bb`；脚本默认 `#FF8232` | #RRGGBB | `seekbarfg_color=#1287bb` |
| `seek_handle_color` | 进度手柄 | 显式 `#1287bb`；脚本默认 `#C96508` | #RRGGBB | `seek_handle_color=#1287bb` |
| `seek_handle_border_color` | 手柄内边框 | 显式 `#1287bb`；脚本默认 `#FF8232` | #RRGGBB；disable 关闭边框 | `seek_handle_border_color=#1287bb` |
| `hover_effect_color` | 悬停颜色 | 显式 `#1287bb`；脚本默认 `#FF8232` | #RRGGBB | `hover_effect_color=#1287bb` |
| `held_element_color` | 按下颜色 | 显式 `#1287bb`；脚本默认 `#999999` | #RRGGBB | `held_element_color=#1287bb` |
| `nibble_color` | 章节标记 | 显式 `#1287bb`；脚本默认 `#FF8232` | #RRGGBB | `nibble_color=#1287bb` |
| `ab_loop_color` | A/B范围 | 显式 `#1287bb`；脚本默认 `#2596be` | #RRGGBB | `ab_loop_color=#1287bb` |
| `windowcontrols_max_hover` | 最大化悬停 | 显式 `#1287bb`；脚本默认 `#F8BC3A` | #RRGGBB | `windowcontrols_max_hover=#1287bb` |
| `windowcontrols_min_hover` | 最小化悬停 | 显式 `#1287bb`；脚本默认 `#43CB44` | #RRGGBB | `windowcontrols_min_hover=#1287bb` |
| `windowcontrols_close_hover` | 关闭悬停 | 显式 `#1287bb`；脚本默认 `#F45C5B` | #RRGGBB | `windowcontrols_close_hover=#1287bb` |
| `volumebar_match_seek_color` | compact/mini 音量条沿用进度颜色 | 显式 `yes`；脚本默认 no | yes/no；不控制 default 音量悬停浮层 | `volumebar_match_seek_color=yes` |
| `seekbarbg_color` | 未播放进度颜色 | 脚本默认 `#999999` | #RRGGBB | `seekbarbg_color=#777777` |
| `title_color` | 标题颜色 | 脚本默认 `#FFFFFF` | #RRGGBB | `title_color=#FFFFFF` |
| `side_buttons_color` | 侧边图标颜色 | 脚本默认 `#FFFFFF` | #RRGGBB | `side_buttons_color=#FFFFFF` |
| `hover_effect` | 悬停效果组合 | 脚本默认 `size,glow,color,box` | 逗号分隔 size/glow/color/box | `hover_effect=color,box` |
| `tooltip_hints` | 按钮提示 | 脚本默认 `yes` | yes/no；seek/音量提示仍会显示 | `tooltip_hints=yes` |
| `osc_height` | 底栏高度 | 脚本默认 `60` | 数值；没有统一安全范围，布局需实际观察 | `osc_height=65` |

以上参数写入 `script-opts/modernz.conf`；生效时机：重启播放器。

### thumbfast 缩略图

`network=no` 是发行包显式策略：本地视频生成缩略图，网络媒体仍可显示时间/章节提示。它与主播放器硬件解码是两套选项。

| 参数 | 作用 | 当前默认与来源 | 可选值或边界 | 修改示例 |
| --- | --- | --- | --- | --- |
| `network` | 网络媒体生成缩略图 | 显式 `no`；脚本默认相同 | yes/no；开启会产生额外网络读取 | `network=no` |
| `mpv_path` | 缩略图播放器路径 | 显式 `mpv`；脚本默认相同 | 非默认路径优先自动探测；本机配置优先级更高 | `mpv_path=C:\Apps\mpv.net\mpvnet.exe` |
| `max_width` | 生成图像最大宽度 | 脚本默认 `200` | 正整数像素；高 DPI 下会缩放；保持宽高配套 | `max_width=300` |
| `max_height` | 生成图像最大高度 | 脚本默认 `200` | 正整数像素；按比例适配 | `max_height=200` |
| `scale_factor` | 显示缩放倍率 | 脚本默认 `1` | 脚本向下取整；用正整数，要求 mpv 0.38+；放大不增加细节 | `scale_factor=1` |
| `tone_mapping` | 缩略图色调映射 | 脚本默认 `auto` | auto/no；源码识别 none/clip/linear/gamma/reinhard/hable/mobius，未知映射回退 hable | `tone_mapping=auto` |
| `spawn_first` | 媒体加载即启动缩略图进程 | 脚本默认 `no` | yes/no；更快首次预览但提前用资源 | `spawn_first=yes` |
| `quit_after_inactivity` | 空闲后退出缩略图进程 | 脚本默认 `0` | 秒；0 禁用，正数启用 | `quit_after_inactivity=30` |
| `audio` | 音频媒体启用缩略图 | 脚本默认 `no` | yes/no；需存在可显示图像 | `audio=no` |
| `hwdec` | 缩略图子进程硬件解码 | 脚本默认 `no` | yes/no；需真实驱动验证 | `hwdec=no` |
| `direct_io` | Windows 原生管道写入 | 脚本默认 `no` | yes/no；需 LuaJIT，缺 ffi 会回退 | `direct_io=no` |
| `overlay_id` | 覆盖层 ID | 脚本默认 `42` | 整数；避免与其他脚本覆盖层冲突 | `overlay_id=42` |
| `socket` | 子进程 IPC 路径 | 脚本默认空 | 空值自动生成；手填可能造成多实例冲突，通常保留空 | `socket=` |
| `thumbnail` | 缩略图临时文件路径 | 脚本默认空 | 空值自动生成；不是截图输出路径，通常保留空 | `thumbnail=` |

以上参数写入 `script-opts/thumbfast.conf`；生效时机：重启播放器。

## 6. 快捷键与鼠标动作

### input.conf

完整绑定及已禁用的宿主键位以 [input.conf](../config/input.conf) 为准，日常速查见[功能与操作](features.md#全部40个全局键盘映射)。每行左边是键名，右边是命令，**没有等号**。以下是修改真实现有绑定的例子。

| 绑定项 | 当前默认/作用 | 可选形式与边界 | 修改示例 |
| --- | --- | --- | --- |
| `Space` | playback_feedback/space，短按暂停、长按加速 | 重绑现有脚本动作；若直接 cycle pause 会失去长按逻辑 | `Space script-binding playback_feedback/space` |
| `Left` / `Right` | 固定后退/前进 3 秒 | 可直接改 seek 命令，但会绕开脚本反馈 | `Right no-osd seek 5 relative+exact` |
| `Shift+Left` / `Shift+Right` | 固定后退/前进 1 秒 | 修改对应行，不改变脚本常量 | `Shift+Right no-osd seek 2 relative+exact` |
| `Ctrl+Left` / `Ctrl+Right` | 固定后退/前进 10 秒 | 修改对应行 | `Ctrl+Right no-osd seek 15 relative+exact` |
| `d` | bilibiliAssert/toggle | 已有弹幕开关动作，可绑定另一键 | `d script-binding bilibiliAssert/toggle` |
| `p` | playlist_controls/toggle | 显示/隐藏独立队列窗 | `p script-binding playlist_controls/toggle` |
| `MBTN_LEFT_DBL` | modernz/fullscreen-video-double-click | 只对视频区双击按组件处理 | `MBTN_LEFT_DBL script-binding modernz/fullscreen-video-double-click` |
| 任一 `ignore` 行 | 明确屏蔽该播放器键 | 改为已存在命令或保留 ignore；注意宿主注入键 | `F11 script-binding playback_feedback/fullscreen` |

修改 input.conf 后重启播放器。字母大小写有区别：`m` 是保存标记，`M` 是 Shift+M 跳回标记。不要把文档显示的大写键名全部照抄成配置大写。

独立 Playlist 的按键转发有自己的映射与焦点规则；任意改 input.conf 不保证侧窗同步得到同样行为。搜索文本框中的文字编辑、Ctrl+F、Escape 和 Delete 有专用处理，不应拿播放器绑定推断所有焦点下的结果。

### ModernZ 鼠标命令

下表覆盖发行包中全部显式鼠标命令。文件为 `script-opts/modernz.conf`，生效时机为重启播放器；合法值是播放器命令字符串或现有 `script-binding` / `script-message-to`，`ignore` 表示无动作。每行修改例子可直接写成 `参数名=命令`。脚本名称和动作名必须与实际实现一致。

| 参数 | 当前显式命令 | 作用与修改示例 |
| --- | --- | --- |
| `seekbar_wheel_up_command` | `script-message-to playback_feedback seek -10 relative+exact` | 进度条；例如 `seekbar_wheel_up_command=ignore` 可禁用该动作 |
| `seekbar_wheel_down_command` | `script-message-to playback_feedback seek 10 relative+exact` | 进度条；例如 `seekbar_wheel_down_command=ignore` 可禁用该动作 |
| `sub_track_mbtn_left_command` | `script-binding subtitle_controls/toggle` | 字幕按钮；例如 `sub_track_mbtn_left_command=ignore` 可禁用该动作 |
| `sub_track_mbtn_right_command` | `script-binding subtitle_controls/select` | 字幕按钮；例如 `sub_track_mbtn_right_command=ignore` 可禁用该动作 |
| `sub_track_mbtn_mid_command` | `ignore` | 字幕按钮；例如 `sub_track_mbtn_mid_command=ignore` 可禁用该动作 |
| `sub_track_wheel_up_command` | `ignore` | 字幕按钮；例如 `sub_track_wheel_up_command=ignore` 可禁用该动作 |
| `sub_track_wheel_down_command` | `ignore` | 字幕按钮；例如 `sub_track_wheel_down_command=ignore` 可禁用该动作 |
| `speed_mbtn_left_command` | `ignore` | 速度按钮；例如 `speed_mbtn_left_command=ignore` 可禁用该动作 |
| `speed_mbtn_right_command` | `script-message-to playback_feedback set-speed 1` | 速度按钮；例如 `speed_mbtn_right_command=ignore` 可禁用该动作 |
| `speed_wheel_down_command` | `script-message-to playback_feedback add-speed -0.25` | 速度按钮；例如 `speed_wheel_down_command=ignore` 可禁用该动作 |
| `speed_wheel_up_command` | `script-message-to playback_feedback add-speed 0.25` | 速度按钮；例如 `speed_wheel_up_command=ignore` 可禁用该动作 |
| `play_pause_mbtn_left_command` | `script-binding playback_feedback/toggle-pause` | 播放按钮；例如 `play_pause_mbtn_left_command=ignore` 可禁用该动作 |
| `play_pause_mbtn_right_command` | `ignore` | 播放按钮；例如 `play_pause_mbtn_right_command=ignore` 可禁用该动作 |
| `play_pause_mbtn_mid_command` | `ignore` | 播放按钮；例如 `play_pause_mbtn_mid_command=ignore` 可禁用该动作 |
| `title_mbtn_left_command` | `script-binding playback_feedback/copy-media-path` | 标题；例如 `title_mbtn_left_command=ignore` 可禁用该动作 |
| `title_mbtn_right_command` | `script-binding playback_feedback/open-media-path` | 标题；例如 `title_mbtn_right_command=ignore` 可禁用该动作 |
| `title_mbtn_mid_command` | `ignore` | 标题；例如 `title_mbtn_mid_command=ignore` 可禁用该动作 |
| `playlist_prev_mbtn_left_command` | `script-binding playlist_controls/previous` | 上一个媒体；例如 `playlist_prev_mbtn_left_command=ignore` 可禁用该动作 |
| `playlist_prev_mbtn_right_command` | `ignore` | 上一个媒体；例如 `playlist_prev_mbtn_right_command=ignore` 可禁用该动作 |
| `playlist_prev_mbtn_mid_command` | `ignore` | 上一个媒体；例如 `playlist_prev_mbtn_mid_command=ignore` 可禁用该动作 |
| `playlist_next_mbtn_left_command` | `script-binding playlist_controls/next` | 下一个媒体；例如 `playlist_next_mbtn_left_command=ignore` 可禁用该动作 |
| `playlist_next_mbtn_right_command` | `ignore` | 下一个媒体；例如 `playlist_next_mbtn_right_command=ignore` 可禁用该动作 |
| `playlist_next_mbtn_mid_command` | `ignore` | 下一个媒体；例如 `playlist_next_mbtn_mid_command=ignore` 可禁用该动作 |
| `playlist_mbtn_left_command` | `script-binding playlist_controls/toggle` | 队列按钮；例如 `playlist_mbtn_left_command=ignore` 可禁用该动作 |
| `playlist_mbtn_right_command` | `ignore` | 队列按钮；例如 `playlist_mbtn_right_command=ignore` 可禁用该动作 |
| `vol_ctrl_wheel_down_command` | `no-osd add volume -5` | 音量图标；例如 `vol_ctrl_wheel_down_command=ignore` 可禁用该动作 |
| `vol_ctrl_wheel_up_command` | `no-osd add volume 5` | 音量图标；例如 `vol_ctrl_wheel_up_command=ignore` 可禁用该动作 |
| `vol_ctrl_mbtn_right_command` | `no-osd set volume 100` | 音量图标；例如 `vol_ctrl_mbtn_right_command=ignore` 可禁用该动作 |
| `vol_ctrl_mbtn_mid_command` | `script-binding select/select-aid` | 音量图标；例如 `vol_ctrl_mbtn_mid_command=ignore` 可禁用该动作 |
| `volumebar_wheel_down_command` | `no-osd add volume -5` | 音量条；例如 `volumebar_wheel_down_command=ignore` 可禁用该动作 |
| `volumebar_wheel_up_command` | `no-osd add volume 5` | 音量条；例如 `volumebar_wheel_up_command=ignore` 可禁用该动作 |
| `info_mbtn_left_command` | `script-binding playback_feedback/media-info` | 信息按钮；例如 `info_mbtn_left_command=ignore` 可禁用该动作 |
| `ontop_mbtn_left_command` | `script-binding playback_feedback/ontop` | 置顶按钮；例如 `ontop_mbtn_left_command=ignore` 可禁用该动作 |
| `screenshot_mbtn_left_command` | `script-binding capture_controls/screenshot` | 截图按钮；例如 `screenshot_mbtn_left_command=ignore` 可禁用该动作 |
| `screenshot_mbtn_right_command` | `script-binding capture_controls/clip-point` | 截图按钮；例如 `screenshot_mbtn_right_command=ignore` 可禁用该动作 |
| `screenshot_mbtn_mid_command` | `script-binding capture_controls/open-folder` | 截图按钮；例如 `screenshot_mbtn_mid_command=ignore` 可禁用该动作 |

`_` 是宿主菜单占位，配置末尾及 playback-feedback 强制空动作会阻止它作为播放器快捷键；Audio Only 从原菜单调用。

`mbtn_left/right/mid` 分别是左/右/中键；`wheel_up/down` 为滚轮方向。保留完整命令才能保留本版字幕、截图、队列或反馈逻辑。音量条左键拖动由组件实现，不能凭空新增 `volumebar_mbtn_left_command`。

ModernZ 还支持以下未显式写入的常用参数，可按上一节相同方法追加：

| 参数 | 作用 | 当前默认与来源 | 可选值或边界 | 修改示例 |
| --- | --- | --- | --- | --- |
| `vol_ctrl_mbtn_left_command` | 音量图标左键静音切换 | 脚本默认 `no-osd cycle mute` | 播放器命令字符串 | `vol_ctrl_mbtn_left_command=no-osd cycle mute` |
| `volume_control_type` | 音量条映射 | 脚本默认 `linear` | linear/logarithmic | `volume_control_type=logarithmic` |
| `volumebar_unmute_on_click` | 点击音量条解除静音 | 脚本默认 `no` | yes/no | `volumebar_unmute_on_click=yes` |
| `jump_amount` | seek 按钮左键步长 | 脚本默认 `10` | 秒；不改变键盘 Left/Right | `jump_amount=5` |
| `jump_more_amount` | seek 按钮右键步长 | 脚本默认 `60` | 秒；不改变 Ctrl+Left/Right | `jump_more_amount=30` |
| `jump_mode` | seek 按钮模式 | 脚本默认 `relative` | relative/exact；default 布局强制 relative+exact，此项不改变其实际 seek 模式 | `jump_mode=exact` |
| `jump_softrepeat` | 按住 seek 按钮连续执行 | 脚本默认 `yes` | yes/no | `jump_softrepeat=no` |

以上参数写入 `script-opts/modernz.conf`；生效时机：重启播放器。

长按 Space 的门槛 250ms、临时 2×，键盘速度循环以及字幕调整步长属于 Lua 源码常量，不是可以追加到 conf 的字段。若只是想改变滚轮速度步长，直接修改已有 `speed_wheel_*_command` 的数值即可，例如 `speed_wheel_up_command=script-message-to playback_feedback add-speed 0.1`。

## 7. 截图、片段与播放列表

截图/片段的可调配置入口是第 3 节的 `capture_root`、`ffmpeg_path`，以及第 6 节 Screenshot 按钮动作。当前没有 `capture-controls.conf` 的编码参数接口，也没有 `playlist-controls.conf` 的窗口尺寸或转发键配置接口；创建同名文件不会让这些字段生效。

| 行为/实现项 | 当前值 | 用户可否直接配置 | 生效与边界 |
| --- | --- | --- | --- |
| Screenshot 左键 | 源 PNG 并复制图像 | 可改按钮命令；源截图格式在实现中固定 | 本次截图；不是控制栏合成图 |
| Screenshot 右键 | A/B 源时间线，输出 MP4、WebP、GIF | 可改按钮命令；编码值没有 conf 字段 | B 点冻结当前任务的复制格式 |
| 下次复制格式 | 新实例 `webp` | 通过 hover 选择 WebP/GIF/MP4 | 只保留当前实例；切媒体保留，重开恢复 |
| MP4 视频编码 | libx264、CRF 18、preset fast、yuv420p，宽高补偶数；有音轨时 AAC 192k | 源码常量，不是现成参数 | helper 每次导出使用 |
| WebP | 最高 20fps，边界框 960×960，质量 75，compression_level 4 | 源码常量 | 保持比例、不放大；循环输出 |
| GIF | 最高 12fps，边界框 640×640，128 色，Bayer 抖动 | 源码常量 | 保持比例、不放大；循环输出 |
| Capture 子目录 | 清理标题并去一个已识别媒体后缀 | 没有标题模板配置 | 不迁移已有目录 |
| Playlist Delete | 从队列移除条目 | 没有删除磁盘文件的配置模式 | 不删除源文件 |
| Playlist 搜索、拖动排序 | 已有队列中的过滤和重排 | 无专用 conf 参数 | 不是目录扫描规则；目录规则在 mpv.conf |
| Playlist 初始窗口 | 340×420，随 DPI 调整并跟随主窗 | 可拖动侧窗调整宽度；持久默认值需改源码 | `helpers/playlist-window.ps1` 中的窗口初始化和 `PlaylistFollower.UserWidth` 共同影响布局 |
| Playlist 字体与配色 | Segoe UI 9；背景 #111111、文字 #E6E8ED | 源码常量，不读取 ModernZ 颜色选项 | 在 `helpers/playlist-window.ps1` 窗口初始化处维护；其他子控件另有自己的颜色 |

改变主播放器 `screenshot-format` 不会自动把本版源 PNG 按钮改成 JPEG；改变 `screenshot-directory` 也不是本版 Capture 根目录入口。本版明确走专用 helper。helper 的 `ValidateOnly`、`NoClipboard`、`TestOutputRoot`、`TestFailPhase` 是调用/测试接口，不是推荐给用户加入配置文件的参数。

片段导出使用源媒体与选定音轨等数据，不是对播放器窗口录屏。显示增强、OSD 和弹幕效果不应据此推断会进入导出文件；网络媒体、HDR 和编码组合需按实际素材验证。详细按钮行为见[截图与动态片段](features.md#6-截图与动态片段)。

## 8. 增强与显示目标

本版新实例始终从 Original 开始。五档选择仅在当前实例保留，切换媒体重新记录该媒体基准，关闭增强恢复基准。不是把上次档位写回配置文件。

| 参数 | 作用 | 当前默认与来源 | 可选值或边界 | 修改示例 |
| --- | --- | --- | --- | --- |
| `anime_verified` | 允许通过条件检查的 Anime4K 档 | 显式 `yes`；脚本默认 no | yes/no；只是可用门槛，不代表你的 GPU 已验证 | `anime_verified=no` |

以上参数写入 `script-opts/enhancement-controls.conf`；生效时机：重启播放器。

| 档位 | 当前实现 | 可配置边界 |
| --- | --- | --- |
| Original | 恢复当前媒体捕获的原值 | 没有 `default_preset` 参数 |
| Scaling | scale=ewa_lanczos、dscale=mitchell、cscale=spline36、scale-antiring=0.7，deband 关闭 | 这些是档位常量，不能写进 enhancement-controls.conf 改档位 |
| Deband | Scaling 基础加 deband；iterations=1、threshold=32、range=16、grain=0 | 常量，没有独立质量级别配置 |
| Anime4K-L / Anime4K-S | 随包固定 shader 链 | 需 gpu/gpu-next、可识别 SDR 元数据、允许开关及 shader 文件存在；无 HDR/RIFE 档 |

增强模块控制 `scale`、`dscale`、`cscale`、`scale-antiring`、`deband`、`deband-iterations`、`deband-threshold`、`deband-range`、`deband-grain`、`glsl-shaders`。可在 mpv.conf 里设这些播放器选项作为自己的基础方案，但**选择非 Original 档会覆盖相应受控组**，不能认为两组会任意叠加。具体数值合法范围仍按播放器版本手册核对。

本包 `target-trc=auto` 保持自动显示目标。若明确需要 sRGB，可在自己的 mpv.conf 改为 `target-trc=srgb`，或先用 `--target-trc=srgb` 做一次启动测试。它是显示目标声明，不是测量、ICC 校准或全链路色准保证。增强档不修改色彩目标、主输出驱动、硬解或帧率。

源代码中的 shader 链、编码常量和快捷步长若要成为新增可调选项，需要开发修改；本文没有提供不存在的 conf 键。第三方资源与修改许可见[许可清单](../LICENSES.md)。

## 9. 常用修改示例与个人维护

### 指定本机输出及程序路径

从下载包的 `config/script-opts/mpvnet-local.conf.example` 复制到播放器实际配置目录，命名为 `script-opts/mpvnet-local.conf`，根据需要填写；不需要覆盖的项保留空值：

```ini
capture_root=D:\Media\Capture
ffmpeg_path=C:\Apps\FFmpeg\bin\ffmpeg.exe
python_path=C:\Apps\Python\python.exe
mpv_path=C:\Apps\mpv.net\mpvnet.exe
```

重启后分别观察截图目录、片段、弹幕和本地缩略图；文件存在性检查不能代替这些能力的实际操作。不要把真实文件上传到公开仓库。

### 放大控制栏并减少隐藏

在 `script-opts/modernz.conf` 修改或追加：

```ini
scalewindowed=1.1
scalefullscreen=1.1
hidetimeout=2500
keeponpause=bottombar
time_format=fixed
```

颜色表只控制相应已有元素，部分新增浮层的选中蓝色由实现固定，不能推断所有菜单都跟随这组颜色。标题为网络媒体时还可能按组件逻辑回退到 media-title。

重启并观察小窗口、全屏和暂停状态。尺寸过大会挤压按钮；先恢复倍率再调布局，不凭屏幕分辨率推断栏内布局单位。

### 显示常驻进度线与章节标题

在 `script-opts/modernz.conf` 修改或追加：

```ini
persistent_progress=yes
persistent_progress_height=10
show_chapter_title=yes
chapter_title_font_size=14
```

高度和字号只有对应元素显示时才可观察；章节标题还要求媒体有章节。修改现有同名行，不保留重复设置。

### 改滚轮步长与音量复位值

在 `script-opts/modernz.conf` 修改已有行，避免保留冲突重复项：

```ini
seekbar_wheel_up_command=script-message-to playback_feedback seek -5 relative+exact
seekbar_wheel_down_command=script-message-to playback_feedback seek 5 relative+exact
vol_ctrl_mbtn_right_command=no-osd set volume 80
```

这些改动仅影响相应控件，不改变键盘 seek 步长；独立侧窗的转发仍需按其实际映射观察。

### 调整弹幕占用与字号

在 `script-opts/bilibiliAssert.conf` 追加：

```ini
fontsize=40
opacity=0.8
percent=0.5
duration_marquee=12
```

`percent=0.5` 是保留底部一半高度为空白。重启后重新加载弹幕才会按新值生成，不会直接重排已生成 ASS。

### 控制本机资源使用

在 `script-opts/thumbfast.conf` 追加，保持远程缩略图关闭：

```ini
network=no
max_width=300
max_height=200
spawn_first=no
quit_after_inactivity=30
```

较大图像会增加生成与传输成本；空闲退出后下次 hover 可能需要重新启动。先保留 `hwdec=no`，再根据实际硬解能力决定是否更改。

### 保存自己的差异

- 记录修改了哪个文件、哪一行、原因与观察结果；保留修改前副本。
- 换版本前保存个人副本并比较差异，按[安装文档](installation.md)选择干净重装或高级命令行流程，不直接覆盖现有目录。
- 不修改第三方许可、不提交真实本机配置、媒体、缓存、日志或账号数据。
- 故障时先恢复最近一项改动；重新加载媒体和重新启动播放器是两种操作。

本文只说明源码中当前可配置的接口与值，不代表所有显示器、GPU、网络入口、导出格式或上游版本已完成功能/视觉验收。
