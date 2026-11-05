# 右键菜单扩展

通过 mpv.net 官方 `IExtension` 加载，在宿主 WPF Dispatcher 中定位真实菜单，仅替换该根菜单及其后代的展示。宿主继续生成动态条目、执行原命令并维护近期文件和设备记忆。无需改写宿主程序，也不使用私有反射。

运行资产是 `config/extensions/KitContextMenu/KitContextMenu.dll`。文件夹与 DLL 名称必须一致；不复制编译引用的 `mpvnet.dll`、`libmpvnet.dll` 或运行时依赖到安装包。

## 重建

需要本地 .NET 10 SDK 和兼容的 mpv.net 单文件程序。工具只读取该程序的程序集与运行时声明，不读取播放器配置，不下载依赖。构建目录必须全新且位于源码和播放器目录之外。

```powershell
python -B dev-tools/build-context-menu.py --host C:/Tools/mpv.net/mpvnet.exe --output D:/Builds/menu-candidate
python -B dev-tools/build-context-menu.py --host C:/Tools/mpv.net/mpvnet.exe --output D:/Builds/menu-candidate --apply
```

第一条只核对输入，第二条构建。核验 `build-evidence.json` 后，将生成的 `KitContextMenu.dll` 更新为受管运行资产，并运行 core 检查及菜单的 WPF/宿主隔离验证。源码与 DLL 一起提交；普通打包沿用白名单复制，不要求安装者拥有 SDK。

源码摘要按四个构建输入的相对路径排序，以 UTF-8 路径、NUL、八字节小端内容长度及原字节依次计算 SHA-256，嵌入程序集的 `KitContextMenu.SourceSha256` 元数据。修改源码后必须重建；不得用旧 DLL 交付新的源码。构建工具和依赖的宿主摘要另在仓外证据中记录。

## 验证边界

构造 WPF 模板、模拟控件事件、实际宿主加载、可见键鼠交互和跨 DPI 是不同层次。内存控件检查不能证明宿主加载成功，实际加载也不能代替用户视觉验收。兼容性变化时先保留原菜单，不接管原点击处理或静默丢弃动态能力。
