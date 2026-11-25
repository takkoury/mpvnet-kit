# Component licenses

独立自有代码、配置和公开文档采用根目录 [MIT License](LICENSE)，适用文件在下方明确列出。第三方组件及其派生修改继续采用各自许可；根目录 MIT 不覆盖它们。本项目保留各组件的源码、许可和来源记录；菜单扩展 DLL 的自有源码位于源码仓库的 `src/context-menu/`，构建方法见 CONTRIBUTING。

| 组件 | 已保留的许可/说明 |
| --- | --- |
| 修改后的 ModernZ | 上游 LGPL-2.1；原导言与归属保留，见[许可](licenses/modernz/LICENSE)及[来源](licenses/modernz/NOTICE.md) |
| ModernZ 图标字体与上游图标 | [Material Symbols Apache-2.0](licenses/modernz/Material-Symbols-Apache-2.0.txt)、[Fluent MIT](licenses/modernz/Fluent-MIT.txt)，具体来源见 ModernZ notice |
| thumbfast | [MPL-2.0](licenses/thumbfast/LICENSE)及[来源](licenses/thumbfast/NOTICE.md) |
| Anime4K shader | 六份为 [MIT](licenses/anime4k/LICENSE)，两份 AutoDownscalePre 为 [Unlicense](licenses/anime4k/UNLICENSE)；文件头与[固定来源](licenses/anime4k/SOURCE.md)保留 |
| Bilibili 弹幕兼容组件 | 原[GPL许可证](config/scripts/bilibiliAssert/LICENSE)及文件头归属保留；本地兼容改动见源码 |
| 含影视画面的界面演示图片 | `overview.png`、`controls.png`、`playlist.png`、`subtitle.png`、`capture.webp` 等包含 Ruri no Houseki 影视画面，源媒体权利归原权利人；这些图片不在本项目 MIT 适用清单内 |
| 常用设置界面示意 `assets/screenshots/settings.png`、`assets/screenshots/settings-shortcuts.png` | 从本项目控件绘制，不含影视画面；采用本项目 MIT 许可 |
| 音轨选择器示意 `assets/screenshots/selector.png` | 从本项目选择器 ASS 输出离屏渲染，使用合成轨道信息，不含影视画面；采用本项目 MIT 许可 |
| 右键菜单示意 `assets/screenshots/context-menu.png` | 从真实宿主已打开的菜单控件离屏绘制，按实际屏幕坐标保留级联重叠；不含影视画面，采用本项目 MIT 许可 |
| 下列独立自有文件 | [MIT](LICENSE)；第三方文件与派生修改排除 |

离线安装 EXE 的启动器源码位于 `src/offline-installer/`，采用项目 MIT 许可。EXE 随附 [mpv.net 官方 x64 portable ZIP](https://github.com/mpvnet-player/mpv.net/releases/tag/v7.1.2.0)。播放器及其内置组件由上游维护，原归属和适用许可保留。上游附件的位置与摘要记录在包内的 `tools/portable-release.json`。Python、用于导出的 FFmpeg 命令行程序及网页插件仍由各自项目分发。

### 离线包中的上游材料

完整 EXE 中的 `licenses/mpvnet-7.1.2.0/` 收录所选播放器源码的 License.txt、MediaInfo 25.10 的许可、.NET 10.0.1 的项目许可与 Windows 组件许可索引，以及 runtime 和 WPF 的第三方声明。可按[安装指南](docs/installation.md)使用 `--extract` 将这些文件保存在本地。各份原文的来源及摘要列在包内的 `manifest.json`。[mpv.net 对应源码](https://github.com/mpvnet-player/mpv.net/tree/96afc62165b5a1df186fc79c58813f37061ace9a) · [.NET Windows 组件许可索引](https://github.com/dotnet/core/blob/68f06e817742dfcce948f6c27233f6a0017525f5/license-information-windows.md)

同目录还收录了宿主内嵌的 CommunityToolkit.Mvvm 8.4.0、Microsoft.Xaml.Behaviors.Wpf 1.1.135 和 NGettext 0.6.7 的许可，以及 CommunityToolkit.Mvvm 随包提供的第三方声明。

宿主源码中的 NGettext.Wpf 声明为 LGPL-3.0-or-later。目录中附有该组件的版权归属、LGPLv3 和 GPLv3 正文。播放核心中可识别的 mpv 和 FFmpeg 源码版本见各自仓库。[NGettext.Wpf 项目记录](https://github.com/mpvnet-player/mpv.net/blob/96afc62165b5a1df186fc79c58813f37061ace9a/src/NGettext.Wpf/NGettext.Wpf.nuspec) · [mpv](https://github.com/mpv-player/mpv/tree/85bf9f4ff46cd45686cfe2fd22f49828877db5cb) · [FFmpeg](https://github.com/FFmpeg/FFmpeg/tree/272c273d30f737632e6630458ed36a0bdbfbc3fc)

## MIT 适用文件

以下清单对应 manifest 中 component 为 author 的文件；第三方归属文件分别按上表处理。后续新增或移植代码必须重新核对来源，不能仅凭路径推断许可。

- `.gitattributes`
- `config/scripts/update-check.lua`
- `config/helpers/update-check.cs`
- `config/helpers/update-window.cs`
- `config/helpers/update-host.cs`
- `config/helpers/KitUpdate.exe`
- `config/helpers/settings-host.cs`
- `config/helpers/KitSettings.exe`
- `config/helpers/playlist-input.cs`
- `config/helpers/playlist-files.cs`
- `config/helpers/playlist-window-controls.cs`
- `config/helpers/playlist-context-menu.cs`
- `config/helpers/KitPlaylistWindow.dll`
- `config/helpers/KitPlaylistInput.exe`
- `config/script-modules/playlist-input.lua`
- `.gitignore`
- `CHANGELOG.md`
- `Install.cmd`
- `LICENSE`
- `LICENSES.md`
- `README.md`
- `assets/screenshots/settings.png`
- `assets/screenshots/settings-shortcuts.png`
- `assets/screenshots/selector.png`
- `assets/screenshots/context-menu.png`
- `config/script-opts/stats.conf`
- `config/script-modules/playlist-selector-data.lua`
- `config/script-modules/selector-menu.lua`
- `config/script-modules/properties-data.lua`
- `config/script-modules/bindings-data.lua`
- `config/script-modules/subtitle-lines.lua`
- `config/script-modules/watch-later-data.lua`
- `config/helpers/watch-later-store.ps1`
- `config/script-modules/history-data.lua`
- `config/helpers/history-store.ps1`
- `config/helpers/capture-media.ps1`
- `config/helpers/media-info-window.ps1`
- `config/extensions/KitContextMenu/KitContextMenu.dll`
- `config/helpers/media-info-data.cs`
- `config/helpers/media-info-view.cs`
- `config/scripts/media-info.lua`
- `config/helpers/media-path-action.ps1`
- `config/helpers/system-http-proxy.ps1`
- `config/browser/youtube-play-event.txt`
- `config/helpers/playlist-window.ps1`
- `config/scripts/user-shortcuts.lua`
- `config/script-modules/user-shortcuts.lua`
- `config/helpers/shortcuts-window.ps1`
- `config/helpers/shortcut-key-names.cs`
- `config/helpers/user-preferences-storage.cs`
- `config/script-modules/user-settings.lua`
- `config/scripts/user-settings.lua`
- `config/scripts/settings-options.lua`
- `config/helpers/settings-storage.ps1`
- `config/helpers/settings-window.ps1`
- `config/helpers/settings-window.cs`
- `config/helpers/about-window.cs`
- `config/helpers/about-window.ps1`
- `config/scripts/about-window.lua`
- `config/helpers/settings-controls.cs`
- `config/helpers/settings-shortcuts.cs`
- `config/helpers/settings-chrome.cs`
- `config/helpers/settings-close.cs`
- `config/helpers/settings-preview.cs`
- `config/input.conf`
- `config/mpv.conf`
- `config/mpvnet.conf`
- `config/script-modules/mpvnet-paths.lua`
- `config/script-opts/bilibiliAssert.conf`
- `config/script-opts/enhancement-controls.conf`
- `config/script-opts/modernz.conf`
- `config/script-opts/mpvnet-local.conf.example`
- `config/script-opts/thumbfast.conf`
- `config/scripts/capture-controls.lua`
- `config/scripts/enhancement-controls.lua`
- `config/scripts/motion-controls.lua`
- `config/scripts/audio-controls.lua`
- `config/scripts/feedback-osd.lua`
- `config/script-modules/feedback.lua`
- `config/scripts/playback-feedback.lua`
- `config/scripts/playlist-controls.lua`
- `config/scripts/subtitle-controls.lua`
- `config/script-modules/track-selector.lua`
- `config/scripts/track-selection.lua`
- `docs/configuration.md`
- `docs/features.md`
- `docs/installation.md`
- `docs/upgrade-notice.txt`
- `tools/check-dependencies.ps1`
- `tools/clean-install.psm1`
- `tools/common.psm1`
- `tools/install.ps1`
- `tools/portable-install.psm1`
- `tools/portable-release.json`
- `tools/installer.ps1`
- `tools/installer-ui.cs`
- `tools/restore.ps1`
- `tools/legacy-releases.json`
- `tools/legacy-install.psm1`
- `tools/prepare-legacy.ps1`
- `tools/maintenance.psm1`
- `tools/maintain.ps1`

## 仅源码仓库提供的开发文件

自有的 `AGENTS.md`、`CONTRIBUTING.md`、`docs/architecture.md`、`dev-tools/` 中的开发脚本与清单、`tests/` 中的测试代码与说明采用 MIT。这些文件仅在源码仓库提供，不随安装包分发。

`tests/fixtures/native-menu.json` 是 mpv.net 原生命令名称的测试快照，来源保留在该文件的 `source` 字段中；未包含上游实现源码。第三方运行代码、许可及演示素材仍按本页前述范围处理。
