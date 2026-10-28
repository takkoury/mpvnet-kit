# 回归检查

从代码仓库根目录运行。测试沿用 Python 标准库 unittest；播放器逻辑使用真实源码和合成输入，安装测试只写显式指定的仓外夹具，不读取个人播放器配置。

## 按改动选择验证

```powershell
python -B dev-tools/run-tests.py --list
python -B dev-tools/run-tests.py --profile core
```

无参数只显示帮助。`--list` 是测试类归组及前置条件的完整索引，不执行测试；`--profile` 可以重复指定。

| 改动领域 | 建议组 | 主要条件与证据边界 |
| --- | --- | --- |
| 开发工具、包清单、文档链接、菜单清单、弹幕转换 | `core` | Python 标准库与 Git；不验证真实播放器界面 |
| 控制栏、字幕、播放反馈、快捷键及队列的 Lua 逻辑 | `core` + `lua` | 显式提供 Lua 5.1 库；host doubles 不替代真实 mpv 输入派发或视觉验收 |
| 截图导出、播放列表、快捷键窗口及用户配置 helper | `helpers` | Windows PowerShell 与 Git；Playlist 指定证据目录；默认是 NoShow、合成输入与原生控件逻辑检查 |
| 目录识别、旧版识别、安装、更新、还原及用户设置保留 | `core` + `install` | Windows PowerShell、Git 完整旧发行历史、生成包及全新夹具目录；不启动占位播放器，不等同断电或人工操作验收 |

执行器先检查全部所选组的必要条件，再运行测试。缺少必要条件、失败或意外跳过都会返回非零；返回零只表示所选组通过。末尾摘要列出执行、失败、跳过数量及原因。新增测试类必须归入一组，发现遗漏或重复时入口会停止。

## Lua 与 helper 条件

常用设置基础的 `UserSettings` 归入 lua，覆盖原文补丁、两实例生效、异步通知顺序、媒体代次、手动覆盖及失败恢复；`SettingsStorage`、`SettingsWindow` 归入 helpers，分别验证真实文件保存与 WPF 控件／草稿状态。窗口检查默认不显示，不等同于真实键鼠、观感或跨 DPI 验收。

`SettingsDisplay` 同属 lua，执行实际 ModernZ 的显隐、暂停及临时显示代码，覆盖续期、超时、手动显隐和媒体切换。`SettingsWindow` 另检查预览与保存区在宽窄窗口中不重叠。DWM 实际画面是否包含字幕与控制栏仍须用隔离播放器观察，不能由这些替身测试代替。

```powershell
# 使用本机已有的 Lua 5.1 库，不由测试下载或安装。
$env:MPVNET_TEST_LUA51 = 'C:/path/to/lua51.dll'
# 可以是已有仓外证据根；每轮自动建立新的唯一子目录。
$env:MPVNET_TEST_PLAYLIST_ARTIFACTS = 'C:/Temp/mpvnet-kit-checks/playlist'
python -B dev-tools/run-tests.py --profile lua --profile helpers
```

helpers 组还需 PATH 中的 Git 和 `powershell.exe`，与现有 helper 用例的实际调用一致。Lua 路径无效或库不兼容会在夹具创建前报错。

只有以下四个既有用例允许在未配置条件时跳过，实际结果仍会列出：

| 可选条件 | 用例／作用 |
| --- | --- |
| `MPVNET_NATIVE_INPUT_HELP` | `UserShortcuts.test_native_snapshot_matches_cached_upstream_getdefaults`；指定已有上游 `InputHelp.cs`，对照固定命令快照 |
| `MPVNET_TEST_FFMPEG` | `CaptureOutputs.test_real_encoders_save_only_selected_file_and_remove_intermediate`、`test_commit_and_clipboard_failure_leave_existing_files_untouched`；指定已有 FFmpeg，执行短合成视频编码，使用 NoClipboard |
| `MPVNET_TEST_PLAYLIST_WINDOWS=1` | `PlaylistWindow.test_owned_window_visible_edges`；短暂显示自有窗口，检查跟随和边缘位置 |

修改 Capture 编码行为时应配置 FFmpeg 后运行。显式提供但无效的文件路径不会降为可选跳过。所有其他跳过（包括整组因缺依赖跳过）都不能作为成功。

## 安装维护条件

先按 [开发说明](../CONTRIBUTING.md#生成测试包)生成新的仓外测试包。用户设置升级测试要求旧包的运行文件严格包含于新包；当前可使用 v0.2.0 的完整包作为旧包。旧包可从既有 Release 或本仓库对应 Git 提交取得，不能指向个人配置目录。

```powershell
# 四个 ROOT 都必须尚不存在，且彼此独立、与所有输入包分离。
$env:MPVNET_INSTALL_TARGET_ROOT = 'C:/Temp/mpvnet-kit-checks/run-01/targets'
$env:MPVNET_LEGACY_ROOT = 'C:/Temp/mpvnet-kit-checks/run-01/legacy'
$env:MPVNET_LEGACY_PACKAGE = 'C:/Temp/mpvnet-kit-trial/package'
$env:MPVNET_MAINTENANCE_ROOT = 'C:/Temp/mpvnet-kit-checks/run-01/maintenance'
$env:MPVNET_MAINTENANCE_PACKAGE = 'C:/Temp/mpvnet-kit-trial/package'
$env:MPVNET_USER_UPGRADE_ROOT = 'C:/Temp/mpvnet-kit-checks/run-01/user-upgrade'
$env:MPVNET_USER_UPGRADE_OLD_PACKAGE = 'C:/Temp/mpvnet-kit-old-package'
$env:MPVNET_USER_UPGRADE_NEW_PACKAGE = 'C:/Temp/mpvnet-kit-trial/package'
python -B dev-tools/run-tests.py --profile core --profile install
```

`MPVNET_LEGACY_RELEASE_REPO` 默认当前仓库；仅在使用另一份完整历史副本时指定。测试按 `tools/legacy-releases.json` 中的固定提交读取并核对旧文件，不联网拉取历史。预检会确认输出目录不在本仓库及工作树内、不经过链接，也不与输入包重叠；各组保留自己的文件／目录快照断言及 stdout、stderr 证据。

重跑必须换用新的 ROOT，不能清空旧证据目录。硬中断测试只终止自身测试进程；用户播放器和真实配置不作为夹具。

## 窗口与完整发现

`tests/fixtures/installer_window_cases.ps1` 是单独的原生窗口夹具，接收 `-SourceRoot`、`-PackageRoot` 和新的仓外 `-FixtureRoot`，需在 Windows PowerShell 的 STA 模式下显式运行。它模拟确认答案并触发真实控件事件，与物理键鼠、跨 DPI 和人工观感分别记录，不由默认测试组启动。

需要运行四组时，在依赖和各目录均准备好后执行：

```powershell
python -B dev-tools/run-tests.py --profile core --profile lua --profile helpers --profile install
```

原有入口 `python -B -m unittest discover -s tests -v` 继续可用，但 unittest 自身可能在跳过整组测试后仍返回成功；用于验收时优先使用具名入口。单文件调试可用 `python -B -m unittest discover -s tests -p test_package_build.py -v`，并自行检查其依赖与跳过情况。

## 维护测试辅助

`support/lua_source.py` 统一片段提取，分别保留字符串和类型化的配置注入；`lua_runtime.py` 只封装已有 Lua 库调用。`support/install_fixtures.py` 统一路径预检、PowerShell 定位、固定发行读取和子进程证据保存，不替各测试定义业务快照。开发工具通过 `support/dev_imports.py` 的单点路径配置普通导入，不执行 CLI 来获取函数。
