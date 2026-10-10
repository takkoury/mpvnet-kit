# Changelog

## 0.1.0

- 加入图形安装：只需选择 mpvnet.exe，自动判断 portable_config / AppData，并从 PATH 检查可选依赖；不备份或覆盖已有配置。
- 完成安装、功能与配置三份指南，README 使用真实界面截图展示。
- 保持原有功能范围、默认 Original 和原帧率。

## 0.1.0-preview

- 首次公开预览：仅运行配置源码、用户文档、第三方许可及文件校验清单。
- 默认 Original 与原帧率，五档增强、独立 Playlist、截图/片段格式选择和键位映射。
- 不包含开发历史、私人配置、账号、缓存、测试输出或二进制依赖。
- 可选私有路径参数与公共自动探测取代作者机器路径；此版本号不代表已创建 Tag 或 Release。

- 加入PowerShell清单安装、恢复及只读依赖检查；默认plan-only，-Apply才执行，逐文件备份及hash保护。
- 保留未知文件和私有local.conf，恢复只操作本次receipt管理的文件；不下载依赖、不管理播放器进程。

- 独立自有文件采用 MIT，第三方代码及其修改保留原许可；Anime4K 六份 MIT 与两份 Unlicense 按文件声明区分。
