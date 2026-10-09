# mpvnet-kit

预览版本：0.1.0-preview。独立自有代码采用 MIT；ModernZ、thumbfast、弹幕、Anime4K 与图标保留各自许可，范围及致谢见[组件许可](LICENSES.md)。

项目仓库：[Takkoury/mpvnet-kit](https://github.com/Takkoury/mpvnet-kit)。

Windows mpv.net 操作与 ModernZ 界面配置。兼容证据基线为 mpv.net 7.1.2 / libmpv 0.41；不同版本、GPU、HDR和网络来源需要另行验证。

已实现播放/字幕/音频反馈、独立 Playlist、源截图与动态片段、五档可选增强。默认 Original、保留原帧率；Anime4K 两档仅对 SDR 开放。Screenshot hover 选择 WebP/GIF/MP4 作为后续导出默认剪贴板文件格式，中键打开 Capture 根目录。原有媒体、账号和历史不属于此分发。

[安装、依赖检查与恢复](docs/installation.md) · [使用](docs/usage.md) · [定制](docs/customization.md) · [变更](CHANGELOG.md)

本项目不提供播放器/Python/FFmpeg二进制。网站调起与弹幕需要已有外部组件；不会导出 Cookie 或注册协议。完整视频下载、右键菜单重排、补帧及全文件管理不在本版范围。提供PowerShell清单安装/恢复与只读依赖检查；安装/恢复默认仅预览，明确-Apply才改目标。工具不启动或终止播放器，不自动下载依赖；先关闭受影响实例，再按安装文档执行。

部分行为有用户观察，部分为定向工具检查；不将这些证据推广为所有机器、GPU或完整视觉验收。请先备份，在可恢复的配置副本上检查自己的媒体。
