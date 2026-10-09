# 手动安装与恢复

此候选面向 Windows mpv.net，验证基线7.1.2 / libmpv 0.41。先准备现有播放器与自己的配置目录；不要把配置放入系统目录或其他用户目录。没有安装/恢复脚本，以下均为手动流程。

1. 关闭受影响的播放器实例。确认目标配置目录确实由这份mpv.net读取。
2. 用根目录 manifest.json 的文件列表筛选 config/ 项；目标相对路径为去掉 config/ 前缀后的同一路径。不要递归覆盖整个配置目录。
3. 对每个目标记录原来是否存在及SHA256；已有文件逐项复制到仓库外备份目录，保留相对路径。未知文件、settings.xml、历史与缓存保持。
4. 按所需能力检查依赖，再逐项复制清单中的config文件。完成受管文件复制后，按[公共路径参数](customization.md)创建或调整自己的script-opts/mpvnet-local.conf；该私有文件不在manifest受管清单中，复制公开包不会覆盖它。licenses/ 和用户文档随分发保留，不需要复制到播放器配置目录。
5. 核对所复制文件的SHA256和manifest一致；修改过的个性化选项另外记录自己的最终hash。启动自己的媒体检查，初始增强保持Original。

恢复：先关闭播放器并核对目标仍是自己记录的部署版本。若有外部修改，先暂停并保留差异。原来存在的逐项恢复备份；原来不存在的，仅移除本次新增且hash一致的清单文件。不要删除整个配置目录、Capture输出或未知文件。

依赖按能力检查：基本UI使用现有mpv.net；Capture导出需要FFmpeg，弹幕转换需要Python，缩略图需要可用的播放器worker。公共路径可在不随包分发的script-opts/mpvnet-local.conf填写capture_root/ffmpeg_path/python_path/mpv_path，空值走自动探测；见[定制](customization.md)。只有片段导出需要FFmpeg，目录打开不检查FFmpeg。独立信息/Playlist侧窗使用Windows PowerShell/WinForms。网页调起复用外部播放器脚本/协议handler，需用户自行配置；不导账号/Cookie，不修改系统PATH或协议注册。

每台机器都应确认路径和依赖，不能把作者测试机路径视作默认安装要求。不要用生产配置覆盖来代替备份。
