# 开发架构与状态边界

本文帮助维护者定位模块、接口和状态归属，仅随源码仓库提供。开发与验证命令见 [CONTRIBUTING](../CONTRIBUTING.md)，用户操作和参数分别见[功能指南](features.md)与[配置说明](configuration.md)。模块接口以链接中的源码为准。

## 模块与入口

mpv.net 承载播放器窗口、原生菜单和 libmpv；`config/` 安装到播放器实际读取的配置根目录。Lua 脚本通过 mpv 属性、`script-binding` 和 `script-message-to` 协作，Windows 辅助窗口通过当前实例的 IPC 通道与 Lua 控制层通信。

| 模块 | 入口与接口 | 状态归属及主要回归 |
| --- | --- | --- |
| 默认配置与菜单 | [mpv.conf](../config/mpv.conf)、[mpvnet.conf](../config/mpvnet.conf)、[input.conf](../config/input.conf)；菜单和键位调用宿主命令或脚本动作 | 文件保存项目默认，运行时属性由播放器持有；[菜单与默认键检查](../tests/test_context_menu.py) |
| 控制栏 | [modernz.lua](../config/scripts/modernz.lua)；读取 `user-data/mpvnet/capture`、`enhancement`，向对应脚本发送动作 | ModernZ 管理布局、浮层、输入区域和字幕避让，不保存用户长期偏好；[响应式布局](../tests/test_responsive_osc.py)、[提示](../tests/test_control_tooltips.py)、[区间标记](../tests/test_seekbar_markers.py) |
| 播放与字幕 | [playback-feedback.lua](../config/scripts/playback-feedback.lua)、[subtitle-controls.lua](../config/scripts/subtitle-controls.lua)；键盘与菜单调用已注册动作，必要时调用媒体信息或路径辅助程序 | 临时加速、Mark 和字幕调整由所属脚本管理；媒体切换时按各自规则恢复或清理；[失败反馈](../tests/test_failure_feedback.py)、[字幕](../tests/test_subtitle_controls.py) |
| 用户快捷键 | [模型](../config/script-modules/user-shortcuts.lua)定义动作和覆盖规则；[控制层](../config/scripts/user-shortcuts.lua)加载、应用并发布 `user-data/mpvnet/shortcuts`；[设置页](../config/helpers/settings-shortcuts.cs)编辑草稿，[保存helper](../config/helpers/shortcuts-window.ps1)以 `-Operation Save -RequestPath` 写入 | `mpvnet-user.json` 保存长期覆盖，稳定动作 ID 对应键位，不接收任意命令；[模型与运行层](../tests/test_user_shortcuts.py)、[原子保存](../tests/test_user_preferences.py)、[内嵌设置页](../tests/test_settings_shortcuts.py) |
| 播放列表 | [playlist-controls.lua](../config/scripts/playlist-controls.lua)通过 `-PayloadPath` 启动 [playlist-window.ps1](../config/helpers/playlist-window.ps1)，以 token 校验回传动作，并读取快捷键映射 | 真实队列和条目 ID 属于 mpv，窗口只维护搜索、选择和布局；[队列控制](../tests/test_playlist_controls.py)、[窗口与几何](../tests/test_playlist_window.py) |
| 截图与片段 | [capture-controls.lua](../config/scripts/capture-controls.lua)以 `-PayloadPath` 调用 [capture-media.ps1](../config/helpers/capture-media.ps1)，将结果发布给控制栏 | Lua 持有 A/B、媒体代次、忙状态、所选格式和最近结果；helper 管理本次输出、FFmpeg 及临时文件；[单格式导出](../tests/test_capture_single_format.py) |
| 画面增强 | [enhancement-controls.lua](../config/scripts/enhancement-controls.lua)接收 `set-preset`，发布 `user-data/mpvnet/enhancement` | 实例保留选择，每个媒体重新捕获基准；写入受控属性失败时尝试回滚；[增强回归](../tests/test_enhancement_controls.py) |
| 外部组件与本机路径 | [mpvnet-paths.lua](../config/script-modules/mpvnet-paths.lua)读取可选路径；[thumbfast.lua](../config/scripts/thumbfast.lua)管理缩略图子进程；[弹幕入口](../config/scripts/bilibiliAssert/main.lua)调用随包转换器 | 本机路径文件属于用户；缩略图及弹幕任务由各自组件清理，弹幕使用独立副字幕轨；[弹幕转换](../tests/test_danmaku.py)，第三方边界见 [LICENSES](../LICENSES.md) |
| 安装与恢复 | [installer.ps1](../tools/installer.ps1)和 [maintain.ps1](../tools/maintain.ps1)共用 [maintenance.psm1](../tools/maintenance.psm1)，复用目录识别、安装、旧版备份与恢复模块 | 安装包 manifest、目标 receipt、备份和未完成操作日志分别保存包内容、安装身份与恢复状态；[目标识别](../tests/test_install_targets.py)、[旧版备份](../tests/test_legacy_backup.py)、[维护事务](../tests/test_maintenance.py)、[用户状态保留](../tests/test_user_settings_upgrade.py) |
| 构建与发行准备 | [build-package.py](../dev-tools/build-package.py)按 [package-map.json](../dev-tools/package-map.json)生成包及 manifest；[prepare-release.py](../dev-tools/prepare-release.py)检查并生成 ZIP | 两入口共用 [package_lib.py](../dev-tools/package_lib.py) 的 `stage_package`／`package_zip`，分别负责目录写入和 ZIP 创建；显式清单决定交付范围，开发文档与测试不入包；[构建回归](../tests/test_package_build.py) |

## 配置与状态所有权

### 常用设置基础

[user-settings 模型](../config/script-modules/user-settings.lua)、[控制层](../config/scripts/user-settings.lua)和 [WPF 窗口](../config/helpers/settings-window.cs)提供八类常用设置及工具入口，完整清单和生效规则见[配置说明](configuration.md#常用设置)。`user_settings/open` 对应“工具与设置 > 常用设置…”及稳定动作 `tools.settings-editor`，不新增默认按键。其他原生入口替换与菜单统一仍属后续批次。

`mpvnet-user.json` 继续使用 schema 1 和平面 `settings` 对象。字段类型、数值范围、选项、搜索词、分组和时机由 Lua 模型定义；窗口按元数据构造控件并持各页草稿和载入 revision。模型复用原文 JSON 解析器，只替换本页字段，其他域和未知值保留原文。false、0、空字符串是显式值，保存请求中的 null 表示删除覆盖；新字段即使等于当前默认也保留显式选择，只有原有两项缩放继续沿用等默认省略的兼容行为。恢复默认先改草稿，保存后删除覆盖，不写受管配置。

[settings-options.lua](../config/scripts/settings-options.lua)持有播放选项的应用边界。语言、默认字幕显隐与硬解只在 `on_load` 写 `file-local-options`，位于当前文件选轨／创建解码器之前；保存和轮询不写当前解码器。全屏与置顶仅初始化一次。音量／静音为避免 mpv.net `Player_Initialized` 记忆值与 Lua 初始化竞争，冻结控制层第一次加载的启动快照，到本实例首次 `on_load` 读取宿主最终基线并应用一次；继承不写，之后的保存、轮询和换媒体不改变这一启动目标。首次损坏配置也冻结无覆盖，之后修复留待下一实例。

同一功能脚本内的多个 owner 共用分发器，内部 preview/cancel/commit 追加稳定字段 ID，避免消息注册互相覆盖。owner 支持数字、布尔和字符串；字幕位置与 ModernZ 自动避让、临时字幕调整共享基线，控制栏各选项由 ModernZ 自己同步内部布局／暂停／时间格式状态。高级工具只接受稳定白名单动作，复用宿主原有文件编辑与目录命令；不接受任意文件路径或命令。

控制层发布 `user-data/mpvnet/settings`，包含已保存值、实际值、默认来源、待生效及错误状态。功能模块通过 `user-settings.owner` 管理预览所有者、媒体代次、应用版本及条件恢复；字幕由 subtitle-controls 写属性，控制栏由 ModernZ 改自己的选项和几何。保存值总线 `settings-values` 只同步长期值；其他实例在下一媒体应用，保存实例显式 commit。提交处理主动读取最新总线，避免消息先于属性通知到达时漏应用。保存成功与运行应用失败分别报告。

切媒体结束预览而保留窗口草稿；再次预览需用户操作。后续手动变化使旧预览失去恢复权，自有字幕动作会显式失效预览。mpv 未通知的外部同值赋值无法观测，不能据此判断操作所有权。预览恢复失败保留恢复点并报错，可重开设置重试撤销。运行态标识不写入用户 JSON。

路径仍只写 `script-opts/mpvnet-local.conf`，使用独立 revision，不提供双文件事务。[settings-storage.ps1](../config/helpers/settings-storage.ps1) 的 `SaveLocal` 只接受四个已知路径键，保留未知行、注释及未改行；空值删除覆盖，重复已知键或非法新路径拒绝保存。Capture 新任务重读输出根，已开始任务的 payload 保持；程序路径在实例启动时读取。

窗口绑定父 PID、IPC 和每次打开的新 token，旧窗口消息失效。[settings-chrome.cs](../config/helpers/settings-chrome.cs)通过WindowChrome提供同底色标题栏、系统拖动／缩放和最大化／关闭按钮，ShowInTaskbar=false；取得并校验父PID对应的MainWindowHandle后设置原生owner，不使用Topmost。验证和NoShow模式不创建窗口句柄。IPC中断保留草稿并禁保存，父进程退出时关闭窗口。窗口消失后控制层结束其预览，仅清理自己的临时请求。回归分别见[运行层](../tests/test_user_settings.py)、[存储](../tests/test_settings_storage.py)、[窗口](../tests/test_settings_window.py)及[标题栏](../tests/test_settings_chrome.py)。

[settings-close.cs](../config/helpers/settings-close.cs)在关闭有草稿时提供等宽“保存／不保存／取消”。保存先校验已知冲突与输入，再依分类顺序执行现有独立保存，全部确认成功才关闭；不是跨文件事务。每页写入前发送该模块的editor-refresh(token, nonce)，等待发布状态中的refresh_id匹配，再从已更新基线发起save，避免同一窗口跨JSON域保存时被尚未轮询的旧revision误拒。两控制层仅在合法token且非保存／关闭中接受有限格式nonce，刷新不写盘或改变生命周期。

逐页完成后清除对应草稿；任一失败停止后续保存，保留窗口与未保存草稿，列出已成功保存分类。保存期间阻止重入关闭。结果超时则停止自动推进并禁止重复提交，保留“不保存／取消”的退出路径，明确先前请求仍可能完成；迟到回执只更新已确认状态，不重新启动关闭流程。“不保存”只放弃未提交草稿，不回滚已成功保存的分类；“取消”只返回编辑。关闭流程与跨域确认回归见[SettingsCloseTests](../tests/test_settings_close.py)。

窗口展示由 [settings-window.cs](../config/helpers/settings-window.cs)协调，[settings-controls.cs](../config/helpers/settings-controls.cs)提供语言排序、字体选择器、固定字幕示例、路径浏览和窗口内确认层。这些控件只修改草稿，仍由原控制层保存和预览。字幕示例使用本机字体和草稿比例，不依赖媒体字幕，不保证与ASS／位图字幕排版一致。关闭确认同时统计设置和快捷键草稿；模态层禁用底层输入，关闭时恢复焦点。

控制栏窗口内画面由 [settings-preview.cs](../config/helpers/settings-preview.cs) 注册所属播放器的 DWM 实时缩略图，校验源窗口 PID，将客户区等比例显示在固定预览区域。它复用当前播放器的 ModernZ 渲染，不另起解码器、不保存截图、不转发预览区域输入。切到其他页、搜索结果或打开窗口内模态层时隐藏缩略图；设置关闭释放 DWM 句柄，源窗口最小化／不可用时隐藏画面并提示。布局按 WPF 逻辑单位转换到目标客户区，真实跨 DPI、特殊渲染器及最小化恢复仍需各自验证。

[settings-shortcuts.cs](../config/helpers/settings-shortcuts.cs)提供内嵌动作目录，窗口通过同一IPC连接额外观察`user-data/mpvnet/shortcuts`，面板沿用该模块的token／revision／save契约，不通过设置保存入口改写键位。面板持有快捷键草稿与录键状态，向窗口公开保存状态和全局搜索条目；父窗口统一底部操作和关闭确认。局部搜索、分类或失焦取消录键，全局搜索不修改草稿。两类保存串行；同一JSON的其他域修改导致revision更新时，只有本页所有保存值／覆盖标记或快捷键基线完全未变、且此前未发生冲突才跟进revision；实际本页变化仍保留草稿并禁止覆盖，最终写入继续做原文比较。

菜单只保留常用设置入口，移除重复的用户快捷键项；稳定动作`tools.shortcuts-editor`及`user_shortcuts/open`仍兼容已有用户绑定，显示名改为“打开快捷键设置…”。该入口转发固定消息`user_settings/open-shortcuts`，由设置控制层持有唯一日常编辑窗口，不再从此入口启动旧独立Editor。控制层在初始请求和设置总线发布会话内`open_page`／`open_serial`，只接受快捷键目标，启动期间的重复请求不会因窗口尚未开始观察而丢失。窗口按序号消费一次，清除全局搜索并定位快捷键，保留各页草稿；普通设置入口只唤回已有窗口。保存、内部确认层、原生路径选择器或关闭流程期间保留待跳转请求，由后续Tick在安全时机处理，不改变快捷键保存token。

关闭通知携带最后收到的导航序号。Lua仅将窗口尚未见过的新请求留到旧helper退出后重开；关闭确认中已收到并随关闭放弃的请求不重放。token退休后到进程退出之间的请求同样排队，禁止并存两个设置helper。缺少关闭序号的旧通知仍按原关闭语义处理。旧快捷键helper的Save接口和兼容Editor代码暂留，日常入口统一不等于本批删除兼容文件或完成M2-F所有原生入口替换。

缩放编辑使用百分比滑块；模型发布常用滑块范围和步长，底层存储合法范围保持。窗口载入时仅夹紧滑块手柄，不夹紧草稿或保存值；超范围配置继续显示原百分比，用户主动操作才换成常用范围内值。字幕标签使用“字幕缩放”，保留“字号”等搜索别名。正式设置页仅使用controlbar模式显示源客户区底部35%区域，保留全宽；几何模块的旧subtitles/full模式保留回归兼容，不再作为字幕页的日常预览。几何只依赖容器、源尺寸、模式与位置，OSC缩放值不参与自动适配。实际客户区裁切经窗口外框、客户区原点及 DWM 源纹理尺寸映射到rcSource。纯几何检查见 [SettingsPreviewGeometry](../tests/test_settings_preview.py)。

控制栏页通过 `preview-display(token, controlbar|none|renew)` 请求临时显示。控制层校验当前会话后转发 ModernZ 的 `settings-display-preview(token, begin|end|renew)`；ModernZ 持有3秒显示期限，窗口约每秒续期，续期不能重新创建已撤销的显示状态。此机制不写 visibility 偏好，也不改数值预览所有权。离页、关闭、失联超时、切媒体和显式手动显隐结束临时显示，按当前显隐／暂停策略恢复。只有预览期间的手动显隐会使旧暂停恢复点失效；未使用预览时沿用原行为。显隐回归见 [SettingsDisplay](../tests/test_settings_display.py)。

### 共享保存与既有模块

项目默认由受管配置文件提供。`mpvnet-user.json` 保存用户快捷键与常用设置覆盖，`script-opts/mpvnet-local.conf` 保存本机路径；两者都不属于安装器的受管文件集合。保存使用互斥锁、原内容比较和原子替换；Lua 保存成功后重新读取，其他实例约每秒检查同一文件。未知字段继续保留，损坏文件或不支持的 schema 保持原样。

JSON 请求校验、路径检查及原子写入由 [user-preferences-storage.cs](../config/helpers/user-preferences-storage.cs) 的 `UserPreferencesStorage` 提供，不依赖 WPF。快捷键原 `Save` 请求及 `{ok, error, conflict}` 回执保持。settings helper 额外请求 `return_written_text`，成功回执包含实际写入文本，回读时精确比对，避免把随后外部保存误认成本次结果。JSON 存储允许缺少域，但出现的 `shortcuts`、`settings` 必须为对象；字段校验由各自模型负责。

播放实例的临时状态与这些长期配置分开。增强选择和导出格式可跨媒体保留，但不跨重启；字幕调整和标记遵从媒体生命周期。观看记录、未知文件和第三方组件数据也不因配置包更新而自动纳管。

安装计划绑定目标目录、包内容、受管文件和恢复记录。统一维护入口的 `Apply`、`Restore`、`Recover` 都要求本次预览的校验值，持锁后再次核对。写入前保存真实备份与日志；恢复只接受日志中记录的操作前后字节，额外修改会阻止恢复。哈希用于一致性检查，不提供对恶意重写整套本地记录的认证。

## 辅助进程与生命周期

关于窗口由[about-window.lua](../config/scripts/about-window.lua)持有单实例helper及两份自有临时文件：不可变JSON请求保存当前实例版本和父PID，独立序号文件传递重复打开请求。[启动器](../config/helpers/about-window.ps1)校验请求与序号路径配对，[WPF窗口](../config/helpers/about-window.cs)保留父Process对象、验证owner窗口PID，每250ms消费更大的序号并唤回；父进程退出时关闭。关闭回执携带最后处理序号，Lua仅重放窗口停止读取之后的新打开请求，清理仅限本会话文件；媒体切换不关闭窗口。菜单及稳定动作`help.about`转向新入口，原命令在快捷键模型中作为语义别名保留。

版本取当前实例的`user-data/frontend/version`、`mpv-version`与`ffmpeg-version`，MediaInfo版本及各文件最后修改日期读取父进程程序所在目录。读取失败明确显示“未能读取”，不使用固定版本；原mpv.net 7.1.2关于窗的版权和GPL v2信息完整保留。自有窗口属于父播放器但不禁用播放器，不发起联网或打开外部链接；高级用户直接调用宿主底层命令仍可用。验证模式不创建句柄、计时器或显示窗口。

安装器继续由`tools/installer.ps1`持有检查计划、后台runspace、忙状态及Apply／Restore／Recover调用；[installer-ui.cs](../tools/installer-ui.cs)仅提供WinForms窗口、按钮、可选择的深色文本框和确认窗。主区显示目标、状态及一句说明，完整检查结果默认收起；右侧主按钮按状态选择播放器、执行、重新检查或完成关闭，还原独立位于左侧。安装器保留独立任务栏、双向缩放与最小化／最大化；确认窗归属于安装器，默认取消，Esc／关闭取消，摘要与可展开的完整详情分别滚动，按钮固定在右侧。确认期间禁止重入和重新检查，确认返回OK后仍走原计划token复核，核心维护模块未移入界面层。界面构建失败继续保留系统MessageBox兜底。

`KitInstallerTextBox`保留原生Edit的文本选择和复制，以自有细滚动条替代亮色系统条；滚动范围使用EM_GETRECT和实际视觉行间距，不能以Font.Height近似高DPI下的原生行高。确认文本只统一换行用于显示，不修改来源内容。安装计划的releaseNotice按字典成员读取并纳入确认正文；不能用PSObject.Properties判断字典键。此层继续采用现有system-aware DPI，不承诺真实跨屏缩放已验证。

发行包可包含`docs/upgrade-notice.txt`。包读取器只从已通过manifest摘要校验的字节读取该提示，最大4096字节；缺少提示的旧包保持兼容。维护计划通过`releaseNotice`传给图形安装器与命令行文本输出：更新确认摘要直接展示，首次安装可在确认详情中展开；恢复／还原不展示升级提示。此展示字段不改变安装、备份、冲突保护或事务顺序。

Capture、Playlist、快捷键、标题路径和媒体信息使用各自拥有的 UTF-8 临时 JSON 文件传参，媒体地址等数据不拼成 shell 命令。

媒体信息的旧`playback_feedback/media-info`动作转发给[media-info.lua](../config/scripts/media-info.lua)，保留原键位与Info按钮。控制层保存打开时的媒体快照及自有请求／唤回序号文件；同一媒体重复打开唤回已有窗，切换媒体后显式打开会先结束旧helper、再生成当前快照，防止两窗并存。网络请求不传URL、请求头或外部轨道地址；标题为URL时使用通用名称。播放进度变化不刷新阅读中的报告。

[media-info-window.ps1](../config/helpers/media-info-window.ps1)校验请求与序号路径配对；[数据层](../config/helpers/media-info-data.cs)读取当前父播放器目录的MediaInfo.dll，以默认Complete=0取得完整原始报告，保留未知字段和行；网络仅使用播放器可取得属性，缺失不猜测。本地读取失败保留可用概览及中文原因。[WPF视图](../config/helpers/media-info-view.cs)负责概览／详情、名称值列、无法结构化的原行、查找及复制；复制详情保留原报告，不复制过滤后的子集。父Process、owner校验、Loaded后轮询、关闭序号及NoShow边界沿关于窗口约定。报告获取与展示分离，不把MediaInfo动态字段压缩成固定概览字段。

Playlist 和快捷键窗口绑定启动它们的播放器 PID、IPC 与 token，关闭时只通知或清理自己的窗口和请求。Capture 用任务 ID、父进程及 Job Object 管理 FFmpeg，失败只清理本任务产生的文件；打开输出目录使用独立请求，不占用导出状态。切换媒体可清除可见区间，但不取消已经开始的导出；媒体代次防止旧任务结果影响新媒体标记。

Playlist 的 WinForms 展示继续位于 `playlist-window.ps1`：`PlaylistStyle` 集中当前窗口配色，客户区标题栏沿用设置窗口的视觉；`WM_NCCALCSIZE`将绘制范围扩到整个窗口，`WM_NCPAINT`／`WM_NCACTIVATE`不再进入默认系统框绘制，普通`WM_ACTIVATE`仍由Form处理。保留sizing样式、水平命中映射和 `PlaylistFollower` 的可见边缘计算。标题栏／底栏尺寸按窗口 DPI 转为物理像素。关闭按钮进入原关闭拦截并隐藏窗口；搜索按钮位于底栏右侧，复用原搜索切换，展开后依次排列输入框、计数和按钮。两按钮聚焦时 Space／Enter 留给按钮激活，列表内仍沿用播放器快捷键转发。此层不持有真实队列或改变 IPC 契约。隐藏句柄消息、命中及离屏绘制检查不等同真实跨屏与跟随验收。

`PlaylistHover`只管理悬停计时：同目标稳定停留550毫秒显示，5秒后到期，移动或换目标才重新计时；`PlaylistTip`持有并释放自己的WinForms Timer，按鼠标和工作区放置提示。隐藏、失焦、点击、搜索切换和实际原生滚动路径取消旧提示，队列内容只用于当次显示、不落盘。底部计数按钮按文字测量命中范围，不覆盖整条底栏。

Playlist普通侧窗通过`DWMWA_WINDOW_CORNER_PREFERENCE=DWMWCP_ROUND`请求Windows标准圆角，不使用自定义窗口Region或逐像素透明度。父播放器最大化／全屏时请求直角，恢复普通窗口后恢复标准圆角；句柄创建或DWM合成恢复时重新提交。属性不受支持时保留既有窗口，不阻断打开。具体裁切和半径由系统决定；隐藏句柄写入／回读只能证明属性已接受，不能替代实际圆角观感检查。

## 验证层次

Python 回归使用标准库，Lua 回归执行实际脚本并提供 mpv 替身；Windows helper 检查覆盖真实存储、控件或合成安装目录。字体替身、控件事件、真实播放器运行和用户体验分别提供不同证据，不能互相替代。测试组、环境条件及允许跳过的项目统一见[测试说明](../tests/README.md)。
