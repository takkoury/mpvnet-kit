# 开发与打包

本仓库直接维护运行配置、安装器、用户文档、测试和构建工具。用户安装请下载 README 中的完整 Release ZIP；源码检出目录不是可直接安装的发行包。

## 开始与完成一个工作包

分支、验收和授权规则以 [AGENTS.md](AGENTS.md#branches-and-integration) 为准。日常操作顺序如下：

1. 用 `git status --short`、`git branch --show-current` 和 `git log -1 --oneline` 核对现场。同一工作包继续使用已有分支；新工作包从本地 `main` 建立 `codex/` 分支。存在无关改动或并行任务时，使用独立 worktree 保留现场。
2. 在工作分支实施，按改动运行必要检查。向用户说明实际验证结果；需要用户验收的部分完成后，再进入合并步骤。
3. 仅暂存本批文件，用 Conventional Commit 创建本地提交；提交应是可独立理解和验证的完整成果。
4. 工作区适合切换且满足合并条件后，切回 `main` 并优先快进合并。例如：

   ```powershell
   git switch main
   git merge --ff-only codex/task-name
   ```

   无法快进时先检查分歧，在已批准范围内处理并保留已有提交；不要通过丢弃改动或擅自重写历史来强行合并。合并引入新的变化时补做相应检查。
5. 报告提交、合并和验证结果。推送及正式发行按对应授权另行执行；分支清理也应保留仍有用途的提交和工作树。

## 目录与环境

- `config/`：通用运行配置、脚本及其依赖。
- `tools/` 和 `Install.cmd`：随安装包交付的安装与维护入口。
- `dev-tools/`：仅供开发者使用的清单构建和 ZIP 打包工具。
- `tests/`：回归测试及合成夹具，使用 Python 标准库；部分测试需要 Windows PowerShell 或已有的 Lua 5.1 共享库。
- `docs/`、`assets/`、`licenses/`：用户指南、演示图片和许可材料。

构建需要 Python 3；安装测试使用 Windows 自带的 Windows PowerShell。无需下载新的开发框架。具体测试依赖与跳过条件见 [测试说明](tests/README.md)。

## 生成测试包

在仓库根目录执行。将示例输出位置换成一个全新的仓外目录；不要指向播放器、源码检出或其他 Git 仓库。

```powershell
python -B dev-tools/build-package.py --source . --destination C:/Temp/mpvnet-kit-trial/package --map dev-tools/package-map.json
python -B dev-tools/build-package.py --source . --destination C:/Temp/mpvnet-kit-trial/package --map dev-tools/package-map.json --apply
```

第一条仅预览，显式 `--dry-run` 与默认行为相同；第二条才写入清单文件及生成的 `manifest.json`。已有受管文件遭外部修改、未知文件碰撞或清单退役项会停止构建，保留现场处理，不整目录覆盖。

本次仓库迁移使用 `0.3.0-migration-test` 标识，正式发行版本仍为 v0.3.0。版本号由清单维护；正式发行前须确认新版本并统一更新版本说明及下载入口。

运行生成目录中的 `Install.cmd` 可试用完整安装器；自动测试使用各自的合成目标。`--apply` 仅授权构建输出，不安装到播放器。

## 测试

```powershell
python -B -m unittest discover -s tests -v
```

Lua 或显式启用的安装测试未配置环境时会报告 `skipped`；不能将跳过视为通过。新包、旧发行以及用户状态保留测试的完整参数见 [测试说明](tests/README.md)。历史发行夹具默认从本仓库已保留的提交读取，不需要另一个代码仓库。

## ZIP 与发行

```powershell
python -B dev-tools/prepare-release.py --source C:/Temp/mpvnet-kit-trial/package --output C:/Temp/mpvnet-kit-trial/mpvnet-kit-migration-test.zip
python -B dev-tools/prepare-release.py --source C:/Temp/mpvnet-kit-trial/package --output C:/Temp/mpvnet-kit-trial/mpvnet-kit-migration-test.zip --apply
```

默认检查文件摘要、许可和包内文档链接，`--apply` 才生成 ZIP 及同名 `.sha256` 校验文件。包内容只来自白名单；开发工具、测试、协作说明和本地资料均不交付。

正式发行应从已确认、干净的源码提交生成新包，记录源码提交、manifest 和 ZIP 摘要，核对 ZIP 中的源文件字节与该提交一致。manifest 属于生成结果，单独核对其文件清单及摘要；不再要求整个源码仓库与 ZIP 文件列表相同。

构建工具不提交、不推送、不创建 Tag 或 Release。发行授权后，在源码提交创建 Tag，使用完整 ZIP 与 `SHA256SUMS.txt` 作为附件；保留旧发行及恢复资料。
