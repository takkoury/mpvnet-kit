# 定制

先在备份副本中调整。不要替换上游许可或把个人账号、Cookie、历史加入公开目录。

- 默认增强为Original，保持原帧率；不要把基础色彩目标当作经过校准的ICC方案。
- ModernZ尺寸/颜色/鼠标动作在config/script-opts/modernz.conf；键位在config/input.conf。用户修改应另外记录hash，以免后续覆盖。
- 可选私有配置为播放器配置目录下script-opts/mpvnet-local.conf；它不属于公开导出。字段capture_root、ffmpeg_path、python_path、mpv_path为空时使用公共自动探测/默认；填写自己机器的路径以覆盖，不提交真实文件。可复制随包config/script-opts/mpvnet-local.conf.example为自己的mpvnet-local.conf起点。Capture默认使用用户Pictures下Capture，PowerShell从SystemRoot定位。FFmpeg仅在导出片段时需要；弹幕Python/缩略图播放器还保留各组件已有显式选项覆盖。
- 公共色彩默认target-trc=auto。需要sRGB提示时，由自己检查显示链路后在个人mpv.conf/include追加target-trc=srgb，或启动时传--target-trc=srgb；不要求所有显示器使用固定sRGB，不随包提供个人ICC。
- 弹幕与网页调用由用户已有外部组件提供；缺少可选依赖时应按组件反馈修正自己的路径或暂不使用对应能力，基本播放不等于所有可选能力均可用。

公开包的manifest是原始分发文件校验；个性化修改后应保存自己的备份和差异，不将原manifest视作修改后配置的hash。

公共路径覆盖的四个值仅为路径，不接受命令参数。非空本地值优先；空值尊重组件原选项：

| 字段 | 空值规则 |
| --- | --- |
| capture_root | Windows Pictures KnownFolder下Capture |
| ffmpeg_path | PATH中的FFmpeg，仅clip导出检查 |
| python_path | bilibiliAssert.conf的python选项/其原PATH默认 |
| mpv_path | thumbfast原显式选项，其次frontend/当前播放器进程exe/portable父目录探测 |

只复制example，不公开自己的真实local.conf；路径含空格时仍填写路径数据，不加入启动参数。

安装工具只管理manifest中的运行文件；真实script-opts/mpvnet-local.conf不受管，升级复制不会覆盖它。对受管文件的个人修改会触发安装/恢复的hash保护，应先保存差异再人工决定，不强行覆盖。路径/可执行文件的存在性检查只是元数据检查，不能代替真实导出、弹幕、缩略图或GPU验证。
