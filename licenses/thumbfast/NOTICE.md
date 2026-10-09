# thumbfast 来源与运行边界

2026-10-08 纳管官方 [po5/thumbfast](https://github.com/po5/thumbfast) 固定提交 `0f711de3138c9bd6718209d819ac54022c23ded2`。基础纳管时 `config/scripts/thumbfast.lua` 按上游原字节保留，包括文件头的 MPL-2.0 声明；2026-10-10 可移植候选改为下述极小本地派生，当前不再声称脚本原字节。完整许可证原文保存在本目录 [LICENSE](LICENSE)。此次只下载脚本和许可证两份官方公开文本，没有下载可执行文件、安装依赖或克隆仓库。

| 纳管文件 | 官方来源 | SHA256 |
| --- | --- | --- |
| `config/scripts/thumbfast.lua` | [固定提交脚本](https://github.com/po5/thumbfast/blob/0f711de3138c9bd6718209d819ac54022c23ded2/thumbfast.lua) | `a3d08e71eae8b892f6cd39f9593ea219768e709312d176bca883841b156448bf` |
| `licenses/thumbfast/LICENSE` | [固定提交 MPL-2.0](https://github.com/po5/thumbfast/blob/0f711de3138c9bd6718209d819ac54022c23ded2/LICENSE) | `3f3d9e0024b1921b067d6f7f88deb4a60cbe7a78e76c64e3f1d7fc3b779b9d04` |

`config/script-opts/thumbfast.conf` 使用 `network=no`，仅本地媒体请求缩略图，远程章节/时间预览保留。其余沿上游默认：spawn_first=false、quit_after_inactivity=0、direct_io=false、hwdec=false、最大宽高各200。mpv_path默认mpv表示自动发现，可明确配置绝对可执行路径。

## 2026-10-10 可移植派生

仅增加Windows backend发现、显式加载配置模块和相关失败提示；缩略图生成/协议/事件逻辑保持上游。`script-modules/mpvnet-paths.lua` 读取可选本机mpvnet-local.conf：非空mpv_path最高优先，空值尊重thumbfast.conf的显式配置；随后尝试frontend/process-path、固定PowerShell代码查询自己的数字PID可执行路径、配置目录父级已有mpvnet.exe。当前可执行路径只发现一次并缓存，不假设mpvnet.exe在PATH，不传媒体数据或任意命令行。查询输出显式UTF8，路径有空格/非ASCII时仍作为argv数据。

上表script hash是原固定上游；本地派生SHA256：`cf1a4899687b59fbb2cd6a9889b2a2044c21e7c727499cddf7295fe05f6b4d41`。MPL声明/完整LICENSE及上游来源保持。共享模块及mpvnet-local.conf.example属于随配置分发的配套，真实本机覆盖不导出。

## Windows backend 与通信

Windows自动发现复用当前已运行frontend的可执行文件，目标兼容mpv.net 7.1.2 / libmpv 0.41.0-60；不要求另装独立mpv.exe。worker使用--no-config、--load-scripts=no、无音频/字幕和rawvideo BGRA输出，不加载父播放器的完整配置。user-data/mpvnet/thumbfast-backend仅发布选择的path/source，不包含媒体URL。

Windows 默认 IPC 名称为 `thumbfast<PID>`（PID 来自父播放器的 `mp.utils.getpid()`），实际命名管道为 `\\.\pipe\thumbfast<PID>`。默认输出基础路径为 `%TEMP%\thumbfast.out<PID>`，读取 / 验证时使用 `.tmp`，有效图像移至 `.bgra`；raw BGRA 每像素 4 字节，绘制 stride 为 `4 * width`。这些临时文件位于系统临时目录，不进入仓库。

UI 通过 `script-message-to thumbfast thumb <秒数> <x> <y>` 请求，`script-message-to thumbfast clear` 清除显示。上游广播 `thumbfast-info`，JSON 字段为 `width`、`height`、`scale_factor`、`disabled`、`available`、`socket`、`thumbnail`、`overlay_id`。其中 `thumbnail` 是基础输出路径，稳定图像位于 `thumbnail + ".bgra"`；`socket` 是不含 Windows 管道前缀的 IPC 名称。可用标志不等于 worker 已经产生图像，应结合实际文件大小和对应宽高检查。

上游 [issue #163](https://github.com/po5/thumbfast/issues/163) 涉及 Windows 上旧版 subprocess `env` 字符串导致白色缩略图。此固定源码中的自定义 `env` 条件仅面向 `darwin`，Windows 不传这段自定义值；这只是源码层面对该旧问题的规避，不能代替实际 BGRA 输出或画面验收。

## 退出、移除与证据边界

上游 `shutdown` 向 worker 发出 `quit`，关闭脚本的管道文件句柄并删除基础输出及 `.bgra`；Windows 命名管道由进程 / 操作系统管理。源码没有显式删除 `.tmp`，异常或无效中间输出可能残留在系统临时目录，不能声称所有临时文件都已清理。`quit_after_inactivity=0` 表示没有闲置退出计时；文件切换、播放器关闭等行为仍由 mpv subprocess 生命周期和上游事件处理决定。

thumbfast的运行文件为scripts/thumbfast.lua与script-opts/thumbfast.conf；派生还依赖共享script-modules/mpvnet-paths.lua，该模块也供其他本地脚本使用。回退/卸载必须按当前部署清单协调这些引用及ModernZ选项，不能单独移除仍被其他脚本使用的共享模块；不删除整个 `scripts`、`script-opts`、系统临时目录或其他组件。此许可目录仅用于来源与分发记录，不部署到播放器运行配置目录。

初次纳管保留上游原字节并核对SHA256、完整许可证及Lua语法；可移植候选的派生验证另行记录，不能沿用原字节结论。播放器部署、真实 worker 输出、子进程退出、网络视频和 GUI 视觉验收由主任务后续检查，本记录不将源码检查计作运行验收。

本机首次真实检查中，自动 frontend/process-path 查找未取得可执行路径，调用缺失的 mpv 后失败；当时用本机mpv_path显式覆盖纠正，未安装新二进制。第二次本地合成素材得到300×169 BGRA、平均RGB128，worker快照无主窗口且随父实例退出、BGRA已清理；随后Seekbar模拟滚轮没有改变位置，自动运行检查未完成，按多次失败规则停止。2026-10-09用户实际反馈“功能都通过”，本批以用户功能观察收尾，未再重跑自动诊断；此前自动失败及证据边界保留，不扩为全部网络源/瞬时GUI/所有codec矩阵验收。旧失败与原测试证据留在开发仓库历史档案，不能当作本次派生的验收。
