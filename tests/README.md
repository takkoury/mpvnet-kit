# 回归检查

从代码仓库根目录运行。测试沿用 Python 标准库 unittest；播放器逻辑使用真实源码和合成输入，安装测试只写显式指定的仓外夹具，不读取个人播放器配置。

## 按改动选择验证

```powershell
python -B dev-tools/run-tests.py --list
python -B dev-tools/run-tests.py --profile core
```

无参数只显示帮助。`--list` 是测试类归组及前置条件的完整索引，不执行测试；`--profile` 可以重复指定。

| 改动领域 | 建议组 | 主要条件与证据边界 |
| --- | --- | --- |
| 开发工具、包清单、文档链接、菜单清单、弹幕转换 | `core` | Python 标准库与 Git；不验证真实播放器界面 |
| 控制栏、字幕、播放反馈、快捷键及队列的 Lua 逻辑 | `core` + `lua` | 显式提供 Lua 5.1 库；host doubles 不替代真实 mpv 输入派发或视觉验收 |
| 截图导出、播放列表、快捷键窗口及用户配置 helper | `helpers` | Windows PowerShell 与 Git；Playlist 指定证据目录；默认是 NoShow、合成输入与原生控件逻辑检查 |
| 目录识别、旧版识别、安装、更新、还原及用户设置保留 | `core` + `install` | Windows PowerShell、Git 完整旧发行历史、生成包及全新夹具目录；不启动占位播放器，不等同断电或人工操作验收 |

执行器先检查全部所选组的必要条件，再运行测试。缺少必要条件、失败或意外跳过都会返回非零；返回零只表示所选组通过。末尾摘要列出执行、失败、跳过数量及原因。新增测试类必须归入一组，发现遗漏或重复时入口会停止。

## Lua 与 helper 条件

`PlaylistSelectorData`归入lua，覆盖真实队列ID0/重复/替换、标题模式、重排定位、删除失效与释放输入后的再次索引解析；`SubtitleSelector`检查当前项初始可见、动态焦点、路径搜索与媒体OSD控制字符中和。真实核心另用合成文件验证重排后播放、当前项重播、长队列和空态，不读取个人播放列表。

`SelectorMenu`归入lua，覆盖17项固定目标、媒体动态条件、稳定ID、旧动作失效、子面板重入和失败重试；`SubtitleSelector`检查动态菜单焦点/命中与按住Enter交接。实际设置窗口、浏览器和原生队列不由此测试自动打开；真实核心只验证本批内部选择器交接。

`PropertiesData`归入lua，覆盖false/0/空值、原生数组/普通map、路径排序去重、循环/大小限制、日志级别借用与恢复、快照展示和OSD转义。`SubtitleSelector`验证属性名/值搜索、预览与大快照无多余编号测量。真实核心证据只采集合成环境与公开配置生成的属性，测试不导出个人完整属性集合。

`BindingsData`归入lua，执行数据模块与控制器，覆盖原生绑定优先级、ignore遮挡、改绑拒绝、输入恢复顺序和命令重入。真实核心检查只注册本批合成的音量/倍速/选择器命令，不执行个人绑定；`SubtitleSelector`另验证命令查找、提示和重复Enter防护。

`SubtitleLines`归入lua，同时执行字幕行数据模块和控制器源码，覆盖FFmpeg流映射、同秒文本/时间对应、延迟、异步取消/超时与旧回调；`SubtitleSelector`验证章节式布局、首次定位及参考标记更新不打断查找。真实FFmpeg提取和mpv跳转仍以隔离合成素材核心检查补充，mock不代表网络或所有字幕格式可读。

`WatchLaterData`归入lua，覆盖保存文件首行解析、mtime排序、目录及快照边界；`WatchLaterStore`归入helpers，使用合成目录验证只读扫描、部分失败、非法文本与数量／大小限制。控制层的目录变化、恢复关闭和旧回调由`TrackSelection`覆盖，真实进度恢复另用播放器核心及合成媒体验证。

播放历史的`HistoryData`归入lua，检查JSON行解析、去重和路径／日期边界；`TrackSelection`与`SubtitleSelector`分别验证会话、异步回调、快照重查和清空确认输入。`HistoryStore`归入helpers，使用仓外合成文件验证真实PowerShell文件锁、摘要冲突、清空和失败保留，不接触个人历史。

常用设置基础的 `UserSettings` 归入 lua，覆盖原文补丁、两实例生效、异步通知顺序、媒体代次、手动覆盖及失败恢复；`SettingsStorage`、`SettingsWindow` 归入 helpers，分别验证真实文件保存与 WPF 控件／草稿状态。窗口检查默认不显示，不等同于真实键鼠、观感或跨 DPI 验收。

`SettingsDisplay` 同属 lua，执行实际 ModernZ 的显隐、暂停及临时显示代码，覆盖续期、超时、手动显隐和媒体切换。`SettingsWindow` 另检查预览与保存区在宽窄窗口中不重叠。DWM 实际画面是否包含字幕与控制栏仍须用隔离播放器观察，不能由这些替身测试代替。

```powershell
# 使用本机已有的 Lua 5.1 库，不由测试下载或安装。
$env:MPVNET_TEST_LUA51 = 'C:/path/to/lua51.dll'
# 可以是已有仓外证据根；每轮自动建立新的唯一子目录。
$env:MPVNET_TEST_PLAYLIST_ARTIFACTS = 'C:/Temp/mpvnet-kit-checks/playlist'
python -B dev-tools/run-tests.py --profile lua --profile helpers
```

helpers 组还需 PATH 中的 Git 和 `powershell.exe`，与现有 helper 用例的实际调用一致。Lua 路径无效或库不兼容会在夹具创建前报错。

只有以下四个既有用例允许在未配置条件时跳过，实际结果仍会列出：

| 可选条件 | 用例／作用 |
| --- | --- |
| `MPVNET_NATIVE_INPUT_HELP` | `UserShortcuts.test_native_snapshot_matches_cached_upstream_getdefaults`；指定已有上游 `InputHelp.cs`，对照固定命令快照 |
| `MPVNET_TEST_FFMPEG` | `CaptureOutputs.test_real_encoders_save_only_selected_file_and_remove_intermediate`、`test_commit_and_clipboard_failure_leave_existing_files_untouched`；指定已有 FFmpeg，执行短合成视频编码，使用 NoClipboard |
| `MPVNET_TEST_PLAYLIST_WINDOWS=1` | `PlaylistWindow.test_owned_window_visible_edges`；短暂显示自有窗口，检查跟随和边缘位置 |

修改 Capture 编码行为时应配置 FFmpeg 后运行。显式提供但无效的文件路径不会降为可选跳过。所有其他跳过（包括整组因缺依赖跳过）都不能作为成功。

## 安装维护条件

先按 [开发说明](../CONTRIBUTING.md#生成测试包)生成新的仓外测试包。用户设置升级测试要求旧包的运行文件严格包含于新包；v0.4.0 发行收尾使用真实 v0.3.0 完整包作为旧包。旧包可从已保留的 Release 产物或本仓库对应 Git 提交取得，不能指向个人配置目录。

```powershell
# 四个 ROOT 都必须尚不存在，且彼此独立、与所有输入包分离。
$env:MPVNET_INSTALL_TARGET_ROOT = 'C:/Temp/mpvnet-kit-checks/run-01/targets'
$env:MPVNET_LEGACY_ROOT = 'C:/Temp/mpvnet-kit-checks/run-01/legacy'
$env:MPVNET_LEGACY_PACKAGE = 'C:/Temp/mpvnet-kit-trial/package'
$env:MPVNET_MAINTENANCE_ROOT = 'C:/Temp/mpvnet-kit-checks/run-01/maintenance'
$env:MPVNET_MAINTENANCE_PACKAGE = 'C:/Temp/mpvnet-kit-trial/package'
$env:MPVNET_USER_UPGRADE_ROOT = 'C:/Temp/mpvnet-kit-checks/run-01/user-upgrade'
$env:MPVNET_USER_UPGRADE_OLD_PACKAGE = 'C:/Temp/mpvnet-kit-old-package'
$env:MPVNET_USER_UPGRADE_NEW_PACKAGE = 'C:/Temp/mpvnet-kit-trial/package'
python -B dev-tools/run-tests.py --profile core --profile install
```

`MPVNET_LEGACY_RELEASE_REPO` 默认当前仓库；仅在使用另一份完整历史副本时指定。测试按 `tools/legacy-releases.json` 中的固定提交读取并核对旧文件，不联网拉取历史。预检会确认输出目录不在本仓库及工作树内、不经过链接，也不与输入包重叠；各组保留自己的文件／目录快照断言及 stdout、stderr 证据。

重跑必须换用新的 ROOT，不能清空旧证据目录。硬中断测试只终止自身测试进程；用户播放器和真实配置不作为夹具。

## 窗口与完整发现

`tests/fixtures/installer_window_cases.ps1` 是单独的原生窗口夹具，接收 `-SourceRoot`、`-PackageRoot` 和新的仓外 `-FixtureRoot`，需在 Windows PowerShell 的 STA 模式下显式运行。它模拟确认答案并触发真实控件事件，与物理键鼠、跨 DPI 和人工观感分别记录，不由默认测试组启动。

该夹具增加`-NoShow`后不显示窗口，仍通过真实安装器控件事件完成取消、新装、阻断、过期计划拒绝和还原；自有确认窗由实际按钮选择结果。`-UpgradeFrom <旧生成包>`可另测旧包更新、取消和还原，精确比较运行文件、收据及用户JSON。两种模式均使用新的合成目标，不执行占位mpvnet.exe；运行中播放器枚举仅在夹具进程内替换，不提供生产绕过开关。离屏图由隐藏控件逐层绘制，不是桌面截图。

`InstallerUI`归入helpers，编译真实`installer-ui.cs`并检查窗口能力、确认摘要／完整详情、收展高度与文字选区保持、取消默认、按钮布局和原生Edit滚底末行；不运行维护写入，不显示窗口。100%／150%／200%合成倍率检查不等同混合显示器DPI验收，真实选择文本／拖动及DWM像素仍需单独试用。

`AboutController`归入lua，检查关于窗口单helper、重复唤回、迟到打开重放、失败及退出清理；`AboutWindowTests`归入helpers，运行真实WPF启动器的ValidateOnly检查版本来源、完整信息、路径校验及无句柄／计时器。owner、实际激活和父播放器退出仍需隔离真窗试用。

媒体信息由`MediaInfoController`（lua）、`MediaInfoDataTests`和`MediaInfoViewTests`（helpers）分别验证会话及地址隔离、原始报告与概览数据、完整行保留及搜索／复制。可选`MPVNET_TEST_MEDIAINFO`指向已有MediaInfo.dll，使用临时父进程与合成音频对照默认Inform原报告；不读取个人配置，不安装DLL。无此依赖时仅允许对应真实DLL用例跳过，隐藏WPF不替代用户键鼠与owner验收。

`SubtitleSelector`归入lua，验证共用ASS面板的Unicode编辑、选中／取消、音轨紧凑列与竖线留白／按需详情、章节单行时间／无关闭项／原索引过滤、跨类型单一输入所有者、临时输入属性和控制台交接；`TrackSelection`验证媒体／会话代次、aid／sid独立提交、章节索引与快照校验、失效／失败与弹幕隔离，`SubtitleControls`保留旧选择入口转发及字幕调整回归，`SettingsDisplay`检查ModernZ临时让出鼠标section且不改变visibility。真实输入法候选、鼠标焦点、宿主拖窗与跨DPI需实际播放器试用；ASS离屏图和headless核心输入检查不替代这些验收。

设备选择也由`SubtitleSelector`／`TrackSelection`覆盖：单行／无关闭项、完整标识搜索与详情、缺失已选提示、会话内稳定name映射、重排／热移除／重插、同名与后缀碰撞、setter及回读失败、旧回调隔离和无关属性保持。真实核心的无声auto提交检查只验证配置接口，不代表物理输出设备、热插拔或实际发声验收。

视频轨复用上述两组，覆盖尺寸／帧率搜索、图像与封面不伪造fps、无标题回落、与音轨共用外框、类型过滤、vid提交／关闭及失败／旧回调不递增恢复代次。`VideoRestore`执行实际audio-only回调，覆盖明确选轨后旧恢复记录失效、当前可见视频优先和纯音频空操作。

媒体版本同样由`SubtitleSelector`／`TrackSelection`覆盖：原索引提交、current-edition实际标记、无标题回落、单一／空版本不可提交、列表变化／失败／媒体代次和提交时同步重新加载关闭。真实多Edition文件的切换与章节变化必须另用实际核心验证，不能用页面模拟或edition请求值代替成功证据。

高级主／次字幕复用两组检查：全量sub列表不污染原始轨道、另一槽占用行及提示、点击／键盘／搜索不提交占用项、提交时重查另一槽、auto当前轨解析、只写目标槽、显隐与ASS覆盖保持、普通字幕过滤和占用反馈、回读失败及旧会话隔离。合成Bilibili Danmaku命名轨的核心检查仅验证槽与属性，不等于真实插件ASS／overlay渲染或网络加载验证。

需要运行四组时，在依赖和各目录均准备好后执行：

```powershell
python -B dev-tools/run-tests.py --profile core --profile lua --profile helpers --profile install
```

原有入口 `python -B -m unittest discover -s tests -v` 继续可用，但 unittest 自身可能在跳过整组测试后仍返回成功；用于验收时优先使用具名入口。单文件调试可用 `python -B -m unittest discover -s tests -p test_package_build.py -v`，并自行检查其依赖与跳过情况。

## 维护测试辅助

`support/lua_source.py` 统一片段提取，分别保留字符串和类型化的配置注入；`lua_runtime.py` 只封装已有 Lua 库调用。`support/install_fixtures.py` 统一路径预检、PowerShell 定位、固定发行读取和子进程证据保存，不替各测试定义业务快照。开发工具通过 `support/dev_imports.py` 的单点路径配置普通导入，不执行 CLI 来获取函数。
