Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'common.psm1') -Force

function Assert-CleanNoReparse([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        try {
            if (([IO.File]::GetAttributes($current) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "拒绝链接或重解析点：$current"
            }
        } catch [IO.FileNotFoundException] { } catch [IO.DirectoryNotFoundException] { }
        $parent = [IO.Directory]::GetParent($current)
        if (-not $parent) { break }
        $current = $parent.FullName
    }
}
function Get-CleanRoamingRoot {
    return [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
}
function Get-CleanPlayer([string]$PlayerPath) {
    $player = Get-KitPlayer $PlayerPath
    if ([IO.Path]::GetFileName($player) -ine 'mpvnet.exe') { throw '请选择名为 mpvnet.exe 的 mpv.net 播放器程序。' }
    return $player
}
function Resolve-CleanTarget([string]$Player) {
    $home = [Environment]::GetEnvironmentVariable('MPVNET_HOME', [EnvironmentVariableTarget]::Process)
    $portable = Join-Path ([IO.Path]::GetDirectoryName($Player)) 'portable_config'
    $portableExists = [IO.Directory]::Exists($portable)
    # Match mpv.net's priority: only an existing HOME directory takes precedence.
    if ($home -and [IO.Directory]::Exists($home)) {
        try { $target = Get-KitRoot $home }
        catch { throw '现存 MPVNET_HOME 不是可安全确定的绝对路径；请在明确的启动环境中重试。安装器不会猜测相对目录。' }
        $source = 'environment'; $sourceLabel = '当前进程的 MPVNET_HOME'
    } elseif ($portableExists) {
        $target = Get-KitRoot $portable; $source = 'portable'; $sourceLabel = '播放器旁已有 portable_config（便携模式）'
    } else {
        $roaming = Get-CleanRoamingRoot
        if (-not $roaming) { throw '无法取得当前用户的 Roaming AppData，无法安全自动选择配置目录。' }
        $target = Get-KitRoot (Join-Path (Get-KitRoot $roaming) 'mpv.net')
        $source = 'appdata'; $sourceLabel = '当前用户 Roaming AppData（安装模式）'
    }
    if ($target.TrimEnd('\', '/') -ieq ([IO.Path]::GetPathRoot($target)).TrimEnd('\', '/')) { throw '卷根或 UNC 共享根不适合作为配置安装目录。' }
    Assert-CleanNoReparse $target
    return [pscustomobject]@{ target = $target; source = $source; sourceLabel = $sourceLabel;
        environmentHome = $home; portableExists = $portableExists }
}
function Test-CleanStateEntry([string]$Relative, [bool]$Directory) {
    $parts = $Relative.Split('/')
    if ($parts[0] -iin @('cache', 'watch_later')) { return ($Directory -or $parts.Count -gt 1) }
    return (-not $Directory -and $Relative -iin @('settings.xml', 'desktop.ini'))
}
function Get-CleanTargetState([string]$Target, $RuntimePaths, $RuntimeDirectories, $OwnedFiles = @{}, $OwnedDirectories = $null, $BaselineEntries = @{}) {
    Assert-CleanNoReparse $Target
    if ([IO.File]::Exists($Target)) { throw '实际配置目录被文件占用，无法安装。' }
    $entries = @{}; $retainedFiles = 0; $retainedDirectories = 0
    if (-not [IO.Directory]::Exists($Target)) { return [pscustomobject]@{ entries = $entries; retainedFiles = 0; retainedDirectories = 0 } }
    $stack = New-Object 'System.Collections.Generic.Stack[string]'; $stack.Push($Target)
    while ($stack.Count) {
        $directory = $stack.Pop()
        foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($directory)) {
            Assert-CleanNoReparse $entry
            $relative = $entry.Substring($Target.Length + 1).Replace('\', '/')
            $isDirectory = [IO.Directory]::Exists($entry)
            if ($isDirectory) {
                $owned = $OwnedDirectories -and $OwnedDirectories.Contains($entry)
                $stateDirectory = Test-CleanStateEntry $relative $true
                $reusable = $BaselineEntries.ContainsKey($relative) -and $BaselineEntries[$relative] -ceq 'reusable-directory'
                if (-not $owned -and -not $stateDirectory -and -not $reusable -and
                    $relative -iin @('scripts', 'script-opts', 'fonts', 'shaders') -and
                    @([IO.Directory]::EnumerateFileSystemEntries($entry)).Count -eq 0) { $reusable = $true }
                if (-not $owned -and -not $stateDirectory -and -not $reusable) {
                    throw "配置目录包含无法保留的目录：$relative。仅真正空的顶层资源目录可复用，已有配置或个性资源不会被合并。"
                }
                $entries[$relative] = if ($owned) { 'owned-directory' } elseif ($stateDirectory) { 'state-directory' } else { 'reusable-directory' }
                if (-not $owned) { $retainedDirectories++ }
                $stack.Push($entry)
            } elseif ($OwnedFiles.ContainsKey($entry)) {
                if ((Get-KitHash $entry) -cne $OwnedFiles[$entry]) { throw "安装文件在写入后变化：$relative" }
                $entries[$relative] = 'owned-file'
            } else {
                if ($RuntimePaths.ContainsKey($relative) -or -not (Test-CleanStateEntry $relative $false)) {
                    throw "实际配置目录已有配置、脚本或未知文件：$relative。请先自行保存和处理，本安装器不会覆盖或合并。"
                }
                $entries[$relative] = 'state-file'; $retainedFiles++
            }
        }
    }
    foreach ($entry in $OwnedFiles.Keys) {
        if ((Get-KitHash $entry) -cne $OwnedFiles[$entry]) { throw "安装文件在写入后变化：$entry" }
    }
    return [pscustomobject]@{ entries = $entries; retainedFiles = $retainedFiles; retainedDirectories = $retainedDirectories }
}
function Get-CleanOptionalTool([string]$Name, [string]$Label) {
    $command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $path = if ($command) { $command.Source } else { '' }
    $found = [bool]($path -and [IO.File]::Exists($path) -and [IO.Path]::GetExtension($path) -ieq '.exe')
    return [pscustomobject]@{ name = $Label; path = $path; found = $found }
}
function Get-CleanTargetIdentity([string]$Target) {
    if (-not [IO.Directory]::Exists($Target)) { return '' }
    Initialize-CleanNative
    $handle = Lock-CleanDirectory $Target
    try {
        $identity = [MpvnetCleanNative]::GetIdentity($handle)
        if (-not $identity) { throw '无法取得实际配置目录的身份，请重新选择播放器。' }
        return $identity
    } finally { $handle.Dispose() }
}
function Get-CleanInstallPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$PlayerPath, [Parameter(Mandatory=$true)][string]$PackageRoot)
    $player = Get-CleanPlayer $PlayerPath
    $resolved = Resolve-CleanTarget $player
    $target = $resolved.target
    $package = Get-KitPackage $PackageRoot
    $a = $target.TrimEnd('\') + '\'; $b = $package.root.TrimEnd('\') + '\'
    if ($a.StartsWith($b, [StringComparison]::OrdinalIgnoreCase) -or $b.StartsWith($a, [StringComparison]::OrdinalIgnoreCase)) { throw '实际配置目录与配置包目录不能相同、互相包含或重叠。' }
    if ($player.StartsWith($a, [StringComparison]::OrdinalIgnoreCase)) { throw '实际配置目录不能包含播放器程序。' }
    $files = New-Object 'System.Collections.Generic.List[object]'; $seen = @{}; $directories = @{}
    foreach ($item in $package.runtime) {
        $path = Get-KitPath $target $item.path
        if ($seen.ContainsKey($item.path)) { throw "重复的安装文件：$($item.path)" }
        $seen[$item.path] = $true
        $files.Add([pscustomobject]@{ path = $item.path; target = $path; bytes = $item.bytes; sha256 = $item.sha256 })
        $parent = [IO.Path]::GetDirectoryName($path)
        while ($parent -and $parent -ine $target) {
            $directories[$parent.Substring($target.Length + 1).Replace('\', '/')] = $true
            $parent = [IO.Path]::GetDirectoryName($parent)
        }
    }
    foreach ($relative in $directories.Keys) { if ($seen.ContainsKey($relative)) { throw "安装文件与子目录发生冲突：$relative" } }
    $identity = Get-CleanTargetIdentity $target
    $baseline = Get-CleanTargetState $target $seen $directories
    if ((Get-CleanTargetIdentity $target) -cne $identity) { throw '检查过程中配置目录身份发生变化，请重新选择播放器。' }
    $tools = @((Get-CleanOptionalTool 'ffmpeg.exe' 'FFmpeg'), (Get-CleanOptionalTool 'python.exe' 'Python'))
    $warnings = @()
    foreach ($tool in $tools) { if (-not $tool.found) { $warnings += "未在 PATH 中发现 $($tool.name)，相关功能需另行准备依赖；不影响基本安装。" } }
    if ($resolved.source -eq 'environment') { $warnings += '目录按安装器当前进程的 MPVNET_HOME 判断。请确保您启动播放器时使用相同环境；安装器不会修改环境变量。' }
    return [pscustomobject]@{ player = $player; target = $target; targetSource = $resolved.source; targetSourceLabel = $resolved.sourceLabel;
        environmentHome = $resolved.environmentHome; portableExists = $resolved.portableExists; targetIdentity = $identity;
        packageRoot = $package.root; packageVersion = $package.version; manifestSha256 = $package.manifestSha256;
        verifiedPackageFiles = $package.verifiedFileCount; files = $files.ToArray(); runtimePaths = $seen; runtimeDirectories = $directories;
        baseline = $baseline; tools = $tools; warnings = $warnings }
}
function Initialize-CleanNative {
    if (-not ('MpvnetCleanNative' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class MpvnetCleanNative {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern bool CreateDirectory(string path, IntPtr security);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr security, uint mode, uint flags, IntPtr template);
    [StructLayout(LayoutKind.Sequential)] public struct Disposition { public byte Delete; }
    [StructLayout(LayoutKind.Sequential)] public struct AttributeTag { public uint Attributes; public uint ReparseTag; }
    [StructLayout(LayoutKind.Sequential)] public struct EntryInfo {
        public uint Attributes, CreationLow, CreationHigh, AccessLow, AccessHigh, WriteLow, WriteHigh;
        public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }
    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out EntryInfo value);
    public static string GetIdentity(SafeFileHandle handle) {
        EntryInfo value;
        if (!GetFileInformationByHandle(handle, out value)) return null;
        return value.Volume.ToString("x8") + ":" + value.IndexHigh.ToString("x8") + value.IndexLow.ToString("x8");
    }
    public static bool IsPlainDirectory(SafeFileHandle handle) {
        AttributeTag value;
        return GetFileInformationByHandleEx(handle, 9, out value, 8) && (value.Attributes & 0x410) == 0x10;
    }
    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool GetFileInformationByHandleEx(SafeFileHandle handle, int type, out AttributeTag value, uint size);
    public static bool IsPlainFile(SafeFileHandle handle) {
        AttributeTag value;
        return GetFileInformationByHandleEx(handle, 9, out value, 8) && (value.Attributes & 0x410) == 0;
    }
    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool SetFileInformationByHandle(SafeFileHandle handle, int type, ref Disposition value, uint size);
    public static bool RemoveOwnedDirectory(SafeFileHandle handle) {
        Disposition value = new Disposition { Delete = 1 };
        return SetFileInformationByHandle(handle, 4, ref value, 1);
    }
}
'@
    }
}
function Lock-CleanDirectory([string]$Path, [bool]$Owned = $false) {
    Assert-CleanNoReparse $Path
    # No delete sharing: another process cannot replace a checked directory while it is used.
    $access = if ($Owned) { 0x00010000 } else { 0 }
    $handle = [MpvnetCleanNative]::CreateFile($Path, $access, 3, [IntPtr]::Zero, 3, 0x02200000, [IntPtr]::Zero)
    if ($handle.IsInvalid) { $handle.Dispose(); throw "无法锁定安装目录：$Path" }
    try {
        if (-not [MpvnetCleanNative]::IsPlainDirectory($handle)) { throw "安装目录不是普通目录：$Path" }
        Assert-CleanNoReparse $Path
    } catch { $handle.Dispose(); throw }
    return $handle
}
function New-CleanDirectory([string]$Path, $OwnedDirectories, $Locks) {
    Assert-CleanNoReparse $Path
    if ([IO.Directory]::Exists($Path)) {
        if (-not $Locks.ContainsKey($Path)) { $Locks[$Path] = Lock-CleanDirectory $Path }
        return
    }
    if ([IO.File]::Exists($Path)) { throw "目录路径已被文件占用：$Path" }
    $parent = [IO.Path]::GetDirectoryName($Path)
    if ($parent) { New-CleanDirectory $parent $OwnedDirectories $Locks }
    Assert-CleanNoReparse $Path
    if (-not [MpvnetCleanNative]::CreateDirectory($Path, [IntPtr]::Zero)) { throw "目录在检查后改变，或无法创建：$Path" }
    $OwnedDirectories.Add($Path)
    $Locks[$Path] = Lock-CleanDirectory $Path $true
}
function Assert-CleanOwnedTree($Plan, $OwnedFiles, $OwnedDirectories) {
    [void](Get-CleanTargetState $Plan.target $Plan.runtimePaths $Plan.runtimeDirectories $OwnedFiles $OwnedDirectories $Plan.baseline.entries)
}
function Write-CleanFile($Item, $OwnedFiles) {
    Assert-CleanNoReparse $Item.target
    $stream = [IO.File]::Open($Item.target, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        try { $stream.Write($Item.bytes, 0, $Item.bytes.Length); $stream.Flush() }
        finally {
            # Capture even partial bytes while exclusive access still proves they are ours.
            $stream.Position = 0
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $OwnedFiles[$Item.target] = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
            finally { $sha.Dispose() }
        }
    } finally { $stream.Dispose() }
    if ($OwnedFiles[$Item.target] -cne $Item.sha256 -or (Get-KitHash $Item.target) -cne $Item.sha256) { throw "安装后的文件校验失败：$($Item.path)" }
}
function Remove-CleanOwnedFile([string]$Path, [string]$ExpectedHash) {
    Assert-CleanNoReparse $Path
    if (-not [IO.File]::Exists($Path)) { return }
    $handle = [MpvnetCleanNative]::CreateFile($Path, 2147549184, 1, [IntPtr]::Zero, 3, 0x00200000, [IntPtr]::Zero)
    if ($handle.IsInvalid) { $handle.Dispose(); throw '无法取得清理文件的独占访问。' }
    $stream = $null
    try {
        # OPEN_REPARSE_POINT opens the entry itself; validate this handle before reading or deleting.
        if (-not [MpvnetCleanNative]::IsPlainFile($handle)) { throw '清理路径不是普通文件，保留该路径。' }
        $stream = New-Object IO.FileStream($handle, [IO.FileAccess]::Read)
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $actual = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
        finally { $sha.Dispose() }
        if ($actual -cne $ExpectedHash) { throw '文件字节已变化，保留文件。' }
        if (-not [MpvnetCleanNative]::RemoveOwnedDirectory($handle)) { throw '无法删除本次创建的文件。' }
    } finally { if ($stream) { $stream.Dispose() } else { $handle.Dispose() } }
}
function Invoke-CleanInstall {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Plan)
    # Resolve again: no fallback to another directory after the user confirms a plan.
    $current = Get-CleanInstallPlan -PlayerPath $Plan.player -PackageRoot $Plan.packageRoot
    if ($current.target -ine $Plan.target -or $current.targetSource -cne $Plan.targetSource -or
        $current.environmentHome -cne $Plan.environmentHome -or $current.portableExists -ne $Plan.portableExists -or
        $current.targetIdentity -cne $Plan.targetIdentity) { throw '配置目录来源、位置或身份在检查后变化，请重新选择播放器并确认。' }
    if ($current.manifestSha256 -cne $Plan.manifestSha256) { throw '配置包在检查后变化，请重新选择播放器。' }
    Initialize-CleanNative
    $ownedFiles = @{}; $locks = @{}
    $ownedDirectories = New-Object 'System.Collections.Generic.List[string]'
    $cleanupNotes = New-Object 'System.Collections.Generic.List[string]'
    try {
        New-CleanDirectory $current.target $ownedDirectories $locks
        if (-not $current.targetIdentity -and -not $ownedDirectories.Contains($current.target)) { throw '原本不存在的配置目录在检查后被创建，请重新选择播放器。' }
        if ($current.targetIdentity -and [MpvnetCleanNative]::GetIdentity($locks[$current.target]) -cne $current.targetIdentity) { throw '配置目录在开始安装前被替换，请重新选择播放器。' }
        Assert-CleanOwnedTree $current $ownedFiles $ownedDirectories
        foreach ($item in $current.files) {
            Assert-CleanOwnedTree $current $ownedFiles $ownedDirectories
            New-CleanDirectory ([IO.Path]::GetDirectoryName($item.target)) $ownedDirectories $locks
            Assert-CleanOwnedTree $current $ownedFiles $ownedDirectories
            Write-CleanFile $item $ownedFiles
        }
        Assert-CleanOwnedTree $current $ownedFiles $ownedDirectories
        return [pscustomobject]@{ target = $current.target; targetSource = $current.targetSource; files = $current.files.Count; packageVersion = $current.packageVersion; warnings = $current.warnings }
    } catch {
        $failure = $_.Exception.Message
        foreach ($path in @($ownedFiles.Keys)) {
            try {
                Remove-CleanOwnedFile $path $ownedFiles[$path]
            } catch { $cleanupNotes.Add("未能清理文件：$path；$($_.Exception.Message)") }
        }
        # Clean only tracked directories through their retained handles, after confirming they are empty.
        for ($i = $ownedDirectories.Count - 1; $i -ge 0; $i--) {
            $path = $ownedDirectories[$i]
            try {
                if ($locks.ContainsKey($path)) {
                    $handle = $locks[$path]
                    if (@([IO.Directory]::EnumerateFileSystemEntries($path)).Count -eq 0 -and -not [MpvnetCleanNative]::RemoveOwnedDirectory($handle)) {
                        $cleanupNotes.Add("未能清理本次创建的空目录：$path")
                    }
                    $handle.Dispose(); $locks.Remove($path)
                } else {
                    $cleanupNotes.Add("保留本次创建但未能取得所属句柄的目录：$path")
                }
            } catch { $cleanupNotes.Add("未能清理目录：$path；$($_.Exception.Message)") }
        }
        $detail = if ($cleanupNotes.Count) { "`r`n" + ($cleanupNotes -join "`r`n") } else { '' }
        throw "安装失败：$failure`r`n已尝试仅清理本次创建且未变化的文件；其他内容保留。$detail"
    } finally { foreach ($handle in $locks.Values) { $handle.Dispose() } }
}
Export-ModuleMember -Function Get-CleanInstallPlan,Invoke-CleanInstall
