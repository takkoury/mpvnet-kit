# 使用

运行配置的完整40项键位以[实际 input.conf](../config/input.conf)为准；侧窗转发保持同一组键位，搜索编辑时避免播放器动作侵入文本输入。右键菜单结构保持现有配置。

下表用于日常查阅；字母显示为大写只是键名写法，只有标出Shift才需按Shift。尤其Shift+M对应源码大写`M`，Ctrl+Shift+S是字幕调整，不是普通Shift+S。

| 类别 | 键/按钮 | 行为 |
| --- | --- | --- |
| 播放 | Space | 短按播放/暂停；按住250ms临时2×，释放恢复 |
| Seek | ← / →；Shift+← / →；Ctrl+← / → | 后退/前进3秒；1秒；10秒 |
| 逐帧 | `,` / `.` | 后退/前进一步；`.`支持按住连续前进 |
| 速度 | Ctrl+[ / Ctrl+]；Ctrl+Backspace | 较慢/较快预设循环；恢复1× |
| 重新加载 | Ctrl+R | Reload当前媒体 |
| 字幕 | S；Alt+S；PageUp / PageDown | 显示开关；选择字幕行；前/后字幕时间 |
| 字幕延迟 | Alt+← / →；Alt+Backspace | 减/加0.1秒；重置延迟 |
| 字幕调整 | Ctrl+Shift+S | 进入/退出位置与字号调整模式 |
| 字幕复制 | Ctrl+C | 复制当前字幕文本 |
| 标记 | M；Shift+M | 保存播放位置；跳回标记 |
| 循环 | L；Ctrl+Shift+L | A→B→清除；文件循环开关 |
| 队列 | Home / End；P | 上/下媒体；显示/隐藏Playlist侧窗 |
| 窗口 | Enter；视频区左键双击 | 全屏开关 |
| 窗口 | Ctrl+T；Ctrl+0 | 置顶开关；窗口100% |
| 信息 | Ctrl+I / Ctrl+M；Tab | 媒体信息；统计显示 |
| 界面 | Alt+O；反引号 | 控制栏可见性；控制台 |
| 时间/URL | Ctrl+Shift+C / Ctrl+Shift+V | 复制播放时间；播放剪贴板URL |
| Screenshot按钮 | 左键 / 右键 / 中键 / hover | 源PNG；A/B导出；打开Capture根；下次默认WebP/GIF/MP4 |
| Playlist内 | 双击 / Delete；Ctrl+F / Escape | 跳转/只移队列；搜索/搜索中退出 |

Playlist搜索文本编辑与侧窗转发有自己的焦点边界；具体键位/禁用层始终以input.conf及组件实现为准。


Playlist侧窗：双击跳转，普通Delete仅移除队列条目、不删除磁盘文件；Ctrl+F打开搜索并选中文本，搜索中普通Escape关闭，带额外修饰键不触发这些专用动作。拖动排序与过滤只操作已有队列。

Screenshot：左键保存源PNG并复制图像；右键依次标记A/B并导出MP4、WebP、GIF。悬停显示三项格式，选择仅决定下一次导出后复制哪个文件，不复制旧文件。初始WebP，实例内跨媒体保留，重开恢复；正在导出时可以修改未来默认，当前任务使用B时冻结的格式。中键打开Capture根目录，独立调用不改变正在执行的导出。

Capture新子目录从媒体标题去掉一个已识别后缀，如Show.mkv→Show；普通Episode.01保留。输出文件名仍使用原安全标题与时间戳、实际格式扩展名；不迁移已有目录。

增强入口为空心四角星。五项Original、Scaling、Deband、Anime4K-L、Anime4K-S，单选hover浮层；选择保留在当前实例，每个媒体重新捕获恢复基准。默认Original，关闭恢复当前媒体原值。Anime4K仅SDR，真实画质与性能取决于素材/GPU；没有RIFE档。

截图/片段处理源媒体时间线，需自行确认所选音轨、源权限及适用素材。不承诺所有在线媒体、HDR或编码组合均已验收。
