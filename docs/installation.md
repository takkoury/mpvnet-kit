# 安装与个人配置维护

本包是 Windows mpv.net 的配置与脚本包，不包含播放器。选择自己的 `mpvnet.exe` 后，安装器自动检查配置目录，确认后安装。功能见[功能指南](features.md)，个人设置见[配置说明](configuration.md)。

## 1. 环境与依赖

准备 Windows mpv.net 和系统自带的 Windows PowerShell。已有播放器可继续使用；需要下载时参考 [mpv.net 发布页](https://github.com/mpvnet-player/mpv.net/releases)及对应版本的运行要求。

FFmpeg 和 Python 是可选依赖，缺少它们不影响基本安装。

## 2. 下载与安装前准备

1. 从[公开仓库](https://github.com/Takkoury/mpvnet-kit)下载完整包，例如 Code → Download ZIP。
2. 完整解压到独立目录，找到 `Install.cmd`。不要直接从 ZIP 中运行，也不要把包解压到播放器配置目录内。
3. 退出受影响的播放器。已有配置或脚本请先自行备份并处理，安装器不会覆盖或合并它们。

安装器支持安装版和便携版，无需选择配置目录，按以下优先级自动判断：

| 条件 | 安装目录 |
| --- | --- |
| 当前环境的 `MPVNET_HOME` 指向已有有效目录 | 该目录，启动播放器时需使用相同环境 |
| 否则，播放器旁已有 `portable_config` | 该便携配置目录 |
| 否则 | 当前用户的 Roaming AppData 下 `mpv.net`，通常为 `%APPDATA%\mpv.net` |

若希望使用便携配置，请在选择播放器前自行创建空的 `portable_config`；目录不存在时会使用 AppData。不存在的 `MPVNET_HOME` 不会被创建，继续按后续条件判断。现存相对路径、卷根和链接目录会被拒绝。

播放器状态和缓存可保留；已有自定义配置、脚本或其他未知内容可能阻止安装。需要确认当前目录时，可在播放器右键菜单 **Config → Open Config Folder** 查看后退出。

## 3. 图形安装

1. 双击解压包根目录的 `Install.cmd`。
2. 点击“浏览…”，选择名为 `mpvnet.exe` 的播放器程序。
3. 等待自动检查，核对窗口显示的实际配置目录、来源和检查结果。
4. 检查通过后，点击右下角“确认安装”，核对弹窗后确认，等待“安装完成”。

窗口无需手填目录、命令参数或依赖路径。检查和安装期间请等待完成后再关闭窗口；完成后自行启动播放器。

安装器不下载依赖、不运行播放器、FFmpeg 或 Python，也不修改系统 PATH、注册表或协议设置。旧配置的备份与处理由用户负责，窗口没有备份、更新或恢复功能。

## 4. 可选组件准备

安装器仅从当前 PATH 查找 FFmpeg 和 Python，未发现仍可继续基本安装。FFmpeg 用于片段导出，Python 用于弹幕转换。优先复用已有程序；需要下载时参考 [FFmpeg 下载页](https://www.ffmpeg.org/download.html)和 [Python Windows 下载页](https://www.python.org/downloads/windows/)。

程序不在 PATH 时，可按[本机路径说明](configuration.md#3-本机路径与外部组件)手动配置，之后调整无需重装。

网页调起请按 [External Player](https://greasyfork.org/zh-CN/scripts/518677-external-player) 的说明，自行配置浏览器脚本及配套的 [URL Scheme Handler](https://github.com/LuckyPuppy514/url-scheme-handler)，将播放器路径指向自己的 `mpvnet.exe`。已有调用链可继续使用，安装器不注册协议。

本包已包含基于 [MPV-Play-BiliBili-Comments](https://github.com/itKelis/MPV-Play-BiliBili-Comments) 的兼容弹幕脚本和默认配置，无需另装原版。弹幕转换需要可用 Python 和对应弹幕数据；播放时按 D 控制弹幕显隐，使用条件见[弹幕说明](features.md#bilibili-弹幕)，样式参数见[字幕与弹幕配置](configuration.md#4-播放音频字幕与弹幕)。

## 5. 首次启动检查

打开一个已知本地视频，简单检查：

- 鼠标移到下半区，出现 ModernZ 控制栏，原右键菜单仍可用。
- Space 可以暂停，P 可以打开 Playlist。
- Screenshot 可以保存源 PNG。

更多操作见[功能指南](features.md)，配置生效规则见[配置说明](configuration.md#2-修改方法与生效规则)。

## 6. 重新安装与个人配置维护

图形安装器不升级或覆盖已有配置。更换版本前，先退出播放器，自行备份原实际配置目录和个人修改，再处理旧配置，保留对应空目录（允许的播放器状态和缓存也可保留），然后安装完整新包。

若将 `portable_config` 整个移走或删除，请重新建立空的 `portable_config`，否则安装位置可能改为 AppData。不要为通过检查直接删除未知内容，也不要把旧目录整包覆盖回新配置。

日常参数调整参考[配置说明](configuration.md)，无需重装。恢复旧配置时，退出播放器，用自己保存的备份替换实际配置目录。

安装失败时，先保留现场和日志，确认剩余内容后自行处理，再重新选择播放器检查。需要保存日志时，可选中文字复制。

## 7. 常见安装问题

| 现象 | 处理方式 |
| --- | --- |
| Install.cmd 无法打开 | 确认完整解压，`tools/installer.ps1` 和 `tools/clean-install.psm1` 存在，并可使用系统 Windows PowerShell / Windows Forms |
| “确认安装”按钮灰色 | 选择 mpvnet.exe 后等待自动检查；若未通过，按日志处理后重新选择播放器 |
| 目录已有内容或路径被拒绝 | 先自行备份处理已有配置；状态缓存可保留，其他未知内容、非空资源目录或资源目录内的空子目录可能被拒绝；使用普通目录，解压包与配置目录应分开 |
| 未发现 FFmpeg / Python | 继续基本安装，之后按配置说明准备程序和本机路径 |
| 安装成功但界面未变化 | 核对显示的安装目录与播放器实际读取目录是否一致，并重开播放器 |

<details>
<summary>高级说明：CLI 与手动安装</summary>

高级工具有独立的备份与状态逻辑，与图形安装不同。**GUI 安装不能用 CLI restore 自动恢复。**

| 工具 | 用途 |
| --- | --- |
| [check-dependencies.ps1](../tools/check-dependencies.ps1) | 必需 `PlayerPath`，只读检查依赖 |
| [install.ps1](../tools/install.ps1) | 必需 `PlayerPath`；默认预览，加 `-Apply` 后写入并备份 |
| [restore.ps1](../tools/restore.ps1) | 使用安装输出的 `backupManifest` 作为 `-BackupManifest`；默认预览，加 `-Apply` 后恢复 |

在完整包根目录运行工具前，先退出受影响播放器并核对预览。保留 CLI 输出的实际 `backupManifest` 及其整个备份目录，恢复时使用最新有效记录；不要手改凭证或哈希。CLI 的 `ConfigDirectory` 只决定复制位置，需自行确认播放器读取它。

手动安装时，先自行备份，再按 manifest 中 `config/` 开头且非 `.example` 的运行项逐项复制：去掉 `config/` 前缀，保留相对目录结构，不把整个包套进配置目录。手动复制没有 CLI 备份凭证，回退依靠自己的副本；不要覆盖未知内容。

</details>
