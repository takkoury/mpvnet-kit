# 安装与个人配置维护

mpvnet-kit 是面向 Windows mpv.net 的配置与脚本包，不包含播放器。功能操作见[功能指南](features.md)，参数调整见[配置说明](configuration.md)。

**版本说明：**本文适用于 0.3.0。旧版用户请使用随包指南；v0.2.0 的图形安装器仅支持首次安装。

## 1. 环境与依赖

准备 Windows mpv.net 和系统自带的 Windows PowerShell。播放器可从 [mpv.net 发布页](https://github.com/mpvnet-player/mpv.net/releases)获取。当前已验证的播放器基线为 mpv.net 7.1.2 / libmpv 0.41；其他版本尚未完成验证。

FFmpeg 用于片段导出，Python 用于弹幕转换。两者均为可选依赖，缺少时不影响基本安装和本地播放。

## 2. 下载与安装前准备

1. 从 [v0.3.0 Release](https://github.com/Takkoury/mpvnet-kit/releases/tag/v0.3.0) 下载 [mpvnet-kit-0.3.0.zip](https://github.com/Takkoury/mpvnet-kit/releases/download/v0.3.0/mpvnet-kit-0.3.0.zip)。
2. 完整解压到独立目录。不要直接从 ZIP 中运行，也不要将安装包解压到播放器的配置目录内。
3. 退出所有 mpv.net 实例。已有配置无需预先清空；不要为通过检查直接删除文件。

安装器只需选择 `mpvnet.exe`，随后按以下顺序确定配置目录：

| 条件 | 使用的目录 |
| --- | --- |
| 当前环境的 `MPVNET_HOME` 指向已有有效目录 | 使用该目录；启动播放器时应保持相同环境 |
| 否则，播放器旁已有 `portable_config` | 使用该便携配置目录 |
| 否则 | 使用当前用户 Roaming AppData 下的 `mpv.net`，通常为 `%APPDATA%\mpv.net` |

若希望使用便携配置，请在选择播放器前创建空的 `portable_config`。不存在的 `MPVNET_HOME` 不会被创建；无效路径、链接目录等会被拒绝。可通过播放器的配置菜单打开配置目录，核对后退出播放器。

## 3. 图形安装

双击安装包中的 `Install.cmd`，点击“浏览…”选择 `mpvnet.exe`。选择播放器后，窗口会显示配置目录、安装包版本、文件变更和备份位置。

| 检查结果 | 可执行的操作 |
| --- | --- |
| 符合首次安装条件 | 开始安装 |
| 能够识别且可以安全更新的旧配置 | 开始更新 |
| 配置内容与安装包一致 | 无需更新 |
| 文件被修改、缺失或存在同名文件 | 停止操作，显示具体原因 |

执行前请退出所有 mpv.net 实例。更新前会自动备份相关文件，备份校验通过后才开始写入；安装器不会自动关闭或启动播放器。完成后请保留备份目录，并重新启动 mpv.net。

如需撤回最近一次更新，选择“还原更新前配置”，核对范围后确认。首次安装对应的操作是“撤销本次安装”。每次只还原最近一步；完成后重新检查，可继续还原更早的操作。

独立保存的快捷键设置、本机路径配置、观看记录和其他个人文件保持不变。直接修改配置包中的文件，例如 `mpv.conf`，会阻止自动更新；本版不合并这些修改。备份包含配置包涉及的文件和安装记录，**不等于整个配置目录的完整副本**。

若提示上次操作未完成，可选择“恢复操作前配置”。更新失败时恢复更新前的配置；还原失败时恢复还原开始前的配置。无法确认的文件变化会阻止恢复，请保留现有配置与备份，不要清空目录重新安装。

## 4. 可选组件准备

安装器只检查 FFmpeg 和 Python 是否能从当前 PATH 找到，不执行或下载程序。需要安装时，可参考 [FFmpeg 下载页](https://www.ffmpeg.org/download.html)和 [Python Windows 下载页](https://www.python.org/downloads/windows/)。程序不在 PATH 时，可按[本机路径说明](configuration.md#3-本机路径与外部组件)配置。

网页调起可配合 [External Player](https://greasyfork.org/zh-CN/scripts/518677-external-player) 和 [URL Scheme Handler](https://github.com/LuckyPuppy514/url-scheme-handler) 使用，由用户按各自说明配置，安装器不注册协议。随包弹幕组件的使用条件见[弹幕说明](features.md#bilibili-弹幕)。

## 5. 首次启动检查

打开一个本地视频，确认控制栏、右键菜单、暂停、播放列表和截图能够正常使用。具体操作见[功能指南](features.md)，配置生效方式见[配置说明](configuration.md#2-修改方法与生效规则)。

## 6. 重新安装与个人配置维护

优先使用窗口提供的更新或还原操作，无需清空配置目录。v0.2.0 没有这些功能，恢复旧配置需使用此前自行保存的备份。

不要将旧目录整包覆盖到新配置，也不要删除备份来消除提示。若移走了整个 `portable_config`，安装器可能转而选择 AppData；再次操作前应核对窗口显示的目录。

日常参数调整无需重装。直接修改配置包文件前，建议保存副本，并留意这类修改可能影响后续更新。

## 7. 常见安装问题

| 现象 | 处理方式 |
| --- | --- |
| `Install.cmd` 无法打开 | 确认安装包已完整解压，并可使用系统 Windows PowerShell 与 Windows Forms |
| 操作按钮不可用 | 等待检查结束，查看具体原因；处理后可点击“重新检查” |
| 提示播放器仍在运行 | 退出所有 mpv.net 实例后重新检查 |
| 提示文件被修改或存在同名文件 | 先保存个人修改并核对差异；本版不会自动合并或覆盖，不确定时请保留原文件 |
| 未发现 FFmpeg 或 Python | 可继续基本安装；需要相应功能时再准备依赖 |
| 安装后界面未变化 | 核对安装目录是否为播放器实际读取的目录，并重新启动播放器 |
| 更新或还原未完成 | 保留配置和备份，按窗口提供的恢复操作处理；发现额外修改时会停止，不强行覆盖 |

<details>
<summary>高级说明：命令行与手动安装</summary>

建议使用与图形窗口共用逻辑的 [maintain.ps1](../tools/maintain.ps1)。默认 `Inspect` 只读检查，`-OutputFormat Text` 显示中文摘要，`-Details` 显示文件明细。

```powershell
.\tools\maintain.ps1 -PlayerPath 'C:\Players\mpv.net\mpvnet.exe' -OutputFormat Text
```

所有写入操作都需要本次检查返回的校验值：安装或更新使用 `Apply` 和 `planToken`；还原使用 `Restore` 和 `restorePlanToken`；恢复未完成操作使用 `Recover` 和该恢复计划的 `planToken`。执行时保持检查所用的目录和安装包参数不变；环境或文件发生变化后，请重新检查。

```powershell
$plan = .\tools\maintain.ps1 -PlayerPath 'C:\Players\mpv.net\mpvnet.exe' | ConvertFrom-Json
# 审阅 $plan 并退出所有 mpv.net 实例后，再执行：
.\tools\maintain.ps1 -PlayerPath 'C:\Players\mpv.net\mpvnet.exe' -Operation Apply -ExpectedPlanToken $plan.planToken -OutputFormat Text
```

`ConfigDirectory` 可显式指定目标，但不会改变播放器实际读取的配置位置。`BackupRoot` 可指定独立备份位置，后续维护应使用同一备份根目录。校验值用于确认计划未变化，不是签名或密码。

| 工具 | 用途与边界 |
| --- | --- |
| [maintain.ps1](../tools/maintain.ps1) | 统一维护入口，提供运行检查及未完成操作恢复 |
| [check-dependencies.ps1](../tools/check-dependencies.ps1) | 本地只读依赖检查，结果可能包含完整路径 |
| [prepare-legacy.ps1](../tools/prepare-legacy.ps1) | 识别无安装记录的旧配置并备份，不执行更新 |
| [install.ps1](../tools/install.ps1) | 保留的高级安装接口，默认预览，`-Apply` 写入；不替代统一维护入口 |
| [restore.ps1](../tools/restore.ps1) | 按对应安装记录还原，默认预览，`-Apply` 执行 |

旧配置准备工具仅接受完整匹配 v0.1.0、v0.1.1 或 v0.2.0 且无新增路径碰撞的内容，备份现场全部31份配置包文件。其 `legacy-snapshot` 清单只能用 `prepare-legacy.ps1 -SnapshotManifest` 校验，不能直接传给 `restore.ps1`。本版图形更新会另外创建实际更新记录；v0.2.0 的旧GUI安装没有这类记录，仍需依靠自己的备份。

旧 `install.ps1` 自动选择目录时，`-Apply` 须携带 `-ExpectedPlanToken`；显式目录保留直接执行的旧接口，使用前须自行核对。原 `restore.ps1` 只接受最新有效的安装备份记录。请保留工具输出的清单及整个备份目录，不手工修改记录或哈希。

手动安装请先备份，再按清单逐项复制配置包文件。不要整目录覆盖；手动复制不会生成自动还原记录。

</details>
