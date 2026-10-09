# 安装、检查与恢复

本候选面向Windows mpv.net，兼容证据基线7.1.2 / libmpv 0.41。请使用自己的播放器与配置目录；先关闭受影响播放器。工具不启动、关闭或终止播放器，不提供GUI安装器、不下载依赖、不改系统PATH或协议注册。

流程为：只读依赖检查 → 安装计划预览 → 明确Apply安装 → 恢复计划预览 → 明确Apply恢复。安装与恢复默认只输出计划，只有传入-Apply才修改目标。

PlayerPath指定已有播放器exe，默认目标由其所在目录推导为portable_config。ConfigDirectory可覆盖目标目录，但用户须自行保证播放器确实读取它。BackupRoot默认在用户LocalAppData下mpvnet-kit/backups，备份与receipt属于用户状态，不放入源码包；目标sidecar为.mpvnet-kit-install.json，备份manifest记录receipt字节hash和逐文件旧/新状态。

## 命令顺序

在解压后的包根目录打开PowerShell，先关闭受影响播放器。下面示例的播放器路径是通用示例，请替换为自己的已有exe。ExecutionPolicy Bypass仅用于这次PowerShell进程，不修改系统策略。

```powershell
# 1. 只读依赖检查
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\check-dependencies.ps1 -PlayerPath 'C:\Apps\mpv.net\mpvnet.exe'

# 2. 安装预览：JSON计划，不写目标
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\install.ps1 -PlayerPath 'C:\Apps\mpv.net\mpvnet.exe'

# 3. 确认目标与备份路径后执行
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\install.ps1 -PlayerPath 'C:\Apps\mpv.net\mpvnet.exe' -Apply
```

保留安装JSON结果的backupManifest路径。需要恢复时先关闭受影响播放器，将下面通用示例改为该次安装的实际manifest文件路径：

```powershell
# 4. 恢复预览
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\restore.ps1 -BackupManifest 'C:\Backups\mpvnet-kit\install-backup\manifest.json'

# 5. 确认恢复计划后执行
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\restore.ps1 -BackupManifest 'C:\Backups\mpvnet-kit\install-backup\manifest.json' -Apply
```

| 工具 | 参数 |
| --- | --- |
| install.ps1 | 必需PlayerPath；可选ConfigDirectory、BackupRoot、PackageRoot；Apply执行 |
| restore.ps1 | 必需BackupManifest；Apply执行 |
| check-dependencies.ps1 | 必需PlayerPath；可选ConfigDirectory、PackageRoot；始终只读JSON |

默认PackageRoot由包位置确定；不要把它指向另一份未核对的包。若覆盖ConfigDirectory，请对检查与安装使用同一个值，并自行确认mpv.net读取它。默认备份位置为用户LocalApplicationData下mpvnet-kit/backups。

## 清单范围与保护

安装仅复制manifest中31份运行配置；mpvnet-local.conf.example留在包内、不安装。未知文件、真实script-opts/mpvnet-local.conf、settings.xml、缓存、历史和媒体不覆盖。licenses/与用户文档随源码包保留，不部署到播放器配置目录。

每次执行先核包文件与目标hash，对原本存在的目标逐项保存备份和旧hash，对原本不存在的目标记录新增所有权。只有运行目标路径集合相同的包支持直接更新；未来版本改变集合时，须先恢复旧部署再安装新包，不能假定任意版本都平滑更新。重复安装及恢复若发现受管目标被外部修改则停止；先保存差异并人工决定，工具没有绕过保护的强制覆盖入口。部署前再次检查目标状态。

恢复按对应receipt逐项核当前部署hash：恢复原来存在的文件；仅删除本次新增且仍匹配hash的受管文件。不删除整个配置目录、Capture输出或未知文件。只允许当前最新receipt恢复，避免乱序覆盖；旧备份保留，不自动清理。

## 中断与人工恢复边界

多文件安装/恢复不是完整原子事务。执行失败时工具尽力回滚，或在备份目录保留status与备份记录；不能承诺所有故障都自动恢复。看到rollback-incomplete或restore-incomplete时，先检查记录、当前文件hash和备份，必要时按逐文件旧状态人工恢复；不要盲目再次-Apply。

目标owner receipt引用的备份丢失或不匹配会被拒绝，工具不会自动接管现有部署或猜测旧文件。请保留receipt对应的备份目录和manifest，不能只保存目标sidecar。恢复成功也不自动清理旧备份。

## 可选依赖与个人配置

基本UI使用现有mpv.net，Capture片段导出需要FFmpeg，弹幕转换需要Python；缺少这些可选依赖不等于基本UI不可安装。缩略图需要可用播放器worker。依赖检查是只读的路径/文件元数据检查，不启动这些程序，结果不能当作运行功能验收。

完成受管复制后，再按[定制](customization.md)创建或调整私有script-opts/mpvnet-local.conf。capture_root、ffmpeg_path、python_path、mpv_path的非空识别值优先，空值遵循公共自动探测与组件原选项。该私有文件不在manifest清单中，安装不会覆盖它。

独立Info/Playlist侧窗使用Windows PowerShell/WinForms。网页调起复用用户已有外部脚本/handler，不导账号或Cookie；工具不替用户注册协议。默认Original与原帧率，公共target-trc=auto；不同显示器/GPU/HDR/网络源需自行检查。

## 高级手动部署

需要手动部署时，按manifest中的config/运行项去掉config/前缀后逐项复制（排除example）；先记录原存在性/hash并逐项备份。复制后核hash，再设置自己的私有local.conf。手动恢复也必须先核当前部署hash，恢复旧文件或只移除本次新增且匹配的文件；未知或外部修改先暂停。手动路径不产生安装工具receipt，不能让工具替它猜测恢复状态。

候选仍未公开发布，自有脚本许可待作者选定。已有定向验证不代表所有用户机器、GPU、网络、GUI或编码组合均通过。
