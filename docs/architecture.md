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

### 显式文件输入

[playlist-input.lua](../config/script-modules/playlist-input.lua)由playlist-controls持有，集中受管菜单、稳定快捷键动作、剪贴板文件和侧窗拖入的打开／追加请求。真实队列仍归mpv；请求开始记录条目ID／路径、当前项、媒体路径和工作目录，异步结果提交前重查，变化则要求重新选择。新请求先退休旧请求；旧结果、关停和提交期间的重入不能继续写新队列。追加不重建原队列、不改暂停状态，空队列也不自动播放。

按需启动的[playlist-input.cs](../config/helpers/playlist-input.cs)编译为`KitPlaylistInput.exe`，只读取本次JSON请求和用户明确选择的输入。它负责Windows文件对话框、显式剪贴板读取、完整路径规范化、文件存在检查和按路径去重；通过stdout返回带请求ID的结果。对话框绑定父PID的主窗；持有父Process并在父退出时结束自身。结果或诊断不输出原始异常、路径日志；请求文件由Lua清理。它不读个人配置、不写剪贴板、不持有独立队列或跨实例会话。

受管打开单个普通音视频保留当前`autocreate-playlist`偏好；明确多选及追加媒体通过loadfile的单文件选项设置`autocreate-playlist=no`，不改全局默认。文件夹、列表解析与保存尚未接入此批。字幕使用sub-add；普通列表／其他核心来源暂交原有loadfile。ISO、AviSynth及Windows快捷方式需要宿主特定预处理，整批拒绝并提示拖入主窗，避免将其当普通文件误加载。原生光盘入口、主窗拖入、资源管理器调起及原生近期文件仍由宿主处理，不承诺新规则覆盖这些路径。

构建工具通过源码摘要校验受管EXE，普通构包不编译、不下载依赖；与设置构建共用本地托管程序构建基础。验证分别覆盖实际C#输入规则、完整Lua控制层和隔离核心；真实选择对话框与键鼠体验仍需用户验收。

### 操作反馈与持续状态

[feedback.lua](../config/script-modules/feedback.lua)提供`new(mp)`客户端，各控制器用`show(text, kind)`发送已有文案；`action`为1.5秒，`success`和普通`notice`为2秒，`error`为4秒。发送、就绪判断和原生回退集中在该Module，控制器仍拥有动作结果、文案和任务生命周期；弹幕加载用`is_ready()`决定是否需要无协调器时的短暂回退。

[feedback-osd.lua](../config/scripts/feedback-osd.lua)继续通过既有`feedback_osd/show(text, seconds)`接收短消息，先暂时撤下自身持续文字，再交给原生`mp.osd_message`；秒数校验与持续槽顺序取自同一反馈Module。尚未发布`user-data/mpvnet/feedback/ready=true`时，客户端直接用原生短消息回退。原有未纳入该协议的3秒错误和20秒属性详情不变，不增加通用事件总线或动态槽注册。

持续状态分别由Capture写`user-data/mpvnet/feedback/capture`、字幕控制器写`subtitle`，只包含固定中文及字幕数值，不含媒体路径。导出开始／终止更新Capture槽；换媒体不取消已有导出。字幕进入／调整更新字幕槽，退出／还原／媒体结束清除；模式外单次调整只显示短消息。显式进入或调整也发送短反馈以即时替换上一条，随后同一状态保留。弹幕控制器另写`danmaku`槽，沿已有请求代次从加载持续到成功／失败；换媒体、主动替换或退出取消时清除，旧回调只清理其自己的输出，不能清掉新状态。加载成功提示不等于存在可见弹幕；原自动显示与最小数量条件保持。各槽按导出、弹幕、字幕顺序组合，真实任务与媒体状态仍属于原模块。

协调器借用原生`osd-msg1`承载持续文字，保留并拼接用户原值；临时隐藏时恢复原值。只在当前值仍等于自己上次写入的值时恢复，外部改动后本轮停止写入，所有持续槽清空后才允许新一轮借用。`osd-level`不为1、控制台或自有选择器打开时只让出自身持续文字，不改用户OSD等级。重复短消息使旧计时回调失效；任务结束后计时器不得恢复已清除状态；退出仅清理自有计时和选项借用。

当前固定核心把`osd-msg1`与其他原生短消息分行组合，未公开原生消息正文／剩余时长。协调器到期只恢复持续选项，不重发或清空原生消息；未纳入反馈协议的提示、20秒属性详情及stats可能与持续文字分行并存，保持原时长和关闭方式。不拦截任意用户命令，不靠轮询`show-text`抢占其他脚本。真实呈现与跨DPI需在目标环境分别验证，逻辑回归见[反馈协调](../tests/test_feedback_osd.py)。

### 轨道、章节与音频设备选择器

[track-selector.lua](../config/script-modules/track-selector.lua)共用Lua/ASS绘制、搜索与临时输入；[track-selection.lua](../config/scripts/track-selection.lua)单实例持有面板类型、媒体／会话代次及aid或sid提交。音轨只读audio轨，普通字幕排除弹幕；提交前重新验证轨道ID，id=0或再次选中当前轨都写对应属性no，不改mute、volume、audio-device、secondary-sid或配置文件。

`track_selection/select-chapter`复用同一面板实例和输入，章节采用38高单行与右对齐起始时间，不显示关闭轨道项。UI条目id为原chapter-list索引+1，提交写0基chapter，重复选择当前章仍写入以回到章首。控制层保留章节time/title顺序快照，列表通知不自动把新条目映射给旧输入；提交发现任何变化时先刷新快照和面板、返回重选提示，下一次明确选择才可提交。chapter观察更新当前标记，duration只改变时间格式，媒体切换使旧回调失效；不改变原上一／下一章或时间轴预览行为。

`track_selection/select-device`复用单行布局，只展示设备名称，完整name按需显示。控制层以audio-device-list的name为真实身份，为本次会话分配不复用的正整数UI id；重排保持映射，提交前重查name存在。description优先用于显示、缺失时显示name，auto明确显示自动选择；同名描述用唯一后缀区分。只写本实例audio-device，重复选择不切no；setter与回读校验不等于实际输出声音已验证。设备列表及配置属性变化刷新，已选name缺失时显示notice，不自动选择替代设备，不合成列表中不存在的auto。全局默认输出及用户配置不归该控制器所有。

`track_selection/select-audio`与`select-subtitle`共用一个按需加载的面板实例；打开新类型或重复打开先使旧回调失效再关闭，防止同步close回调退休新会话。`subtitle_controls/select`保留为转发入口，原循环／显隐／调整逻辑不变。start-file／end-file／shutdown关闭面板，track-list及当前类型对应的aid／sid变化刷新。音轨仅增加数据展示，不复制输入编辑器；四列元信息整组靠左，首尾列左对齐、位于两条竖线之间的格式／声道列居中，与字幕格式列对齐规则一致。按完整轨道集合确定有上限的紧凑列宽，搜索／滚动不改变列位置，竖线两侧使用统一留白，不均分或撑满整行。完整标题／采样率／码率／标记可停留或键盘聚焦查看。

现有mp.input.select由console固定渲染并强制单行，不能承接已确认双行条目；经能力检查和用户明确同意后采用独立渲染。面板只在打开期间启用自己的exclusive输入section，临时借用input-ime、cursor-autohide与window-dragging，关闭时仅在属性仍为自己的值时恢复。控制台打开时立即释放面板输入与绘制，IME旧值延后到控制台关闭再按所有权条件恢复，避免跨脚本观察次序覆盖控制台输入。

面板发布`user-data/mpvnet/track-selector/open`及无搜索内容的status诊断（类型／阶段／尺寸）。ModernZ只在此期间暂停自己的鼠标section与绘制，后续mouse／resize事件不能重新抢输入；关闭后按原visibility偏好重建显示与输入区域。快捷键目录保留既有动作ID及对应的旧命令别名。ModernZ将已替换选择器的旧精确`select`命令转到相应的新入口；从控制台直接调用的原生命令仍由核心处理。mock与无界面输入检查的证据和真实输入法组合、宿主拖窗、鼠标焦点及跨DPI试用分别记录。

视频轨选择同样由`track_selection/select-video`复用面板：过滤video轨，保留真实ID、图像／封面与已知尺寸／帧率；选择当前轨或关闭项写vid=no，其他写目标vid。双行布局沿用音轨，元信息为分辨率／格式／帧率或图像类型／来源，未知值不补造，细节按需显示。成功提交后递增`user-data/mpvnet/video-selection-revision`；playback-feedback的audio-only恢复记录绑定这一代次，明确新选轨使旧记录失效，避免异步清理消息误删较新的恢复记录。audio-only以当前可见视频为优先，关闭后恢复其自身记录；显式选择器关闭后无有效记录时仍按既有auto恢复。此修正不改aid、音量、设备或长期配置。

媒体版本由`track_selection/select-edition`复用单行面板，展示edition-list标题／编号，以current-edition标记实际当前版本，不以edition请求值代替。控制层持有原列表id/title顺序快照，提交前重读验证，变化时刷新并拒绝旧索引；提交写0基edition，同项重选不写no。少于两个版本不提供可提交行。设置edition可能触发start-file／end-file等重新加载事件，旧会话先失效；渲染层允许提交回调重入关闭，不重新激活旧面板。不承诺切换后播放位置不变。

高级字幕由`track_selection/select-primary`／`select-secondary`复用双行面板，包含全部sub轨；普通subtitle继续过滤Bilibili Danmaku。主／次字幕当前值由sid／secondary-sid决定，auto时回落current-tracks/sub或sub2的id，不使用跨槽track.selected判断目标槽。高级列表复制轨道展示数据并附另一槽占用原因，不修改原始track-list；占用项可聚焦但不提交，控制层在提交时再次读取另一槽并防竞态误选，成功后校验目标槽回读。当前目标轨重选或0关闭仅作用于目标槽。

两个槽及显隐变化刷新高级列表，普通列表保持原布局，仅增加被次槽占用时的明确失败反馈。次槽指向Bilibili Danmaku时提示可能影响弹幕；原生字幕隐藏时说明选轨不自动开启显示。选择器不写sub-visibility、secondary-sub-visibility、secondary-sub-ass-override或弹幕renderer，不把选轨配置接受当作已可见。此为用户确认的占用保护，替代原生select_track对另一槽selected项关闭目标槽的行为。

`track_selection/select-tracks`在同一面板实例中按视频／音轨／主字幕分组。控制层以类型＋真实ID建立会话内不复用的正整数UI身份，展示数据另外携带`display_kind`、真实`number_text`及各组独立的`current`，不把同编号跨类型轨道混为一项。提交重新核验真实类型和ID，只写白名单vid／aid／sid；当前项重选只关闭目标类型，主槽仍检查次槽占用并回读，视频成功提交沿用恢复代次。媒体或会话退休后映射及旧回调同时失效。

全部轨道绘制复用各类型原有双行布局及元信息列宽。分类与搜索组合过滤，组标题不参与选择；一块有高度上限的列表按逻辑像素滚动，绘制及鼠标命中裁切到视口，当前组标题置顶并由下一组推出。键盘移动跳过标题且保持目标行可见，Tab进入分类后左右键切换。筛选或搜索变化回到顶部，重新打开清空查询并恢复全部；普通单类型选择器保持原有行索引滚动。稳定动作`tools.selector-tracks`转到新入口，原生旧命令保留语义别名。

`track_selection/select-history`继续使用同一输入与媒体／会话代次，异步加载历史时显示加载态；关闭、切媒体或切换选择器后，旧读取回调不得更新新面板。稳定动作`file.history`与文件菜单转向该入口，ModernZ中旧精确`select/select-watch-history`选项同样兼容；受管标题右键仍打开媒体路径，保留原原生命令的语义别名。历史不是轨道当前状态，不按最新条目伪造当前标记；选择仍提交原始路径的plain loadfile，由播放器决定加载与进度恢复。

[history-data.lua](../config/script-modules/history-data.lua)读取当前`watch-history-path`及`select`的日期／去重选项，按文件逆序解析JSON行并按完整路径去重（可由已有选项关闭）。展示使用会话内不复用的正整数ID，完整路径保留给查找和延迟提示，同名条目增加父目录短名。提交前重新核对配置路径和原始字节快照；变化则刷新并要求重选，不把旧ID指向新行。坏行跳过并提示，非法时间格式回落默认格式；缺失、未启用和读取失败分别展示，不自动开启记录。

[history-store.ps1](../config/helpers/history-store.ps1)仅通过参数数组调用，读取结果在子进程stdout传回，不额外落盘历史副本或记录其内容。Read短暂拒绝写入以取得一致的UTF-8字节与SHA256；Clear在独占句柄中再次核对摘要，随后截断并刷新同一文件，保留空文件而不删除后重建。清空二次确认默认取消，针对完整文件，与搜索子集无关；不涉及媒体文件或watch-later进度。锁冲突、摘要变化及写入前失败不修改内容；开始截断后遇异常返回结果不确定并重读，不虚称记录已保留。两个操作限2 MiB，超限明确拒绝，不截断读取。已开始的Clear不因关闭面板中途撤销，迟到结果不能重新打开或改变新面板。

`track_selection/select-watch-later`复用历史行显示但不提供清空，只读取`current-watch-later-dir`中的保存记录。[watch-later-data.lua](../config/script-modules/watch-later-data.lua)保留首行媒体原路径及文件字节快照，排除redirect entry，按mtime倒序且同时间按叶名稳定排序；同名文件附父目录，保存日期不是观看时间。提交重查目录与被选文件字节，改变/删除则刷新且旧ID不复用。恢复与记录消费均由plain loadfile交回核心，不解析start来seek，也不写resume-playback或保存选项；恢复关闭时只提示，选项通知刷新不重映射行ID。

[watch-later-store.ps1](../config/helpers/watch-later-store.ps1)以异步只读子进程扫描一层目录，不落盘副本；单文件读锁取得UTF-8字节与mtime，结果经stdout传回。目录缺失、空目录、没有媒体路径、读取失败分别展示；部分文件失败保留可读项并提示。限制2048文件、单文件64KiB与总读取2MiB，超限明确拒绝或部分提示，不截断成可提交内容；跳过文件重解析点。目录改变、工作目录改变和会话退休防止旧读取结果覆盖当前面板；无法确定的跨盘相对目录拒绝读取。选择器不直接删改保存文件，恢复后由核心正常消费不属于选择器的清理动作。

`track_selection/select-subtitle-line`承接Alt+S、菜单与稳定动作subtitle.select-line，复用章节式单行布局。新增[subtitle-lines.lua](../config/script-modules/subtitle-lines.lua)读取当前主字幕来源，以本机已配置FFmpeg或PATH中的ffmpeg异步导出LRC；内嵌/外挂优先使用真实ff-index，缺失时按内嵌字幕顺序或外挂首字幕流回落，不假设sid-1就是流序号。来源签名包含媒体/轨道/格式/映射/外挂路径及可取得的本地文件元数据；不写字幕文件，不把FFmpeg诊断中的地址或字幕内容写入日志。

LRC沿原生按整数秒定位，清理HTML/ASS文本格式及绘图，按时间排序，同秒不同文本保留出现顺序、相同文本去重，逐行绑定时间防错配。列表当前标记是time-pos减当前sub-delay之前的参考行，不承诺字幕此刻可见；首批定位到参考附近，后续标记更新保留搜索/滚动/提示。提交重查来源，使用最新延迟；纯音频或静态画面沿原生加0.1秒，负目标夹到0以避免mpv从片尾倒算。取消不seek，不改字幕轨或显隐。

提取最多30秒、8MiB输出和10000行，超限拒绝不把截断内容作为完整列表。无主字幕、图形字幕、空文本、缺FFmpeg、读取失败分别反馈；不增加OCR。关闭、切主字幕/媒体或新面板取消自有任务和计时器，代次与任务身份同时屏蔽过期回调；time-pos/sub-delay观察只在面板期存在。可观察的本地文件元数据变化会刷新，远端同地址内容变化及同元数据本地替换无法可靠识别；网络认证与可读取性受既有FFmpeg能力限制，不追加转发凭据。

`track_selection/select-binding`替代执行式快捷键选择器，与设置中心的绑定编辑用途分开。[bindings-data.lua](../config/script-modules/bindings-data.lua)读取本实例input-bindings，按原生规则在priority>=0的条目中，每键优先强绑定、同强弱时取较高优先级；胜出ignore或非法命令遮住弱项而不提供可执行行。快照按键排序，行ID只在本次面板有效，名称可使用快捷键模型的静态中文标签，未知动作显示原命令；标签不重写执行目标，命令与键名均可查找。

打开前先关闭旧选择器取得正常输入快照，面板期间不观察自己的临时input-bindings。提交先校验会话，再关闭面板恢复输入，重读所选键当前生效命令并要求与快照完全相同，随后原样交给mp.command；保留引号、前缀及多命令序列，不模拟按键或拆分为shell。改绑/消失/无法复核时不执行，反馈只含中文原因，不回显原生诊断中的私有内容。动作可打开另一个选择器、设置或退出；旧提交回调不关闭新界面。恢复期间其他脚本的动态键变化可能使本次选择被保守拒绝，重新打开后取新快照，不额外引入跨脚本确认协议。

`track_selection/show-properties`承接只读属性选择器。[properties-data.lua](../config/script-modules/properties-data.lua)在打开时枚举property-list并递归取一次快照，补current-tracks四槽且去重，按路径排序；不连续观察值或把采集结果发布到userdata/磁盘。false、0、空字符串、空表和nil保持各自表示。仅mp.ARRAY元表的整数索引转换为mpv的0基路径，普通map数字/字符串键保持；特殊map键中的斜线、百分号等转义以避免显示路径冲突，这类转义名不是直接可调用的mpv属性路径。

读取期间沿原生短暂借用msg-level抑制过时属性日志，预先保存其原值及包含它的options/file-local-options树；结束或异常时仅在当前仍为借用值时恢复，不覆盖外部修改。递归32层、20000节点、单项64KiB/合计8MiB为上限，循环/超限整次失败并明确提示，不把部分快照当完整。属性不因显示而写回播放器；日志借用是唯一临时设置例外。

属性行沿既有双行布局，长预览和提示有可见省略，但搜索与选中目标保留完整快照。选择先释放输入，再按原有20秒屏幕文字显示该项；长值保留原生小字号，无VO时仅将用户明确选中的项写info日志。值内OSD控制字符先转为可见转义，ASS用escape-ass，属性展开以$>截止；值中的脚本样式/变量表达式不得改变显示或执行命令。选中仍显示打开时的值，重开才刷新；旧会话/切媒体/重试的回调不能显示旧结果。完整快照不等于任意长值都能在屏幕内一次排完，未新增编辑、复制或滚动详情页。

`track_selection/menu`替代屏幕内主菜单。[selector-menu.lua](../config/script-modules/selector-menu.lua)仅从当前媒体条件决定固定17个动作的可见性，动作ID和目标binding不来自媒体数据。主/次字幕、字幕行、音视频轨、章节、版本、设备、历史、稍后继续、执行式快捷键转到自有选择器；保持多轨/多版本/多队列等条件，字幕行额外确认主槽在当前轨列表且可提取文字。菜单提交前重新核对同ID目标仍可用，失效刷新并提示，不把可见索引当动作身份。

动态通知仅在可见ID/标题/错误状态变化时更新，保留查询与仍有效的焦点；键盘目标移位后保持在视口内，鼠标按下/抬起跨不同ID不触发。所有选择器忽略Enter/Esc的repeat事件，防止主菜单打开子面板后按住的按键立即激活新项，方向键重复保留。执行固定binding前退休旧会话并释放输入，新面板不会被旧回调关闭。

主菜单原“编辑配置/编辑快捷键”依既定入口去重合并为常用设置，原文件编辑仍在高级页。统计第1/5/4页、在线文档保持原目标，不把统计文件信息替换成MediaInfo；屏幕内队列现转到自有select-playlist入口，侧窗管理用途保持。此处不全局劫持原生select、修改stats/console或实现右键级联菜单。菜单、OSC旧精确主菜单命令及tools.selector-menu动作转到新入口，原命令为用户快捷键保留语义别名。

`track_selection/select-playlist`替代屏幕内队列选择器，保留全屏内选片用途；playlist-controls与侧窗仍负责队列管理，真实队列仍属于mpv。[playlist-selector-data.lua](../config/script-modules/playlist-selector-data.lua)为唯一有效的原生entry.id分配会话内不复用的正整数UI身份，真实ID0可用，重排保留身份；删除、同ID替换路径或身份歧义会退休旧UIid。名称遵从osd-playlist-entry，序号随真实队列顺序更新，完整路径用于搜索/提示，playing标记不以current或playlist-pos猜测。

打开时定位当前播放项，零OSD等待尺寸有效后再定位；playlist与标题选项观察仅在面板期间存在，有意义的更新保留查询和有效焦点，后续不强制跳回当前项。提交读取最新队列核验ID/路径，释放输入后再次解析最接近执行时的0基索引，才调用playlist-play-index；重选当前项仍执行原生重播。mpv没有按ID播放的原子命令，最后读取与原生命令之间仍不保证其他脚本并发修改的原子性。未新增删除、排序、入队、暂停或持久化写入。

屏幕内主菜单、工具菜单、ModernZ原精确队列命令和tools.selector-playlist均指向新入口；P侧窗切换与管理API不变。共用ASS转义前将媒体文本中的OSD C1控制码显示为可见转义，避免它们改变转义模式；后台播放仍使用控制层原始身份与路径。

### 原生播放统计外观

[stats.conf](../config/script-opts/stats.conf)只设置原生stats脚本支持的字体/等宽数字字体、文字颜色/透明度、描边/阴影和图表颜色/边框。使用Microsoft YaHei UI与Consolas，字号20沿原生默认；ASS颜色为BGR，图表BB8712对应套件强调色#1287BB。统计仍叠加画面，不增加外层窗口或固定背景面板，深色图表底色与文字描边用于可读性。

原生stats.lua仍由宿主核心提供，页面0–5、字段/顺序、图表开关、采样、分页/滚动/搜索和Tab/数字键/Esc均保持。没有设置custom_header、persistent_overlay、vidscale或任何功能选项，不改变其他OSD样式。已有同名个人stats.conf按安装器的未知/修改文件保护处理。样式配置加载与原生输出对照、实际窗口验收分别记录。

### 常用设置基础

[user-settings 模型](../config/script-modules/user-settings.lua)、[控制层](../config/scripts/user-settings.lua)和 [WPF 窗口](../config/helpers/settings-window.cs)提供八类常用设置及工具入口，完整清单和生效规则见[配置说明](configuration.md#常用设置)。`user_settings/open` 对应“工具与设置 > 常用设置…”及稳定动作 `tools.settings-editor`，不新增默认按键。高级配置编辑器和原生快捷键编辑器仍由宿主承载。

`mpvnet-user.json` 继续使用 schema 1 和平面 `settings` 对象。字段类型、数值范围、选项、搜索词、分组和时机由 Lua 模型定义；窗口按元数据构造控件并持各页草稿和载入 revision。模型复用原文 JSON 解析器，只替换本页字段，其他域和未知值保留原文。false、0、空字符串是显式值，保存请求中的 null 表示删除覆盖；新字段即使等于当前默认也保留显式选择，只有原有两项缩放继续沿用等默认省略的兼容行为。恢复默认先改草稿，保存后删除覆盖，不写受管配置。

[settings-options.lua](../config/scripts/settings-options.lua)持有播放选项的应用边界。语言、默认字幕显隐与硬解只在 `on_load` 写 `file-local-options`，位于当前文件选轨／创建解码器之前；保存和轮询不写当前解码器。全屏与置顶仅初始化一次。音量／静音为避免 mpv.net `Player_Initialized` 记忆值与 Lua 初始化竞争，冻结控制层第一次加载的启动快照，到本实例首次 `on_load` 读取宿主最终基线并应用一次；继承不写，之后的保存、轮询和换媒体不改变这一启动目标。首次损坏配置也冻结无覆盖，之后修复留待下一实例。

同一功能脚本内的多个 owner 共用分发器，内部 preview/cancel/commit 追加稳定字段 ID，避免消息注册互相覆盖。owner 支持数字、布尔和字符串；字幕位置与 ModernZ 自动避让、临时字幕调整共享基线，控制栏各选项由 ModernZ 自己同步内部布局／暂停／时间格式状态。高级工具只接受稳定白名单动作，复用宿主原有文件编辑与目录命令；不接受任意文件路径或命令。

控制层发布 `user-data/mpvnet/settings`，包含已保存值、实际值、默认来源、待生效及错误状态。功能模块通过 `user-settings.owner` 管理预览所有者、媒体代次、应用版本及条件恢复；字幕由 subtitle-controls 写属性，控制栏由 ModernZ 改自己的选项和几何。保存值总线 `settings-values` 只同步长期值；其他实例在下一媒体应用，保存实例显式 commit。提交处理主动读取最新总线，避免消息先于属性通知到达时漏应用。保存成功与运行应用失败分别报告。

切媒体结束预览而保留窗口草稿；再次预览需用户操作。后续手动变化使旧预览失去恢复权，自有字幕动作会显式失效预览。mpv 未通知的外部同值赋值无法观测，不能据此判断操作所有权。预览恢复失败保留恢复点并报错，可重开设置重试撤销。运行态标识不写入用户 JSON。

路径仍只写 `script-opts/mpvnet-local.conf`，使用独立 revision，不提供双文件事务。[settings-storage.ps1](../config/helpers/settings-storage.ps1) 的 `SaveLocal` 只接受四个已知路径键，保留未知行、注释及未改行；空值删除覆盖，重复已知键或非法新路径拒绝保存。Capture 新任务重读输出根，已开始任务的 payload 保持；程序路径在实例启动时读取。

窗口绑定父 PID、IPC 和每次打开的新 token，旧窗口消息失效。[settings-chrome.cs](../config/helpers/settings-chrome.cs)通过WindowChrome提供同底色标题栏、系统拖动／缩放和最大化／关闭按钮，ShowInTaskbar=false；按父PID枚举可见、无owner且非子窗／工具窗／不激活弹窗的窗口，选择最大有效窗口作为原生owner，不直接相信MainWindowHandle。显示前设置owner，读回GW_OWNER后才缓存；成功绑定及显式唤回时，只有原生置顶层与父窗不同时才同步，SetWindowPos不激活、不抬升owner、不移动缩放，不设置独立WPF Topmost或循环抢前台。父窗取消置顶时由Windows同步退出置顶层。控制栏DWM预览使用同一已确认句柄，并再次核对有效性与PID，避免将输入提示窗当成播放器画面。验证和NoShow模式不创建窗口句柄。IPC中断保留草稿并禁保存，父进程退出时关闭窗口。窗口消失后控制层结束其预览，仅清理自己的临时请求。回归分别见[运行层](../tests/test_user_settings.py)、[存储](../tests/test_settings_storage.py)、[窗口](../tests/test_settings_window.py)及[标题栏](../tests/test_settings_chrome.py)。

窗口创建前的IPC或请求文件失败会退休本次token，保留原状态错误并显示4秒中文提示；helper异常退出只在会话仍有效时提示，不回显其stdout诊断。用户已关闭窗口或播放器退出后的迟到结果保持静默，重试创建新会话时清除上一轮错误。正常打开、保存和关闭的接口保持。

设置控制层优先直接启动`helpers/KitSettings.exe -RequestPath <临时请求>`，避免在每次打开时启动PowerShell并编译窗口。入口[settings-host.cs](../config/helpers/settings-host.cs)运行同一`SettingsEditor`，保持STA、会话校验、JSON错误与退出码。EXE缺失时仍可使用`settings-window.ps1`源码入口；源码入口不自动预备，已经启动后的失败不盲目再开第二个窗口。保存仍交给原控制层和storage helper。

EXE存在时，控制层在初始化后延迟250ms预备一个新会话，使用`start_hidden=true`请求，保持`editor_visible=false`。窗口先载入匹配token的实时设置，在Hidden状态关联原生HWND、视觉树并完成布局，随后一次性发送`editor-prepared`；`editor-ready`只说明IPC已连接。预备期间不显示或激活窗口，也不取得预览租期。显式打开通过`editor_visible=true`快照及show消息传递意图，订阅前的点击也不丢失；首次Show前按鼠标所在屏幕工作区和原生窗口尺寸复现原居中位置，再绑定主窗并同步窗口层级，避免提前绑owner改变WPF所选屏幕。每个播放器最多一个此类进程。

正常关闭仍退休旧token并结束旧进程，再预备全新的进程和模型，草稿不跨关闭保留。旧进程退出前的显式重开继续排队，不并发新窗口。预备失败静默且不自动循环重试，用户明确打开可重新尝试；已请求打开时的异常沿原中文反馈。父播放器退出取消待预备计时器，并清理对应进程及请求文件。

IPC异步读取完成后唤醒WPF Dispatcher，每批最多64条，串行应用状态、导航和关闭后才决定显示；Run前完成的读取在Application就绪后处理，已退休会话不继续读取或显示。原100ms维护Timer仅处理父退出、超时和预览续期。导航内容仅随草稿标记变化更新，固定配色画刷冻结并在窗口内复用，避免状态通知重建未变化控件。

EXE是以.NET Framework 4.7.2为目标的确定性WinExe，DPI manifest保留system-aware窗口行为。源码与运行资产由[构建工具](../dev-tools/build-settings-window.py)记录输入摘要，普通打包校验源同步而不运行编译器；摘要校验不充当数字签名。`-ValidateOnly`／`-NoShow`供隔离回归使用，界面模型、视图与实际IPC路径保持同源。

[settings-close.cs](../config/helpers/settings-close.cs)在关闭有草稿时提供等宽“保存／不保存／取消”。保存先校验已知冲突与输入，再依分类顺序执行现有独立保存，全部确认成功才关闭；不是跨文件事务。每页写入前发送该模块的editor-refresh(token, nonce)，等待发布状态中的refresh_id匹配，再从已更新基线发起save，避免同一窗口跨JSON域保存时被尚未轮询的旧revision误拒。两控制层仅在合法token且非保存／关闭中接受有限格式nonce，刷新不写盘或改变生命周期。

逐页完成后清除对应草稿；任一失败停止后续保存，保留窗口与未保存草稿，列出已成功保存分类。保存期间阻止重入关闭。结果超时则停止自动推进并禁止重复提交，保留“不保存／取消”的退出路径，明确先前请求仍可能完成；迟到回执只更新已确认状态，不重新启动关闭流程。“不保存”只放弃未提交草稿，不回滚已成功保存的分类；“取消”只返回编辑。关闭流程与跨域确认回归见[SettingsCloseTests](../tests/test_settings_close.py)。

窗口展示由 [settings-window.cs](../config/helpers/settings-window.cs)协调，[settings-controls.cs](../config/helpers/settings-controls.cs)提供语言排序、字体选择器、固定字幕示例、路径浏览和窗口内确认层。这些控件只修改草稿，仍由原控制层保存和预览。字幕示例使用本机字体和草稿比例，不依赖媒体字幕，不保证与ASS／位图字幕排版一致。关闭确认同时统计设置和快捷键草稿；模态层禁用底层输入，关闭时恢复焦点。

控制栏窗口内画面由 [settings-preview.cs](../config/helpers/settings-preview.cs) 注册所属播放器的 DWM 实时缩略图，校验源窗口 PID，将客户区等比例显示在固定预览区域。它复用当前播放器的 ModernZ 渲染，不另起解码器、不保存截图、不转发预览区域输入。切到其他页、搜索结果或打开窗口内模态层时隐藏缩略图；设置关闭释放 DWM 句柄，源窗口最小化／不可用时隐藏画面并提示。布局按 WPF 逻辑单位转换到目标客户区，真实跨 DPI、特殊渲染器及最小化恢复仍需各自验证。

[settings-shortcuts.cs](../config/helpers/settings-shortcuts.cs)提供内嵌动作目录，窗口通过同一IPC连接额外观察`user-data/mpvnet/shortcuts`，面板沿用该模块的token／revision／save契约，不通过设置保存入口改写键位。面板持有快捷键草稿与录键状态，向窗口公开保存状态和全局搜索条目；父窗口统一底部操作和关闭确认。局部搜索、分类或失焦取消录键，全局搜索不修改草稿。两类保存串行；同一JSON的其他域修改导致revision更新时，只有本页所有保存值／覆盖标记或快捷键基线完全未变、且此前未发生冲突才跟进revision；实际本页变化仍保留草稿并禁止覆盖，最终写入继续做原文比较。

菜单只保留常用设置入口，移除重复的用户快捷键项；稳定动作`tools.shortcuts-editor`及`user_shortcuts/open`仍兼容已有用户绑定，显示名改为“打开快捷键设置…”。该入口转发固定消息`user_settings/open-shortcuts`，由设置控制层持有唯一日常编辑窗口，不再从此入口启动旧独立Editor。控制层在初始请求和设置总线发布会话内`open_page`／`open_serial`，只接受快捷键目标，启动期间的重复请求不会因窗口尚未开始观察而丢失。窗口按序号消费一次，清除全局搜索并定位快捷键，保留各页草稿；普通设置入口只唤回已有窗口。保存、内部确认层、原生路径选择器或关闭流程期间保留待跳转请求，由后续Tick在安全时机处理，不改变快捷键保存token。

关闭通知携带最后收到的导航序号。Lua仅将窗口尚未见过的新请求留到旧helper退出后重开；关闭确认中已收到并随关闭放弃的请求不重放。token退休后到进程退出之间的请求同样排队，禁止并存两个设置helper。缺少关闭序号的旧通知仍按原关闭语义处理。快捷键helper继续提供保存接口及旧独立Editor兼容代码，日常编辑由设置窗口负责。

缩放编辑使用百分比滑块；模型发布常用滑块范围和步长，底层存储合法范围保持。窗口载入时仅夹紧滑块手柄，不夹紧草稿或保存值；超范围配置继续显示原百分比，用户主动操作才换成常用范围内值。字幕标签使用“字幕缩放”，保留“字号”等搜索别名。正式设置页仅使用controlbar模式显示源客户区底部35%区域，保留全宽；几何模块的旧subtitles/full模式保留回归兼容，不再作为字幕页的日常预览。几何只依赖容器、源尺寸、模式与位置，OSC缩放值不参与自动适配。实际客户区裁切经窗口外框、客户区原点及 DWM 源纹理尺寸映射到rcSource。纯几何检查见 [SettingsPreviewGeometry](../tests/test_settings_preview.py)。

控制栏页通过 `preview-display(token, controlbar|none|renew)` 请求临时显示。控制层校验当前会话后转发 ModernZ 的 `settings-display-preview(token, begin|end|renew)`；ModernZ 持有3秒显示期限，窗口约每秒续期，续期不能重新创建已撤销的显示状态。此机制不写 visibility 偏好，也不改数值预览所有权。离页、关闭、失联超时、切媒体和显式手动显隐结束临时显示，按当前显隐／暂停策略恢复。只有预览期间的手动显隐会使旧暂停恢复点失效；未使用预览时沿用原行为。显隐回归见 [SettingsDisplay](../tests/test_settings_display.py)。

### 共享保存与既有模块

项目默认由受管配置文件提供。`mpvnet-user.json` 保存用户快捷键与常用设置覆盖，`script-opts/mpvnet-local.conf` 保存本机路径；两者都不属于安装器的受管文件集合。保存使用互斥锁、原内容比较和原子替换；Lua 保存成功后重新读取，其他实例约每秒检查同一文件。未知字段继续保留，损坏文件或不支持的 schema 保持原样。

JSON 请求校验、路径检查及原子写入由 [user-preferences-storage.cs](../config/helpers/user-preferences-storage.cs) 的 `UserPreferencesStorage` 提供，不依赖 WPF。快捷键原 `Save` 请求及 `{ok, error, conflict}` 回执保持。settings helper 额外请求 `return_written_text`，成功回执包含实际写入文本，回读时精确比对，避免把随后外部保存误认成本次结果。JSON 存储允许缺少域，但出现的 `shortcuts`、`settings` 必须为对象；字段校验由各自模型负责。

本机路径整页请求先按原文解析值计算实际变更，只校验新写入的非空值；未改的UNC／空值行和未知行保留原字节。此规则不放宽配置目标或新路径的安全检查。窗口的IPC命令采集只在ValidateOnly模式分配，正常模式直接发送，避免预览续期累积测试数据。

播放实例的临时状态与这些长期配置分开。增强选择和导出格式可跨媒体保留，但不跨重启；字幕调整和标记遵从媒体生命周期。观看记录、未知文件和第三方组件数据也不因配置包更新而自动纳管。

安装计划绑定目标目录、包内容、受管文件和恢复记录。统一维护入口的 `Apply`、`Restore`、`Recover` 都要求本次预览的校验值，持锁后再次核对。写入前保存真实备份与日志；恢复只接受日志中记录的操作前后字节，额外修改会阻止恢复。哈希用于一致性检查，不提供对恶意重写整套本地记录的认证。

统一维护与当前随包旧install／restore的写入共用`common.psm1`的目标互斥锁，目录句柄仍只负责防路径替换。旧入口在取得互斥后、目录保护后拒绝待恢复标记（包括no-op Apply）；不解析或清理新版日志。旧Restore在锁内读取状态摘要并复核活动收据和文件，写入前拒绝不得修改备份状态。CLI参数、收据格式和正常还原语义保持；用户仍须自行关闭受影响播放器。

## 辅助进程与生命周期

关于窗口由[about-window.lua](../config/scripts/about-window.lua)持有单实例helper及两份自有临时文件：不可变JSON请求保存当前实例版本和父PID，独立序号文件传递重复打开请求。[启动器](../config/helpers/about-window.ps1)校验请求与序号路径配对，[WPF窗口](../config/helpers/about-window.cs)保留父Process对象、验证owner窗口PID，每250ms消费更大的序号并唤回；父进程退出时关闭。关闭回执携带最后处理序号，Lua仅重放窗口停止读取之后的新打开请求，清理仅限本会话文件；媒体切换不关闭窗口。菜单及稳定动作`help.about`转向新入口，原命令在快捷键模型中作为语义别名保留。

版本取当前实例的`user-data/frontend/version`、`mpv-version`与`ffmpeg-version`，MediaInfo版本及各文件最后修改日期读取父进程程序所在目录。读取失败明确显示“未能读取”，不使用固定版本；原mpv.net 7.1.2关于窗的版权和GPL v2信息完整保留。自有窗口属于父播放器但不禁用播放器，不发起联网或打开外部链接；高级用户直接调用宿主底层命令仍可用。验证模式不创建句柄、计时器或显示窗口。

安装器继续由`tools/installer.ps1`持有检查计划、后台runspace、忙状态及Apply／Restore／Recover调用；[installer-ui.cs](../tools/installer-ui.cs)仅提供WinForms窗口、按钮、可选择的深色文本框和确认窗。主区显示目标、状态及一句说明，完整检查结果默认收起；右侧主按钮按状态选择播放器、执行、重新检查或完成关闭，还原独立位于左侧。安装器保留独立任务栏、双向缩放与最小化／最大化；确认窗归属于安装器，默认取消，Esc／关闭取消，摘要与可展开的完整详情分别滚动，按钮固定在右侧。确认期间禁止重入和重新检查，确认返回OK后仍走原计划token复核，核心维护模块未移入界面层。界面构建失败继续保留系统MessageBox兜底。

`KitInstallerTextBox`保留原生Edit的文本选择和复制，以自有细滚动条替代亮色系统条；滚动范围使用EM_GETRECT和实际视觉行间距，不能以Font.Height近似高DPI下的原生行高。确认文本只统一换行用于显示，不修改来源内容。安装计划的releaseNotice按字典成员读取并纳入确认正文；不能用PSObject.Properties判断字典键。此层继续采用现有system-aware DPI，不承诺真实跨屏缩放已验证。

发行包可包含`docs/upgrade-notice.txt`。包读取器只从已通过manifest摘要校验的字节读取该提示，最大4096字节；缺少提示的旧包保持兼容。维护计划通过`releaseNotice`传给图形安装器与命令行文本输出：更新确认摘要直接展示，首次安装可在确认详情中展开；恢复／还原不展示升级提示。此展示字段不改变安装、备份、冲突保护或事务顺序。

`maintenance.psm1`的`Get-KitMaintenanceReason`统一给维护计划、图形失败摘要和CLI文本输出提供中文原因；含中文路径的英文诊断仍需转换。图形详情及CLI显式`-Details`保留必要的原始技术诊断，JSON错误字段保持原契约。此函数仅负责展示，不改变错误判断、写入或恢复流程。

Capture、Playlist、快捷键、标题路径和媒体信息使用各自拥有的 UTF-8 临时 JSON 文件传参，媒体地址等数据不拼成 shell 命令。

媒体信息的旧`playback_feedback/media-info`动作转发给[media-info.lua](../config/scripts/media-info.lua)，保留原键位与Info按钮。控制层保存打开时的媒体快照及自有请求／唤回序号文件；同一媒体重复打开唤回已有窗，切换媒体后显式打开会先结束旧helper、再生成当前快照，防止两窗并存。网络请求不传URL、请求头或外部轨道地址；标题为URL时使用通用名称。播放进度变化不刷新阅读中的报告。

[media-info-window.ps1](../config/helpers/media-info-window.ps1)校验请求与序号路径配对；[数据层](../config/helpers/media-info-data.cs)读取当前父播放器目录的MediaInfo.dll，以默认Complete=0取得完整原始报告，保留未知字段和行；网络仅使用播放器可取得属性，缺失不猜测。本地读取失败保留可用概览及中文原因。[WPF视图](../config/helpers/media-info-view.cs)负责概览／详情、名称值列、无法结构化的原行、查找及复制；复制详情保留原报告，不复制过滤后的子集。父Process、owner校验、Loaded后轮询、关闭序号及NoShow边界沿关于窗口约定。报告获取与展示分离，不把MediaInfo动态字段压缩成固定概览字段。

Playlist 和快捷键窗口绑定启动它们的播放器 PID、IPC 与 token，关闭时只通知或清理自己的窗口和请求。Capture 用任务 ID、父进程及 Job Object 管理 FFmpeg，失败只清理本任务产生的文件；打开输出目录使用独立请求，不占用导出状态。切换媒体可清除可见区间，但不取消已经开始的导出；媒体代次防止旧任务结果影响新媒体标记。

Playlist在父进程仍存活时遇IPC读取失败或EOF，沿已有helper失败回执退出，由控制层显示中文提示；匹配token的关闭消息、shutdown事件和父进程已退出仍正常结束，不误报连接失败。

Playlist跟随器保持已确认的主窗句柄，不因`Process.MainWindowHandle`在菜单打开期间指向另一个窗口而改绑。首次发现或原句柄失效后按父PID查找无owner的顶层窗口，并排除子窗口、工具窗口和不激活的弹出窗口；不排除普通`WS_POPUP`，以兼容无边框／全屏主窗。主窗隐藏或最小化时保留身份并隐藏侧窗，原主窗销毁后重新发现。

Playlist 的 WinForms 展示继续位于 `playlist-window.ps1`：`PlaylistStyle` 集中当前窗口配色，客户区标题栏沿用设置窗口的视觉；`WM_NCCALCSIZE`将绘制范围扩到整个窗口，`WM_NCPAINT`／`WM_NCACTIVATE`不再进入默认系统框绘制，普通`WM_ACTIVATE`仍由Form处理。保留sizing样式、水平命中映射和 `PlaylistFollower` 的可见边缘计算。标题栏／底栏尺寸按窗口 DPI 转为物理像素。关闭按钮进入原关闭拦截并隐藏窗口；搜索按钮位于底栏右侧，复用原搜索切换，展开后依次排列输入框、计数和按钮。两按钮聚焦时 Space／Enter 留给按钮激活，列表内仍沿用播放器快捷键转发。此层不持有真实队列或改变 IPC 契约。隐藏句柄消息、命中及离屏绘制检查不等同真实跨屏与跟随验收。

`PlaylistHover`只管理悬停计时：同目标稳定停留550毫秒显示，5秒后到期，移动或换目标才重新计时；`PlaylistTip`持有并释放自己的WinForms Timer，按鼠标和工作区放置提示。隐藏、失焦、点击、搜索切换和实际原生滚动路径取消旧提示，队列内容只用于当次显示、不落盘。底部计数按钮按文字测量命中范围，不覆盖整条底栏。

Playlist普通侧窗通过`DWMWA_WINDOW_CORNER_PREFERENCE=DWMWCP_ROUND`请求Windows标准圆角，不使用自定义窗口Region或逐像素透明度。父播放器最大化／全屏时请求直角，恢复普通窗口后恢复标准圆角；句柄创建或DWM合成恢复时重新提交。属性不受支持时保留既有窗口，不阻断打开。具体裁切和半径由系统决定；隐藏句柄写入／回读只能证明属性已接受，不能替代实际圆角观感检查。

## 右键菜单展示扩展

[菜单扩展](../src/context-menu/README.md)使用宿主官方 `IExtension`；受管 DLL 位于 `config/extensions/KitContextMenu/KitContextMenu.dll`。宿主后台加载后，扩展转到现有 WPF Dispatcher，用公开的绑定目录、FindMenuItem 和 ItemsControl 所有者找到真实根菜单。仅向该根添加局部资源字典，不改全局样式，不复制菜单树，不访问私有字段，不替换点击处理。近期文件、蓝光标题、章节、轨道、配置方案、设备记忆及开关菜单的输入生命周期继续归宿主。

扩展只给精确命令增加展示标记；互斥项用圆点，开关用勾选。自有附加属性不修改宿主 IsChecked/IsCheckable 或 Tag。动态轨道和设备的 Items 集合变更时补上标记列，宿主新建的容器继续继承局部样式。静态路径存在歧义时不猜测命令映射。原快捷键提示为回退值；每次打开优先读取 `user-data/mpvnet/shortcuts` 的已应用 actions，空 keys 清空显示，未知命令和动态时长保留宿主原值。

公开 ShowMenu 事件在宿主实际打开前更新展示，Opened 为直接打开的补充。样式失败时移除自有资源和订阅并恢复原提示，父窗口释放时解除订阅。`user-data/mpvnet/context-menu` 仅发布 schema、status、style_version、source 原因码和根数量，不含个人路径。当前兼容宿主固定为 `7.1.2.0+96afc62165b5a1df186fc79c58813f37061ace9a`（内嵌.NET 10.0.1）；其他版本保留原菜单。程序集尚不能加载的宿主由其原扩展加载器处理错误，不承诺此时可发布状态。

DLL 是可重建的受管运行资产，源码和源码摘要随变更一并校验；普通包构建不执行 SDK。更新它沿用安装器的播放器运行检查、摘要、备份和还原，不写个人设置。真实跨 DPI、边缘翻转与键鼠焦点须单独验收；读取显示器 DPI 并不等于通过这些验收。

## 验证层次

Python 回归使用标准库，Lua 回归执行实际脚本并提供 mpv 替身；Windows helper 检查覆盖真实存储、控件或合成安装目录。字体替身、控件事件、真实播放器运行和用户体验分别提供不同证据，不能互相替代。测试组、环境条件及允许跳过的项目统一见[测试说明](../tests/README.md)。
