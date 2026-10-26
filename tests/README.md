# 定向回归检查

在本代码仓库根目录执行。测试使用Python标准库、临时夹具和替身；Windows下部分用例调用系统PowerShell/WinForms。默认不显示窗口，不启动播放器、不访问网络或剪贴板，也不读取个人运行配置。

```powershell
python -B -m unittest discover -s tests -v
```

弹幕用例导入实际转换器并检查生成的ASS内容，覆盖默认/空过滤、正则、过滤文件、组合与非法正则，以及HTTP失败提示和退出码。测试文件写入系统临时目录，结束后清理。

ModernZ交互用例执行真实源码中的Lua函数和配置命令，替身只提供mpv、布局及输入环境。需要已有的Lua 5.1共享库；设置进程级环境变量后运行完整检查：

```powershell
# 替换为本机已有的Lua 5.1库绝对路径，不下载或随项目分发DLL。
$env:MPVNET_TEST_LUA51 = 'C:\path\to\lua51.dll'
python -B -m unittest discover -s tests -v
```

未设置该变量时，Lua用例明确显示`skipped`，只代表Python用例执行，不能报告整批验证通过；提供不存在或不兼容的库会报错。测试不修改全局环境变量，库仅用于测试，不成为播放器或公开包的新依赖。

覆盖弹幕过滤/错误处理、队列边界按钮、Speed滚轮、章节预览与失败反馈。章节用例中的mpv转义和ASS字体测量为host double，验证真实Lua流程与几何约束，不是实际字体像素验收。Capture用例可通过`NoClipboard`和失败注入验证真实PowerShell结果与自有文件回滚，不触碰真实剪贴板。

Playlist的C#几何和完整helper检查需要显式仓库外输出目录，每次创建唯一子目录保留结果：

```powershell
$env:MPVNET_TEST_PLAYLIST_ARTIFACTS = 'D:\artifacts\mpvnet-kit\test-run'
python -B -m unittest discover -s tests -v
```

未设置输出目录时该组明确跳过。默认仍跳过原生窗口用例；需要观察自有测试窗时，额外设置`$env:MPVNET_TEST_PLAYLIST_WINDOWS = '1'`后运行`test_playlist_window.py`。该用例会短暂显示自己创建的WinForms窗口，检查普通/最大化/全屏/屏边的可见边缘、焦点和记忆宽度，随后关闭自己的窗口。不会操作用户播放器或更改系统显示设置；单屏结果不能代替真实跨DPI移动。

这些检查不能替代实际播放器鼠标命中、网络加载或用户视觉验收。修改相关行为时先跑对应测试文件；交付前运行本批完整集合，避免重复无关历史矩阵。日志出现`skipped`时应明确报告缺少哪层验证。

中文菜单新增`test_context_menu.py`，以固定宿主旧菜单命令清单检查低频功能保留、既有键位、八类层级与动态名称；`test_subtitle_controls.py`执行完整字幕Lua，覆盖单次调整、反复进出、基线恢复和生命周期。只跑本批相关集合可使用：

```powershell
$env:PYTHONPATH = 'tests'
python -B -m unittest test_context_menu test_subtitle_controls test_modernz -v
```

Lua仍需上述`MPVNET_TEST_LUA51`。菜单文本检查不能替代宿主解析或真实菜单点击；本批额外WPF源码解析和隔离播放器维护者历史证据单独保存。

单格式导出的Lua路由与helper预览由`test_capture_single_format.py`覆盖；设置进程级`MPVNET_TEST_FFMPEG`为本机已有ffmpeg.exe路径后，额外以生成的短夹具执行真实三种格式及失败回滚，使用NoClipboard，不写真实剪贴板。未设置时编码项明确跳过。增强测试覆盖完整Lua状态和真实ModernZ说明函数，字体测量仍为host double。Playlist检查明确断言初始/搜索/恢复布局，并覆盖长队列按ID定位及空/过期ID。

开发测试不列入`dev-tools/package-map.json`，不会进入公开安装包。当前功能进度与未覆盖项见维护者另存的历史证据。

`test_control_tooltips`执行实际ModernZ控件构造、配置鼠标派发及提示布局，覆盖中文说明、无左键枚举、字幕状态、自定义绑定退化和浮层上方避让；`test_responsive_osc`另覆盖More字幕选轨/调整分路与独立行说明。字体度量为替身，不能替代真实像素和鼠标命中；两组均需要已有Lua51库。

鼠标操作图示回归追加已知前缀/未知文本、实际ASS p标签的有效尺寸、右键中心扩展且无灰色覆层、独立event及alpha/画布边界；escape-ass替身验证精确参数数量。显式p1和当前mp.assdraw默认p4的差异已由隔离运行探针验证；仍需真窗核实际像素，不能用替身代替字体与GPU验收。

`test_seekbar_markers.py`执行真实ModernZ区间/hover/刷新路径，覆盖有限时间与duration、A=0、重叠/贴边、暂停observer、代次隔离、淡出和窄hover降级；按ASS event最终定位检查图形，防止文本定位或中途样式覆盖使区间偏离轨道。Capture路由另覆盖pending_clip成功/失败、payload写失败及跨媒体回调。实际ASS像素、GPU输出和字幕自动扫描使用仓外隔离夹具，证据指针见state；不把host double计为实际像素或物理点击通过。

`test_responsive_osc.py`新增16项真实Lua布局/More回归，覆盖单行/两行/极矮、收纳入口完整性、子页长度变化、音量连续拖动、隐藏来源辅助键、同panel原因、外点消费、ESC/resize、鼠标section归属保存恢复。区域模型不能替代mpv实际section派发；仓外GPU probe单独验证其跨界、滚动和布局切换，维护者历史证据单独保存。

用户配置/快捷键集合：`test_user_shortcuts`执行真实Lua模型和控制层；`test_user_preferences`执行真实原子writer；`test_shortcuts_window`创建不显示的真实WPF控件并验证隐藏IPC生命周期；`test_user_preferences_export`保证用户JSON不被导出。`test_playlist_window`增加共享键名、动态转发与换键释放检查。实际mpv keybind优先级、双实例保存/重启/侧窗转发、可见GUI录入和保存分别使用仓外native probe，维护者历史证据单独保存，不能把替身/NoShow检查称作用户人工验收。

`test_user_settings_upgrade`需要显式环境`MPVNET_USER_UPGRADE_ROOT`（全新仓外根）、`MPVNET_USER_UPGRADE_OLD_PACKAGE`、`MPVNET_USER_UPGRADE_NEW_PACKAGE`，只在自有临时target调用真实安装/恢复工具，保留每条结果。覆盖用户JSON原bytes在升级/回退/干净安装保持，以及受管外改/新增路径碰撞/伪造用户状态包拒绝；具体变量名以测试源码为准，不运行stub播放器。

`test_install_targets` 在 Windows PowerShell 5.1 中执行真实目录与安装工具，用独立进程和合成包覆盖三入口目录选择、预览校验值、目录／父目录替换、来源变化、危险路径、GUI 失败清理、CLI JSON／文本及旧恢复接口。设置 `MPVNET_INSTALL_TARGET_ROOT` 为**不存在的仓外目录**后运行 `python -m unittest discover -s tests -p test_install_targets.py -v`；未设置时明确跳过。目录与每次 stdout/stderr 保留，stub 播放器不运行，AppData 测试仅替换本次进程内模块 getter，不写用户配置。每次重跑使用新根目录；界面真窗和人工观感另验。

`fixtures/installer_window_cases.ps1` 接收绝对路径`-SourceRoot`、`-PackageRoot`和**全新仓外**`-FixtureRoot`，用Windows PowerShell的`-STA`运行。它启动真实Form，在内存测试副本中只替换消息框答案并注入定时测试，执行原控件事件，记录初始／通过／阻断／完成与最小窗截图；不使用外部UIAutomation或物理输入。确认取消、详情开关、重检及过期目标拒绝属于控件事件证据，不替代鼠标、Tab／Enter／Esc或人工观感验收。

`test_legacy_backup` 需要 `MPVNET_LEGACY_ROOT`（全新仓外目录）、`MPVNET_LEGACY_PACKAGE`（按白名单生成的新测试包）；可选 `MPVNET_LEGACY_RELEASE_REPO` 默认为当前代码仓库。用本地Git archive读取目录中固定commit的旧版本，逐项验证指纹，不联网、不改公开库、不运行占位播放器。运行 `python -m unittest discover -s tests -p test_legacy_backup.py -v`；未配置时明确跳过。检查三个旧版本的31文件实际备份、用户状态保持、修改／缺失／混版／碰撞拒绝、过期预览、快照完整性与JSON／文本；stdout/stderr和合成目录均保留。

`test_maintenance` 需要 `MPVNET_MAINTENANCE_ROOT`（全新仓外目录）及 `MPVNET_MAINTENANCE_PACKAGE`（完整测试包）；本地旧发行来源同上。运行 `python -m unittest discover -s tests -p test_maintenance.py -v`。覆盖新装撤销、旧版接续、已有CLI兼容、连续还原、冲突／过期预览、进程检测失败、伪造恢复日志拒绝，以及真实子进程Exit(77)打断更新／还原／恢复后的文件与receipt原字节恢复。进程枚举只在测试子进程模块内替换，模拟运行实例或检测错误，不提供生产跳过开关，不启动或结束播放器；硬中断只终止自有测试进程，不等同断电实测。

M1-C原生窗口夹具复用`installer_window_cases.ps1`，新增实际隔离安装后自动检查、最近一步还原及再次安装可用状态；确认弹窗答案仍为模拟。窗口根据WorkingArea限制高度、底栏固定、内容可滚动，检查DPI意识及可达尺寸；物理键鼠、真实观感与跨屏仍单列。失败现场保留，不清除未知文件或用户进程。

动作目录覆盖复用`fixtures/native-menu.json`并补齐原生键盘专用命令，逐项覆盖mpv.net 7.1.2的143条有效命令、仓库实际菜单及OSC公开动作；检查语义合并、40默认键不变、新项可绑定和试用项按精确菜单启用。缓存上游源码一致性检查是可选增强（缺缓存则明确skip），基础目录回归不依赖仓外文件。

A分类窗口检查覆盖实际WPF分类计数/四筛选、modified与dirty区分、行内双键/移除/恢复、恢复全部确认、录入失焦及过期回焦取消、Tab Continue、真实键帽29 DIP与ghost样式。NoShow不替代真窗：自有播放器+UIAutomation验证实际录入/保存/播放器生效/Tab遍历，并以窗口截图核默认与最小尺寸；维护者历史证据单独保存。

## 构建迁移验证

`test_package_build` 检查默认预览不写入、显式构建、ZIP内容及开发文件排除，另验证已修改包保留和Git检出目标拒绝。构建及ZIP命令见 [开发说明](../CONTRIBUTING.md)。

`test_user_shortcuts` 的可选上游源码对照通过 `MPVNET_NATIVE_INPUT_HELP` 指定本机 `InputHelp.cs`，未设置时明确跳过。固定命令快照及核心动作覆盖不依赖此缓存。

安装回归需要先生成仓外测试包，再设置：

```powershell
# 所有 root 都必须是尚不存在的仓外目录；包目录由构建工具生成。
$env:MPVNET_INSTALL_TARGET_ROOT = 'C:/Temp/mpvnet-kit-checks/targets'
$env:MPVNET_LEGACY_ROOT = 'C:/Temp/mpvnet-kit-checks/legacy'
$env:MPVNET_LEGACY_PACKAGE = 'C:/Temp/mpvnet-kit-trial/package'
$env:MPVNET_MAINTENANCE_ROOT = 'C:/Temp/mpvnet-kit-checks/maintenance'
$env:MPVNET_MAINTENANCE_PACKAGE = 'C:/Temp/mpvnet-kit-trial/package'
$env:MPVNET_USER_UPGRADE_ROOT = 'C:/Temp/mpvnet-kit-checks/user-upgrade'
$env:MPVNET_USER_UPGRADE_OLD_PACKAGE = 'C:/Temp/mpvnet-kit-old-package'
$env:MPVNET_USER_UPGRADE_NEW_PACKAGE = 'C:/Temp/mpvnet-kit-trial/package'
python -B -m unittest discover -s tests -v
```

旧包可从本仓库既有发行提交 `git archive` 到新的仓外位置；新旧包及测试根目录相互独立。这里的旧包也可以是此前已核验的发行包，不能指向个人播放器配置。历史发行夹具默认在本仓库读取保留的提交；仅在使用其他完整历史副本时设置 `MPVNET_LEGACY_RELEASE_REPO`。
