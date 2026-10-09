# Component licenses

独立自有代码、配置和公开文档采用根目录 [MIT License](LICENSE)，适用文件在下方明确列出。第三方组件及其派生修改继续采用各自许可；根目录 MIT 不覆盖它们。此包提供各组件的源码、许可和来源记录。

| 组件 | 已保留的许可/说明 |
| --- | --- |
| 修改后的 ModernZ | 上游 LGPL-2.1；原导言与归属保留，见[许可](licenses/modernz/LICENSE)及[来源](licenses/modernz/NOTICE.md) |
| ModernZ 图标字体与上游图标 | [Material Symbols Apache-2.0](licenses/modernz/Material-Symbols-Apache-2.0.txt)、[Fluent MIT](licenses/modernz/Fluent-MIT.txt)，具体来源见 ModernZ notice |
| thumbfast | [MPL-2.0](licenses/thumbfast/LICENSE)及[来源](licenses/thumbfast/NOTICE.md) |
| Anime4K shader | 六份为 [MIT](licenses/anime4k/LICENSE)，两份 AutoDownscalePre 为 [Unlicense](licenses/anime4k/UNLICENSE)；文件头与[固定来源](licenses/anime4k/SOURCE.md)保留 |
| Bilibili 弹幕兼容组件 | 原[GPL许可证](config/scripts/bilibiliAssert/LICENSE)及文件头归属保留；本地兼容改动见源码 |
| 下列独立自有文件 | [MIT](LICENSE)；第三方文件与派生修改排除 |

外部播放器、Python、FFmpeg、网页插件由各自项目分发，本候选不打包这些程序。

## MIT 适用文件

以下清单对应 manifest 中 component 为 author 的文件；第三方归属文件分别按上表处理。后续新增或移植代码必须重新核对来源，不能仅凭路径推断许可。

- `.gitattributes`
- `.gitignore`
- `CHANGELOG.md`
- `LICENSE`
- `LICENSES.md`
- `README.md`
- `config/helpers/capture-media.ps1`
- `config/helpers/media-info-window.ps1`
- `config/helpers/media-path-action.ps1`
- `config/helpers/playlist-window.ps1`
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
- `config/scripts/playback-feedback.lua`
- `config/scripts/playlist-controls.lua`
- `config/scripts/subtitle-controls.lua`
- `docs/customization.md`
- `docs/installation.md`
- `docs/usage.md`
- `tools/check-dependencies.ps1`
- `tools/common.psm1`
- `tools/install.ps1`
- `tools/restore.ps1`
