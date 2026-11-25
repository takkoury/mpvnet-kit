# 安装与个人配置维护

mpvnet-kit 0.7.0 使用单个离线安装程序，内含套件及 mpv.net 官方 Windows x64 portable ZIP。已有播放器和首次安装共用一个窗口。功能操作见[功能指南](features.md)，参数调整见[配置说明](configuration.md)。

## 1. 环境与依赖

0.7.0 安装程序面向 Windows x64，使用 .NET Framework 4.7.2 或更高版本及系统自带的 Windows PowerShell。两种安装方式都可以离线完成。已有播放器的程序与播放核心须匹配此版已验证的 mpv.net 7.1.2.0 x64 官方文件。

FFmpeg 用于片段导出和提取字幕行，Python 用于弹幕转换。两者均为可选依赖，缺少时不影响基本安装和本地播放。

## 2. 下载与安装前准备

1. 从 [Releases](https://github.com/takkoury/mpvnet-kit/releases) 下载 Windows x64 离线安装程序 `mpvnet-kit-0.7.0.exe`。
2. 退出所有 mpv.net 实例，保留原配置与备份。
3. 双击 EXE。安装程序自动校验并展开所需文件，随后显示安装窗口。

用本安装程序新装的播放器通过 `Play.cmd` 使用同一安装位置内的 `player\portable_config`。对其他已有播放器，安装器按以下顺序判断目录。

| 条件 | 使用的目录 |
| --- | --- |
| 当前环境的 `MPVNET_HOME` 指向已有有效目录 | 使用该目录；启动播放器时应保持相同环境 |
| 否则，播放器旁已有 `portable_config` | 使用该便携配置目录 |
| 否则 | 使用当前用户 Roaming AppData 下的 `mpv.net`，通常为 `%APPDATA%\mpv.net` |

若希望使用便携配置，请在选择播放器前创建空的 `portable_config`。不存在的 `MPVNET_HOME` 不会被创建；无效路径、链接目录等会被拒绝。已安装套件时，可从“工具与设置 > 常用设置… > 高级”打开配置目录；未安装时使用播放器原有配置菜单，核对后退出播放器。

## 3. 图形安装

在安装窗口中选择适合的方式。

- **已有播放器**　核对窗口识别的路径，或点“已有…”选择平时使用的 `mpvnet.exe`。选择“安装”或“更新”前，核对配置目录和备份位置。安装器只更新套件配置，原播放器和播放核心继续使用。
- **新装播放器**　点“新装…”选择空文件夹，可在选择窗口中新建文件夹。核对启动入口，再点“安装播放器”并确认。安装器校验并解压随包的官方 ZIP，再安装同一份 kit。完成后双击所选目录中的 `Play.cmd`，它会为本次启动指定便携配置。以后更新或还原时，选择其中的 `player\mpvnet.exe`。
- **遇到冲突**　查看具体原因。版本或核心未匹配时，可改选其他已有播放器，或另选空目录新装。目录已有内容时，可点“换目录”。原文件和已有备份均保留。

“查看详情”中可核对文件变更、备份位置和完整原因。新装后的“撤销本次安装”只撤销最近安装的 kit，保留官方播放器、启动入口和个人文件。

| 检查结果 | 可执行的操作 |
| --- | --- |
| 符合首次安装条件 | 安装 |
| 能够识别且可以安全更新的旧配置 | 更新 |
| 配置内容与安装包一致 | 显示“无需更新”，点击“完成”关闭 |
| 文件被修改、缺失或存在同名文件 | 停止操作，显示具体原因 |

更新前，安装器会备份并校验本次涉及的文件。完成后保留备份目录，重新启动 mpv.net。

更新确认窗口会说明新版界面、中文反馈和入口变化。读完后选择“更新”才会安装；选择“取消”保留旧版。首次安装时可在确认窗口的详情中查看这份说明。

如需撤回最近一次更新，选择“还原更新前配置”，核对范围后确认。首次安装对应的操作是“撤销本次安装”。每次只还原最近一步；完成后重新检查，可继续还原更早的操作。

常用设置、快捷键、本机路径和观看记录独立于套件更新。直接修改过 `mpv.conf` 等随包文件时，安装器会停止更新。请先保存个人差异，再按提示处理。安装器备份本次涉及的文件和安装记录，如需完整备份，请另行复制实际配置目录。

若提示上次操作未完成，可选择“恢复配置”。更新失败时恢复更新前的配置；还原失败时恢复还原开始前的配置。无法确认的文件变化会阻止恢复，请保留现有配置与备份，不要清空目录重新安装。

## 4. 可选组件准备

安装器只检查 FFmpeg 和 Python 是否能从当前 PATH 找到，不执行或下载程序。需要安装时，可参考 [FFmpeg 下载页](https://www.ffmpeg.org/download.html)和 [Python Windows 下载页](https://www.python.org/downloads/windows/)。程序不在 PATH 时，可按[本机路径说明](configuration.md#3-本机路径与外部组件)配置。

随包弹幕组件的使用条件见[弹幕说明](features.md#bilibili-弹幕)。

### 在播放器中打开公开投稿网址

如果拿到的是媒体直链，复制后在播放器按 Ctrl+Shift+V 即可播放。要打开 B 站公开投稿或 YouTube 公开视频的网页地址，可以自行添加 `yt-dlp.exe`，让播放器从网页找到音视频。

1. 在播放器右键菜单选择“工具与设置 > 常用设置…”，进入“高级”，点击“打开配置目录”。用本安装包新装播放器时，这个目录通常是安装目录下的 `player\portable_config`。
2. 从 [yt-dlp 官方发布页](https://github.com/yt-dlp/yt-dlp/releases/latest)下载 Windows x64 独立程序 `yt-dlp.exe`。把它放在刚打开的目录里，与 `mpv.conf` 放在同一层，然后重新启动播放器。无需修改系统 PATH。
3. 复制视频网址或含单个网址的分享文案。B 站也可以只复制完整 BV 号。请保留网址中的分 P 或起播时间。在播放器按 Ctrl+Shift+V，或选择“文件 > 粘贴网址”。一次粘贴多条时每行放一个网址。空队列会从第一条开播；已有队列时会按顺序追加到队尾。

B 站公开直播间也可以这样打开。复制浏览器地址栏中的完整房间网址，在播放器按 Ctrl+Shift+V。房间正在开播时即可观看，显示“直播间当前未开播”时可以稍后再打开同一个网址。

YouTube 支持普通观看页和 `youtu.be` 单视频分享链接。分享链接带有 `t=42s` 或 `t=42` 时，会从第 42 秒附近起播。使用 Clash Verge 等本机 HTTP 代理时，在代理软件里开启“系统代理”即可。每次开始播放 YouTube 视频，播放器都会读取 Windows 为该网址选用的 HTTP 代理，用它解析网页和读取音视频。换到其他媒体后，这次使用的代理随即失效。

如果 YouTube 提示解析失败，请检查系统代理并更新 yt-dlp。部分视频还需要 JavaScript 运行时，可按 [yt-dlp 的 Windows 说明](https://github.com/yt-dlp/yt-dlp/wiki/EJS#deno)将 Deno 放在 `yt-dlp.exe` 旁，再重新打开视频。

使用 yt-dlp 2026.11.23 已实测一个公开投稿的网页分享、两种手机 App 分享短链和 BV 号。若短链接打不开，可以改用浏览器地址栏里的完整投稿网址，并检查 yt-dlp 官方发布页是否有新版。已经在浏览器里选好视频，或观看需要浏览器登录状态的内容时，可以[从网页打开播放器](#从网页打开播放器)。

更新这个组件时，退出播放器，用上游新版替换自己放入的 `yt-dlp.exe`。要撤回这次添加，退出播放器后移走该文件即可。如果系统 PATH 中另有解析器，播放器仍可能找到它。使用新装包时，可在安装目录的 PowerShell 中运行 `.\Play.cmd --ytdl=no`，让本次启动停用网页解析；媒体直链仍可播放。

### 从网页打开播放器

要从 Edge 的 B 站或 YouTube 视频页调用播放器，请按 [External Player 的安装说明](https://github.com/LuckyPuppy514/external-player)准备 Tampermonkey 并安装脚本，再按 [URL Scheme Handler 的说明](https://github.com/LuckyPuppy514/url-scheme-handler)注册协议。kit 安装器不代为注册。

1. 在 Handler 中添加名为 `MPVNET` 的应用。用本安装包新装播放器时，选择安装目录中的 `player\mpvnet.exe`；给已有播放器安装 kit 时，选择当时安装 kit 的那份 `mpvnet.exe`。
2. 打开 B 站投稿页或番剧的具体分集，在 External Player 中选择 `MPVNET` 播放。浏览器首次询问是否打开外部应用时，确认打开。点击后没有播放器窗口，可先核对协议是否已注册，以及 Handler 里的程序路径是否仍然有效。
3. 如果播放器打开了，但菜单或设置和平时不同，可在“工具与设置 > 常用设置… > 高级 > 打开配置目录”查看当前目录。若显示的是 mpv.net 原版菜单，可选“打开配置文件夹”（Open Config Folder）。新装播放器应使用安装目录内的 `player\portable_config`；已有播放器应与安装 kit 时确认的配置目录一致。

想接着网页上的进度看，可以在视频页按 Ctrl+Alt+E 打开 External Player 设置，选择 `MPVNET`，在“预设事件”中勾选“同步时间”，点击“保存”。这个选项默认关闭。开启后，在 B 站普通投稿页选好分 P，再用 `MPVNET` 播放，脚本会把网页视频当时的播放位置传给播放器。

新装目录里的 `Play.cmd` 会在启动时指定这份便携配置。Handler 直接启动 `mpvnet.exe`，若浏览器继承的 `MPVNET_HOME` 指向另一有效目录，同一个播放器也会读到另一套配置。这时请先核对该变量是否仍用于其他安装，再决定是否调整；调整后需重新启动浏览器才能使用新环境。

#### 从 YouTube 当前进度续看

先确认播放器能[直接粘贴 YouTube 网址播放](#在播放器中打开公开投稿网址)，并在 Handler 中配好上面的 `MPVNET` 应用。已经能从 B 站调起同一播放器时，可以直接添加 YouTube 按钮。

1. 在 Edge 打开一个 YouTube 公开视频的普通观看页，按 Ctrl+Alt+E 打开 External Player 设置。点击左侧的“+”，名称填 `YouTube 续看`，系统选 Windows。
2. 打开[播放事件文本](../config/browser/youtube-play-event.txt)，复制全文，粘贴到新按钮的“播放事件”框。也可以从播放器的“常用设置… > 高级 > 打开配置目录”进入 `browser` 文件夹，用记事本打开 `youtube-play-event.txt`。
3. 在“预设事件”中勾选“同步时间”和“自动暂停”，勾选“启用”，点击“保存”。图标留空时，按钮显示字母 **Y**。

等正片开始后，点网页上 External Player 的 **Y**，首次弹窗时确认打开外部应用。播放器会从点击时所在的那一秒开始，网页暂停。例如网址标着 0:42，已经看到 1:17，点 **Y** 就从 1:17 续看。关闭“同步时间”时，按钮会按原网址打开视频。

这个按钮使用播放器为当前 YouTube 视频选用的 Windows 系统 HTTP 代理。B 站仍可使用原来的 `MPVNET` 按钮。要移除 YouTube 按钮，在 External Player 设置里选中 `YouTube 续看`，点击“删除”并保存。

## 5. 首次启动检查

打开一个本地视频，确认控制栏、右键菜单、暂停、播放列表和截图能够正常使用，再从“工具与设置 > 常用设置…”核对自己的设置。具体操作见[功能指南](features.md)，保存与生效时机见[常用设置说明](configuration.md#保存关闭与生效)。

## 6. 重新安装与个人配置维护

再次运行完整安装 EXE，点“已有…”选择原来的 `mpvnet.exe`，核对配置目录和备份位置。用本安装程序新装过播放器时，应选择安装目录内的 `player\mpvnet.exe`。移走整个 `portable_config` 可能影响已有播放器使用的配置目录，请先核对窗口显示的位置。

- **更新套件。** 检查结果显示“更新”后，阅读本次变更并确认。使用 v0.5.0 或更早版本时，需要自行下载新版安装程序。v0.1.0、v0.1.1 或 v0.2.0 的配置若没有安装记录，安装器会先核对旧版文件，文件完整匹配且新增路径没有冲突时才可更新。旧版功能和默认值的变化见[变更记录](../CHANGELOG.md)。
- **还原最近一次更新。** 选择“还原更新前配置”。安装器根据本次备份恢复原受管文件，移除这次更新新增的受管文件。请保留旧发行包、备份目录和安装记录。用早期安装器安装且没有还原记录时，需使用自己保存的备份。
- **保留个人设置。** 常用设置和快捷键保存在 `mpvnet-user.json`，本机路径保存在 `script-opts/mpvnet-local.conf`。还原后，旧版只读取它支持的设置。日常调整可直接使用播放器的[常用设置](configuration.md#常用设置)。

从 v0.3.0 或更早版本升级时，如果没有自定义字幕选项，普通字幕会默认显示，语言按中文、日语、英语排序。音轨没有预设优先语言。如需调整，在常用设置中保存后，从下一个媒体开始生效。

## 7. 常见安装问题

| 现象 | 处理方式 |
| --- | --- |
| 安装程序无法打开或提示文件校验失败 | 核对 EXE 的下载是否完整，确认 Windows x64 上可使用 .NET Framework 和 Windows PowerShell，再运行安装程序 |
| 操作按钮不可用 | 等待检查结束，查看具体原因；处理后可点击“重新检查” |
| 提示播放器仍在运行 | 退出所有 mpv.net 实例后重新检查 |
| 提示文件被修改或存在同名文件 | 先保存个人修改并核对差异；本版不会自动合并或覆盖，不确定时请保留原文件 |
| 未发现 FFmpeg 或 Python | 可继续基本安装；需要相应功能时再准备依赖 |
| 安装后界面未变化 | 核对安装目录是否为播放器实际读取的目录，并重新启动播放器 |
| 更新或还原未完成 | 保留配置和备份，按窗口提供的恢复操作处理；发现额外修改时会停止，不强行覆盖 |

<details>
<summary>高级说明：命令行与手动安装</summary>

需要保留一份包内文档和命令行工具时，可使用 `--extract`。指定一个尚不存在的绝对目录，其上级目录应已存在。例如在 EXE 所在目录打开 PowerShell，执行以下命令并等待完成。

```powershell
Start-Process .\mpvnet-kit-0.7.0.exe -ArgumentList '--extract "C:\Temp\mpvnet-kit-0.7.0"' -Wait
```

进入解出的目录后，可使用与图形窗口共用逻辑的 [maintain.ps1](../tools/maintain.ps1)。默认 `Inspect` 只读检查，`-OutputFormat Text` 显示中文摘要，`-Details` 显示文件明细。

```powershell
.\tools\maintain.ps1 -PlayerPath 'C:\Players\mpv.net\mpvnet.exe' -OutputFormat Text
```

完整离线包的新装路径使用 `-InstallDirectory 'C:\Players\MyPlayer'` 替代 `-PlayerPath`。先预览，再用同一目录、`-Operation Apply` 和本次 `-ExpectedPlanToken` 执行。成功后按输出的 `launcherPath` 启动，后续维护使用输出的 `playerPath`。

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

旧配置准备工具仅接受文件内容完整匹配 v0.1.0、v0.1.1 或 v0.2.0，且新版本拟添加的路径没有同名内容的配置。它备份现场全部 31 份旧版配置包文件；生成的 `legacy-snapshot` 清单只能用 `prepare-legacy.ps1 -SnapshotManifest` 校验，不能直接传给 `restore.ps1`。本版图形更新会另行创建实际更新记录，完成后可通过窗口还原到更新前。

旧 `install.ps1` 自动选择目录时，`-Apply` 须携带 `-ExpectedPlanToken`；显式目录保留直接执行的旧接口，使用前须自行核对。原 `restore.ps1` 只接受最新有效的安装备份记录。请保留工具输出的清单及整个备份目录，不手工修改记录或哈希。

这些兼容入口也会拒绝正在维护或存在未完成操作的目标。遇到未完成操作，请先在安装器中选择“恢复配置”，或使用统一命令行入口的 `Recover`，完成后再重新检查；不要改用旧命令绕过恢复。

手动安装请先备份，再按清单逐项复制配置包文件。不要整目录覆盖；手动复制不会生成自动还原记录。

</details>
