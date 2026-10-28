# 开发架构与状态边界

本文帮助维护者定位模块、接口和状态归属，仅随源码仓库提供。开发与验证命令见 [CONTRIBUTING](../CONTRIBUTING.md)，用户操作和参数分别见[功能指南](features.md)与[配置说明](configuration.md)。模块接口以链接中的源码为准。

## 模块与入口

mpv.net 承载播放器窗口、原生菜单和 libmpv；`config/` 安装到播放器实际读取的配置根目录。Lua 脚本通过 mpv 属性、`script-binding` 和 `script-message-to` 协作，Windows 辅助窗口通过当前实例的 IPC 通道与 Lua 控制层通信。

| 模块 | 入口与接口 | 状态归属及主要回归 |
| --- | --- | --- |
| 默认配置与菜单 | [mpv.conf](../config/mpv.conf)、[mpvnet.conf](../config/mpvnet.conf)、[input.conf](../config/input.conf)；菜单和键位调用宿主命令或脚本动作 | 文件保存项目默认，运行时属性由播放器持有；[菜单与默认键检查](../tests/test_context_menu.py) |
| 控制栏 | [modernz.lua](../config/scripts/modernz.lua)；读取 `user-data/mpvnet/capture`、`enhancement`，向对应脚本发送动作 | ModernZ 管理布局、浮层、输入区域和字幕避让，不保存用户长期偏好；[响应式布局](../tests/test_responsive_osc.py)、[提示](../tests/test_control_tooltips.py)、[区间标记](../tests/test_seekbar_markers.py) |
| 播放与字幕 | [playback-feedback.lua](../config/scripts/playback-feedback.lua)、[subtitle-controls.lua](../config/scripts/subtitle-controls.lua)；键盘与菜单调用已注册动作，必要时调用媒体信息或路径辅助程序 | 临时加速、Mark 和字幕调整由所属脚本管理；媒体切换时按各自规则恢复或清理；[失败反馈](../tests/test_failure_feedback.py)、[字幕](../tests/test_subtitle_controls.py) |
| 用户快捷键 | [模型](../config/script-modules/user-shortcuts.lua)定义动作和覆盖规则；[控制层](../config/scripts/user-shortcuts.lua)加载、应用并发布 `user-data/mpvnet/shortcuts`；[窗口](../config/helpers/shortcuts-window.ps1)接收 `-RequestPath` | `mpvnet-user.json` 保存长期覆盖，稳定动作 ID 对应键位，不接收任意命令；[模型与运行层](../tests/test_user_shortcuts.py)、[原子保存](../tests/test_user_preferences.py)、[窗口](../tests/test_shortcuts_window.py) |
| 播放列表 | [playlist-controls.lua](../config/scripts/playlist-controls.lua)通过 `-PayloadPath` 启动 [playlist-window.ps1](../config/helpers/playlist-window.ps1)，以 token 校验回传动作，并读取快捷键映射 | 真实队列和条目 ID 属于 mpv，窗口只维护搜索、选择和布局；[队列控制](../tests/test_playlist_controls.py)、[窗口与几何](../tests/test_playlist_window.py) |
| 截图与片段 | [capture-controls.lua](../config/scripts/capture-controls.lua)以 `-PayloadPath` 调用 [capture-media.ps1](../config/helpers/capture-media.ps1)，将结果发布给控制栏 | Lua 持有 A/B、媒体代次、忙状态、所选格式和最近结果；helper 管理本次输出、FFmpeg 及临时文件；[单格式导出](../tests/test_capture_single_format.py) |
| 画面增强 | [enhancement-controls.lua](../config/scripts/enhancement-controls.lua)接收 `set-preset`，发布 `user-data/mpvnet/enhancement` | 实例保留选择，每个媒体重新捕获基准；写入受控属性失败时尝试回滚；[增强回归](../tests/test_enhancement_controls.py) |
| 外部组件与本机路径 | [mpvnet-paths.lua](../config/script-modules/mpvnet-paths.lua)读取可选路径；[thumbfast.lua](../config/scripts/thumbfast.lua)管理缩略图子进程；[弹幕入口](../config/scripts/bilibiliAssert/main.lua)调用随包转换器 | 本机路径文件属于用户；缩略图及弹幕任务由各自组件清理，弹幕使用独立副字幕轨；[弹幕转换](../tests/test_danmaku.py)，第三方边界见 [LICENSES](../LICENSES.md) |
| 安装与恢复 | [installer.ps1](../tools/installer.ps1)和 [maintain.ps1](../tools/maintain.ps1)共用 [maintenance.psm1](../tools/maintenance.psm1)，复用目录识别、安装、旧版备份与恢复模块 | 安装包 manifest、目标 receipt、备份和未完成操作日志分别保存包内容、安装身份与恢复状态；[目标识别](../tests/test_install_targets.py)、[旧版备份](../tests/test_legacy_backup.py)、[维护事务](../tests/test_maintenance.py)、[用户状态保留](../tests/test_user_settings_upgrade.py) |
| 构建与发行准备 | [build-package.py](../dev-tools/build-package.py)按 [package-map.json](../dev-tools/package-map.json)生成包及 manifest；[prepare-release.py](../dev-tools/prepare-release.py)检查并生成 ZIP | 两入口共用 [package_lib.py](../dev-tools/package_lib.py) 的 `stage_package`／`package_zip`，分别负责目录写入和 ZIP 创建；显式清单决定交付范围，开发文档与测试不入包；[构建回归](../tests/test_package_build.py) |

## 配置与状态所有权

### 常用设置基础

[user-settings 模型](../config/script-modules/user-settings.lua)、[控制层](../config/scripts/user-settings.lua)和 [WPF 窗口](../config/helpers/settings-window.cs)目前贯通字幕字号、窗口控制栏缩放及独立路径页。入口为 `user_settings/open`；正式菜单接入与其他设置属于后续批次。

`mpvnet-user.json` 继续使用 schema 1，新增平面 `settings` 对象，字段为 `sub-scale` 和 `modernz.scalewindowed`。窗口持各页草稿和载入时 revision；模型复用快捷键的原文 JSON 解析器，只替换本页字段，其他域和未知值保留原文。恢复默认先改草稿，保存后删除对应覆盖；默认取功能模块启动时的真实配置。

控制层发布 `user-data/mpvnet/settings`，包含已保存值、实际值、默认来源、待生效及错误状态。功能模块通过 `user-settings.owner` 管理预览所有者、媒体代次、应用版本及条件恢复；字幕由 subtitle-controls 写属性，控制栏由 ModernZ 改自己的选项和几何。保存值总线 `settings-values` 只同步长期值；其他实例在下一媒体应用，保存实例显式 commit。提交处理主动读取最新总线，避免消息先于属性通知到达时漏应用。保存成功与运行应用失败分别报告。

切媒体结束预览而保留窗口草稿；再次预览需用户操作。后续手动变化使旧预览失去恢复权，自有字幕动作会显式失效预览。mpv 未通知的外部同值赋值无法观测，不能据此判断操作所有权。预览恢复失败保留恢复点并报错，可重开设置重试撤销。运行态标识不写入用户 JSON。

路径仍只写 `script-opts/mpvnet-local.conf`，使用独立 revision，不提供双文件事务。[settings-storage.ps1](../config/helpers/settings-storage.ps1) 的 `SaveLocal` 只接受四个已知路径键，保留未知行、注释及未改行；空值删除覆盖，重复已知键或非法新路径拒绝保存。Capture 新任务重读输出根，已开始任务的 payload 保持；程序路径在实例启动时读取。

窗口绑定父 PID、IPC 和每次打开的新 token，旧窗口消息失效。正常关闭有草稿时列出分类并确认放弃，保存期间禁止关闭；IPC 中断保留草稿并禁保存，父进程退出时关闭窗口。窗口消失后控制层结束其预览，仅清理自己的临时请求。回归分别见[运行层](../tests/test_user_settings.py)、[存储](../tests/test_settings_storage.py)及[窗口](../tests/test_settings_window.py)。

窗口内画面由 [settings-preview.cs](../config/helpers/settings-preview.cs) 注册所属播放器的 DWM 实时缩略图，校验源窗口 PID，将客户区等比例显示在固定预览区域。它复用当前播放器的字幕和 ModernZ 渲染，不另起解码器、不保存截图、不转发预览区域输入。路径页隐藏画面；设置关闭释放 DWM 句柄，源窗口最小化／不可用时隐藏画面并提示。布局按 WPF 逻辑单位转换到目标客户区，真实跨 DPI、特殊渲染器及最小化恢复仍需各自验证。

控制栏页通过 `preview-display(token, controlbar|none|renew)` 请求临时显示。控制层校验当前会话后转发 ModernZ 的 `settings-display-preview(token, begin|end|renew)`；ModernZ 持有3秒显示期限，窗口约每秒续期，续期不能重新创建已撤销的显示状态。此机制不写 visibility 偏好，也不改数值预览所有权。离页、关闭、失联超时、切媒体和显式手动显隐结束临时显示，按当前显隐／暂停策略恢复。只有预览期间的手动显隐会使旧暂停恢复点失效；未使用预览时沿用原行为。显隐回归见 [SettingsDisplay](../tests/test_settings_display.py)。

### 共享保存与既有模块

项目默认由受管配置文件提供。`mpvnet-user.json` 保存用户快捷键与常用设置覆盖，`script-opts/mpvnet-local.conf` 保存本机路径；两者都不属于安装器的受管文件集合。保存使用互斥锁、原内容比较和原子替换；Lua 保存成功后重新读取，其他实例约每秒检查同一文件。未知字段继续保留，损坏文件或不支持的 schema 保持原样。

JSON 请求校验、路径检查及原子写入由 [user-preferences-storage.cs](../config/helpers/user-preferences-storage.cs) 的 `UserPreferencesStorage` 提供，不依赖 WPF。快捷键原 `Save` 请求及 `{ok, error, conflict}` 回执保持。settings helper 额外请求 `return_written_text`，成功回执包含实际写入文本，回读时精确比对，避免把随后外部保存误认成本次结果。JSON 存储允许缺少域，但出现的 `shortcuts`、`settings` 必须为对象；字段校验由各自模型负责。

播放实例的临时状态与这些长期配置分开。增强选择和导出格式可跨媒体保留，但不跨重启；字幕调整和标记遵从媒体生命周期。观看记录、未知文件和第三方组件数据也不因配置包更新而自动纳管。

安装计划绑定目标目录、包内容、受管文件和恢复记录。统一维护入口的 `Apply`、`Restore`、`Recover` 都要求本次预览的校验值，持锁后再次核对。写入前保存真实备份与日志；恢复只接受日志中记录的操作前后字节，额外修改会阻止恢复。哈希用于一致性检查，不提供对恶意重写整套本地记录的认证。

## 辅助进程与生命周期

Capture、Playlist、快捷键和标题路径操作使用各自拥有的 UTF-8 临时 JSON 文件传参，媒体地址等数据不拼成 shell 命令。Media Info 仍通过 `stdin_data` 传递字段；改接口时应检查对应调用方，不能假定所有 helper 使用相同传输方式。

Playlist 和快捷键窗口绑定启动它们的播放器 PID、IPC 与 token，关闭时只通知或清理自己的窗口和请求。Capture 用任务 ID、父进程及 Job Object 管理 FFmpeg，失败只清理本任务产生的文件；打开输出目录使用独立请求，不占用导出状态。切换媒体可清除可见区间，但不取消已经开始的导出；媒体代次防止旧任务结果影响新媒体标记。

## 验证层次

Python 回归使用标准库，Lua 回归执行实际脚本并提供 mpv 替身；Windows helper 检查覆盖真实存储、控件或合成安装目录。字体替身、控件事件、真实播放器运行和用户体验分别提供不同证据，不能互相替代。测试组、环境条件及允许跳过的项目统一见[测试说明](../tests/README.md)。
