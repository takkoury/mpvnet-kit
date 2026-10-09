# ModernZ 与图标字体来源

2026-10-07 基础试装使用 [Samillion/ModernZ](https://github.com/Samillion/ModernZ) 提交 `579897e8c974c380caa5017dc7b27a69123c1333` 的 `modernz.lua`（文件头 `v0.3.3`）与同一提交的 `modernz-icons.ttf`，该基础节点按上游原字节保留。

2026-10-08 第一轮控制栏布局开始修改本地脚本：调整默认布局的左右按钮、中央上 / 下按钮可见性和长时间文字避让，网络标题优先已有 media-title；首版观察后按用户反馈将下载放在截图左侧。随后新增局部音量 / 倍速悬停浮层，复用 ASS 元素、原鼠标分发与音量计算，通用横向 slider 未改。脚本顶部保留原导言与维护日期 / 上游提交说明。随后按明确反馈补齐音量浮层 alpha modifier、以 UI 字体选中色 `#1287bb` 替代当前速度圆点，并为预设选择使用原生 `osd-msg set speed`；按钮左键屏蔽由精简配置维护。用户图示反馈后，将音量轨道 / 填充 / 滑钮分为独立 ASS event 并用明确定位及零基 bounds，浮层展开时抑制其 anchor 原 tooltip；修正选中色 converter 的输入为 `#1287bb`。该浮层图示修正节点的本地脚本 SHA256 为 `58fda6127f930cc93fcfdc6de08a7c80ff9830947f738e4b218ee7a4f58106a4`。字体没有修改，下表脚本 hash 是上游原始快照，不能作为当前本地脚本 hash。

- 脚本遵循上游 LGPL-2.1，完整原文保存在本目录 [LICENSE](LICENSE)。脚本原有导言、派生项目和 mpv OSC 归属保留。
- 上游 README 将图标归属列为 Google [Material Symbols](https://github.com/google/material-design-icons)（Apache-2.0）与 Microsoft [Fluent System Icons](https://github.com/microsoft/fluentui-system-icons)（MIT）；部分图标由 ModernZ 修改或创建。对应完整许可证与 Microsoft 原 copyright notice 分别保存在 [Material-Symbols-Apache-2.0.txt](Material-Symbols-Apache-2.0.txt) 和 [Fluent-MIT.txt](Fluent-MIT.txt)。
- 此目录用于仓库分发与来源记录，不部署到播放器配置目录。回退或卸载仅按 README 对应部署清单处理，不删除许可记录或其他组件。

来源与 SHA256：

| 内容 | 官方来源 | SHA256 |
| --- | --- | --- |
| ModernZ 脚本 | [固定提交脚本](https://github.com/Samillion/ModernZ/blob/579897e8c974c380caa5017dc7b27a69123c1333/modernz.lua) | `6f622f138931a0b3b019fd17fb7d85febf0d0b733948a814ab54ec1c40ed2268` |
| 图标字体 | [固定提交字体](https://github.com/Samillion/ModernZ/blob/579897e8c974c380caa5017dc7b27a69123c1333/modernz-icons.ttf) | `5033b84d569502538968c6f23b0859bda790eed85c10e419b0759537ec60a016` |
| LGPL-2.1 | [固定提交许可证](https://github.com/Samillion/ModernZ/blob/579897e8c974c380caa5017dc7b27a69123c1333/LICENSE) | `20c17d8b8c48a600800dfd14f95d5cb9ff47066a9641ddeab48dc54aec96e331` |
| Fluent MIT | [Microsoft 官方 LICENSE](https://github.com/microsoft/fluentui-system-icons/blob/main/LICENSE)，本次读取快照 | `69bc45dc42b9acb96a69823adbc6ae538374e3c0bde169b855b32c48eaaef52f` |
| Material Apache-2.0 | [Google 官方 LICENSE](https://github.com/google/material-design-icons/blob/master/LICENSE)，本次读取快照 | `58d1e17ffe5109a7ae296caafcadfdbe6a7d176f0bc4ab01e12a689b0499d8bd` |

2026-10-08后续维护增加已明确的播放/窗口/字幕反馈、视频Mouse分区、Seekbar click/drag/exact/wheel与预览Title隐藏及纵向栈；2026-10-09按用户截图将默认预览Chapter/Time文字组与thumbnail横向锚点独立。上述均为现有维护文件局部修改，实际当前hash以Git与部署清单为准，不继续自称前述图示节点hash。thumbfast原字节独立组件使用MPL-2.0，来源与完整许可见 ../thumbfast/，没有替换ModernZ或图标许可证。
