# mpvnet-custom public candidate

版本草稿：0.1.0-preview。这是未发布的本地公开候选；自有独立脚本的分发许可尚待作者选择，见[组件许可](LICENSES.md)。

Windows mpv.net 操作与 ModernZ 界面配置。兼容证据基线为 mpv.net 7.1.2 / libmpv 0.41；不同版本、GPU、HDR和网络来源需要另行验证。

已实现播放/字幕/音频反馈、独立 Playlist、源截图与动态片段、五档可选增强。默认 Original、保留原帧率；Anime4K 两档仅对 SDR 开放。Screenshot hover 选择 WebP/GIF/MP4 作为后续导出默认剪贴板文件格式，中键打开 Capture 根目录。原有媒体、账号和历史不属于此分发。

[手动安装及恢复](docs/installation.md) · [使用](docs/usage.md) · [定制](docs/customization.md) · [变更](CHANGELOG.md)

本候选不提供播放器/Python/FFmpeg二进制。网站调起与弹幕需要已有外部组件；不会导出 Cookie 或注册协议。完整视频下载、右键菜单重排、补帧及全文件管理不在本版范围。尚无 installer 或 restore 脚本；只按清单手动备份/部署。

部分行为有用户观察，部分为定向工具检查；不将这些证据推广为所有机器、GPU或完整视觉验收。请先备份，在可恢复的配置副本上检查自己的媒体。
