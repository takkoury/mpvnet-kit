Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:KitOwner = 'mpvnet-kit'
$script:KitUtf8 = New-Object Text.UTF8Encoding($false)
$script:ReceiptName = '.mpvnet-kit-install.json'

function Get-KitHashBytes([byte[]]$Bytes) {
    if ($null -eq $Bytes) { $Bytes = [byte[]]@() }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
function Get-KitHash([string]$Path) {
    if (-not [IO.File]::Exists($Path)) { return $null }
    return Get-KitHashBytes ([IO.File]::ReadAllBytes($Path))
}
function Get-KitBytes($Value) {
    return ,$script:KitUtf8.GetBytes(($Value | ConvertTo-Json -Depth 20) + "`n")
}
function Get-KitTokenHash([object[]]$Parts) {
    # Length-prefixed UTF-8 fields avoid PowerShell edition, JSON formatting and delimiter differences.
    $stream = New-Object IO.MemoryStream
    $writer = New-Object IO.BinaryWriter($stream, $script:KitUtf8)
    try {
        foreach ($part in $Parts) {
            if ($null -eq $part) { $writer.Write([int]-1) }
            else {
                $bytes = $script:KitUtf8.GetBytes([string]$part)
                $writer.Write([int]$bytes.Length); $writer.Write($bytes)
            }
        }
        $writer.Flush()
        return Get-KitHashBytes $stream.ToArray()
    } finally { $writer.Dispose(); $stream.Dispose() }
}
function Get-KitRoot([string]$Path) {
    if (-not $Path) { throw 'An absolute Windows path is required.' }
    if ($Path.StartsWith('\\?\') -or $Path.StartsWith('\\.\')) { throw 'Device paths are not supported.' }
    if (-not $Path -or $Path -notmatch '^(?:[A-Za-z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+)') { throw 'An absolute Windows path is required.' }
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.Length -gt [IO.Path]::GetPathRoot($full).Length) { $full = $full.TrimEnd('\', '/') }
    return $full
}
function Assert-KitRelative([string]$Path) {
    if (-not $Path -or $Path -match '[:\\\x00]' -or $Path.StartsWith('/')) { throw "Invalid relative path: $Path" }
    foreach ($part in $Path.Split('/')) {
        if (-not $part -or $part -in @('.', '..') -or $part -match '[. ]$' -or
            $part.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
            $part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') { throw "Unsafe relative path: $Path" }
    }
}
function Assert-KitNoReparse([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        try {
            $attributes = [IO.File]::GetAttributes($current)
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Reparse point refused: $current" }
        } catch [IO.FileNotFoundException] { } catch [IO.DirectoryNotFoundException] { }
        $parent = [IO.Directory]::GetParent($current)
        if (-not $parent) { break }
        $current = $parent.FullName
    }
}
function Get-KitPath([string]$Root, [string]$Relative) {
    Assert-KitRelative $Relative
    $rootPath = Get-KitRoot $Root
    $path = [IO.Path]::GetFullPath((Join-Path $rootPath $Relative.Replace('/', '\')))
    if (-not $path.StartsWith($rootPath.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Path escaped its root.' }
    Assert-KitNoReparse $path
    return $path
}
function Assert-KitSeparate([string[]]$Roots) {
    for ($i = 0; $i -lt $Roots.Count; $i++) {
        for ($j = $i + 1; $j -lt $Roots.Count; $j++) {
            $a = (Get-KitRoot $Roots[$i]).TrimEnd('\') + '\'
            $b = (Get-KitRoot $Roots[$j]).TrimEnd('\') + '\'
            if ($a.StartsWith($b, [StringComparison]::OrdinalIgnoreCase) -or $b.StartsWith($a, [StringComparison]::OrdinalIgnoreCase)) { throw 'Package, target and backup roots must be separate.' }
        }
    }
}
function Read-KitJson([string]$Path) {
    Assert-KitNoReparse $Path
    return ([IO.File]::ReadAllText($Path, $script:KitUtf8) | ConvertFrom-Json)
}
function Assert-KitFields($Value, [string[]]$Names) {
    foreach ($name in $Names) { if (-not $Value -or -not $Value.PSObject.Properties[$name]) { throw "Missing field: $name" } }
}
function Get-KitPackage([string]$PackageRoot) {
    $root = Get-KitRoot $PackageRoot
    $manifestPath = Get-KitPath $root 'manifest.json'
    $manifestBytes = [IO.File]::ReadAllBytes($manifestPath)
    $manifest = $script:KitUtf8.GetString($manifestBytes).TrimStart([char]0xfeff) | ConvertFrom-Json
    Assert-KitFields $manifest @('schema', 'version', 'files')
    if ($manifest.schema -ne 1 -or $manifest.version -isnot [string] -or -not $manifest.version -or @($manifest.files).Count -eq 0) { throw 'Unsupported package manifest.' }
    $seen = @{}; $runtime = @(); $releaseNotice = ''
    foreach ($file in $manifest.files) {
        Assert-KitFields $file @('path', 'sha256')
        if ($file.path -isnot [string] -or $file.sha256 -notmatch '^[0-9a-f]{64}$' -or $seen.ContainsKey($file.path)) { throw 'Invalid or case-colliding package entry.' }
        $seen[$file.path] = $true
        $path = Get-KitPath $root $file.path
        $bytes = [IO.File]::ReadAllBytes($path)
        if ((Get-KitHashBytes $bytes) -cne $file.sha256) { throw "Package checksum mismatch: $($file.path)" }
        if ($file.path -ceq 'docs/upgrade-notice.txt') {
            if ($bytes.Length -gt 4096) { throw 'Package upgrade notice is too long.' }
            $releaseNotice = $script:KitUtf8.GetString($bytes).TrimStart([char]0xfeff).Trim()
        }
        if ($file.path.StartsWith('config/', [StringComparison]::Ordinal) -and -not $file.path.EndsWith('.example', [StringComparison]::OrdinalIgnoreCase)) {
            $relative = $file.path.Substring(7)
            if ($relative -eq 'mpvnet-user.json' -or $relative -eq 'script-opts/mpvnet-local.conf' -or $relative -eq $script:ReceiptName -or $relative -eq '.mpvnet-kit-operation.json') { throw 'Private or state files cannot be package runtime files.' }
            $runtime += [pscustomobject]@{ path = $relative; sha256 = $file.sha256; bytes = $bytes }
        }
    }
    if ($runtime.Count -eq 0) { throw 'The package has no runtime payload.' }
    return [pscustomobject]@{ root = $root; version = $manifest.version; manifestSha256 = (Get-KitHashBytes $manifestBytes); runtime = $runtime; verifiedFileCount = @($manifest.files).Count; releaseNotice = $releaseNotice }
}
function Get-KitRecordData($Record) {
    return [ordered]@{ schema = $Record.schema; owner = $Record.owner; kind = $Record.kind; id = $Record.id;
        target = $Record.target; packageVersion = $Record.packageVersion; packageManifestSha256 = $Record.packageManifestSha256;
        createdUtc = $Record.createdUtc; files = $Record.files; previousReceipt = $Record.previousReceipt }
}
function Read-KitRecord([string]$ManifestPath) {
    $path = Get-KitRoot $ManifestPath
    Assert-KitNoReparse $path
    if ([IO.Path]::GetFileName($path) -cne 'manifest.json') { throw 'A backup manifest.json is required.' }
    $record = Read-KitJson $path
    Assert-KitFields $record @('schema', 'owner', 'kind', 'id', 'target', 'packageVersion', 'packageManifestSha256', 'createdUtc', 'files', 'previousReceipt', 'dataSha256', 'receiptSha256')
    if ($record.schema -ne 1 -or $record.owner -cne $script:KitOwner -or $record.kind -cne 'backup' -or $record.id -notmatch '^[0-9a-f]{32}$') { throw 'Unowned or invalid backup record.' }
    $directory = [IO.Path]::GetDirectoryName($path)
    $target = Get-KitRoot $record.target
    Assert-KitSeparate @($directory, $target)
    if ((Get-KitHashBytes (Get-KitBytes (Get-KitRecordData $record))) -cne $record.dataSha256) { throw 'Backup record data changed.' }
    $seen = @{}
    foreach ($file in $record.files) {
        Assert-KitFields $file @('path', 'oldExists', 'oldSha256', 'newSha256', 'changed', 'backup')
        if ($seen.ContainsKey($file.path) -or $file.oldExists -isnot [bool] -or $file.changed -isnot [bool] -or $file.newSha256 -notmatch '^[0-9a-f]{64}$') { throw 'Invalid backup file entry.' }
        $seen[$file.path] = $true
        [void](Get-KitPath $target $file.path)
        if ($file.oldExists -and $file.oldSha256 -notmatch '^[0-9a-f]{64}$') { throw 'Invalid old checksum.' }
        if ($file.oldExists -and $file.changed) {
            if ($file.backup -cne ('files/' + $file.path)) { throw 'Backup path does not match its file.' }
            $saved = Get-KitPath $directory $file.backup
            if ((Get-KitHash $saved) -cne $file.oldSha256) { throw "Backup checksum mismatch: $($file.path)" }
        } elseif ($file.backup) { throw 'Unexpected backup path.' }
    }
    if (@($record.files).Count -eq 0) { throw 'Empty backup record.' }
    Assert-KitFields $record.previousReceipt @('exists', 'sha256', 'backup')
    if ($record.previousReceipt.exists -isnot [bool]) { throw 'Invalid previous receipt flag.' }
    if ($record.previousReceipt.exists) {
        if ($record.previousReceipt.backup -cne 'previous-receipt.json') { throw 'Unsafe previous receipt path.' }
        $savedReceipt = Get-KitPath $directory 'previous-receipt.json'
        if ((Get-KitHash $savedReceipt) -cne $record.previousReceipt.sha256) { throw 'Previous receipt backup changed.' }
    }
    return [pscustomobject]@{ value = $record; directory = $directory; target = $target; manifest = $path }
}
function Assert-KitReceiptData($Receipt, [string]$Target, [string]$ReceiptHash) {
    Assert-KitFields $Receipt @('schema', 'owner', 'kind', 'id', 'target', 'packageVersion', 'packageManifestSha256', 'backupDirectory', 'backupDataSha256', 'files')
    if ($Receipt.schema -ne 1 -or $Receipt.owner -cne $script:KitOwner -or $Receipt.kind -cne 'receipt' -or $Receipt.id -notmatch '^[0-9a-f]{32}$' -or
        (Get-KitRoot $Receipt.target) -ine $Target) { throw 'Existing state is not a valid owned receipt.' }
    $record = Read-KitRecord (Get-KitPath (Get-KitRoot $Receipt.backupDirectory) 'manifest.json')
    if ($record.value.id -cne $Receipt.id -or $record.target -ine $Target -or $record.value.dataSha256 -cne $Receipt.backupDataSha256 -or $record.value.receiptSha256 -cne $ReceiptHash) { throw 'Receipt ownership or bytes changed.' }
    $expected = @{}; foreach ($f in $record.value.files) { $expected[$f.path] = $f.newSha256 }
    if (@($Receipt.files).Count -ne $expected.Count) { throw 'Receipt file set changed.' }
    $seen = @{}
    foreach ($f in $Receipt.files) {
        Assert-KitFields $f @('path', 'sha256')
        if ($seen.ContainsKey($f.path) -or -not $expected.ContainsKey($f.path) -or $expected[$f.path] -cne $f.sha256) { throw 'Receipt file entries changed.' }
        $seen[$f.path] = $true
    }
    return $record
}
function Get-KitReceipt([string]$Target) {
    $path = Get-KitPath $Target $script:ReceiptName
    if (-not [IO.File]::Exists($path)) { return $null }
    $bytes = [IO.File]::ReadAllBytes($path); $sha = Get-KitHashBytes $bytes
    $receipt = $script:KitUtf8.GetString($bytes) | ConvertFrom-Json
    $record = Assert-KitReceiptData $receipt $Target $sha
    foreach ($file in $receipt.files) {
        if ((Get-KitHash (Get-KitPath $Target $file.path)) -cne $file.sha256) { throw "Managed file modified or deleted: $($file.path)" }
    }
    return [pscustomobject]@{ value = $receipt; path = $path; bytes = $bytes; sha256 = $sha; record = $record }
}
function Assert-KitExpected([string]$Path, [string]$ExpectedHash) {
    Assert-KitNoReparse $Path
    if ([IO.Directory]::Exists($Path)) { throw "A directory occupies the file target: $Path" }
    $actual = Get-KitHash $Path
    if ((-not $ExpectedHash -and $null -ne $actual) -or ($ExpectedHash -and $actual -cne $ExpectedHash)) { throw "File changed since preflight: $Path" }
}
function Write-KitFile([string]$Path, [byte[]]$Bytes, [string]$ExpectedHash) {
    if ($null -eq $Bytes) { $Bytes = [byte[]]@() }
    Assert-KitExpected $Path $ExpectedHash
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    Assert-KitNoReparse $Path
    $temporary = $Path + '.mpvnet-kit-' + [Guid]::NewGuid().ToString('N')
    $temporaryOwned = $false
    try {
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $temporaryOwned = $true
        try { $stream.Write($Bytes, 0, $Bytes.Length); $stream.Flush() } finally { $stream.Dispose() }
        Assert-KitExpected $Path $ExpectedHash
        Assert-KitNoReparse $temporary
        if ((Get-KitHash $temporary) -cne (Get-KitHashBytes $Bytes)) { throw 'Staged bytes changed before commit.' }
        if ($ExpectedHash) { [IO.File]::Replace($temporary, $Path, [System.Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    } finally { if ($temporaryOwned -and [IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }

}
function Remove-KitFile([string]$Path, [string]$ExpectedHash) {
    Assert-KitExpected $Path $ExpectedHash
    [IO.File]::Delete($Path)
}
function Save-KitStatus([string]$Directory, [string]$State, [string]$Message, [string]$ExpectedHash) {
    $path = Get-KitPath $Directory 'status.json'
    $bytes = Get-KitBytes ([ordered]@{ schema = 1; owner = $script:KitOwner; state = $State; message = $Message; updatedUtc = [DateTime]::UtcNow.ToString('o') })
    Write-KitFile $path $bytes $ExpectedHash
    return Get-KitHashBytes $bytes
}
function Get-KitPlayer([string]$PlayerPath) {
    $path = Get-KitRoot $PlayerPath
    Assert-KitNoReparse $path
    if (-not [IO.File]::Exists($path) -or [IO.Path]::GetExtension($path) -ine '.exe') { throw 'PlayerPath must identify an existing executable; it will not be launched.' }
    return $path
}
function Initialize-KitNative {
    if (-not ('MpvnetKitNative' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class MpvnetKitNative {
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
function Get-KitRoamingRoot {
    return [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
}
function Test-KitEntryExists([string]$Path) {
    try { [void][IO.File]::GetAttributes($Path); return $true }
    catch [IO.FileNotFoundException] { return $false }
    catch [IO.DirectoryNotFoundException] { return $false }
}
function Lock-KitDirectory([string]$Path, [bool]$Owned = $false) {
    Initialize-KitNative
    Assert-KitNoReparse $Path
    # No delete sharing: checked directories and their parents cannot be replaced.
    $access = if ($Owned) { 0x00010001 } else { 1 }
    $handle = [MpvnetKitNative]::CreateFile($Path, $access, 3, [IntPtr]::Zero, 3, 0x02200000, [IntPtr]::Zero)
    if ($handle.IsInvalid) { $handle.Dispose(); throw "Cannot lock a plain directory: $Path" }
    try {
        if (-not [MpvnetKitNative]::IsPlainDirectory($handle)) { throw "Not a plain directory: $Path" }
        Assert-KitNoReparse $Path
    } catch { $handle.Dispose(); throw }
    return $handle
}
function Add-KitExistingDirectoryLocks([string]$Path, $Locks) {
    $path = Get-KitRoot $Path
    if ($Locks.ContainsKey($path)) { return }
    $parent = [IO.Directory]::GetParent($path)
    if ($parent) { Add-KitExistingDirectoryLocks $parent.FullName $Locks }
    Assert-KitNoReparse $path
    if ([IO.Directory]::Exists($path)) { $Locks[$path] = Lock-KitDirectory $path }
    elseif (Test-KitEntryExists $path) { throw "A non-directory entry occupies a directory path: $path" }
}
function Get-KitDirectoryIdentity([string]$Path) {
    if (-not [IO.Directory]::Exists($Path)) { return '' }
    $handle = Lock-KitDirectory $Path
    try {
        $identity = [MpvnetKitNative]::GetIdentity($handle)
        if (-not $identity) { throw "Cannot identify directory: $Path" }
        return $identity
    } finally { $handle.Dispose() }
}
function Get-KitDirectoryContext([string]$Path) {
    $target = Get-KitRoot $Path
    if ($target.TrimEnd('\', '/') -ieq ([IO.Path]::GetPathRoot($target)).TrimEnd('\', '/')) { throw 'A volume or UNC share root cannot be an installation directory.' }
    $locks = @{}
    try {
        Add-KitExistingDirectoryLocks $target $locks
        $parent = [IO.Directory]::GetParent($target)
        while ($parent -and -not [IO.Directory]::Exists($parent.FullName)) { $parent = $parent.Parent }
        if (-not $parent) { throw 'Cannot identify an existing parent directory.' }
        $exists = [IO.Directory]::Exists($target)
        $identity = if ($exists) { [MpvnetKitNative]::GetIdentity($locks[$target]) } else { '' }
        $parentIdentity = [MpvnetKitNative]::GetIdentity($locks[$parent.FullName])
        if (($exists -and -not $identity) -or -not $parentIdentity) { throw 'Cannot identify the installation directory or its existing parent.' }
        return [pscustomobject]@{ target = $target; targetExists = $exists; targetIdentity = $identity;
            nearestExistingParent = $parent.FullName; nearestExistingParentIdentity = $parentIdentity }
    } finally { foreach ($handle in $locks.Values) { $handle.Dispose() } }
}
function Get-KitTargetContext {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$PlayerPath, [string]$ConfigDirectory = '')
    $player = Get-KitPlayer $PlayerPath
    $home = [Environment]::GetEnvironmentVariable('MPVNET_HOME', [EnvironmentVariableTarget]::Process)
    $portable = Join-Path ([IO.Path]::GetDirectoryName($player)) 'portable_config'
    $portableExists = Test-KitEntryExists $portable
    if ($ConfigDirectory) {
        $target = $ConfigDirectory; $source = 'explicit'; $label = '显式指定的配置目录'
    } elseif ($home -and (Test-KitEntryExists $home)) {
        $target = $home; $source = 'environment'; $label = '当前进程的 MPVNET_HOME'
    } elseif ($portableExists) {
        $target = $portable; $source = 'portable'; $label = '播放器旁已有 portable_config（便携模式）'
    } else {
        $roaming = Get-KitRoamingRoot
        if (-not $roaming) { throw 'Cannot obtain the current user Roaming AppData directory.' }
        $target = Join-Path (Get-KitRoot $roaming) 'mpv.net'; $source = 'appdata'; $label = '当前用户 Roaming AppData（安装模式）'
    }
    $directory = Get-KitDirectoryContext $target
    $context = [ordered]@{ target = $directory.target; source = $source; sourceLabel = $label;
        environmentHome = $home; portableExists = $portableExists; targetExists = $directory.targetExists;
        targetIdentity = $directory.targetIdentity; nearestExistingParent = $directory.nearestExistingParent;
        nearestExistingParentIdentity = $directory.nearestExistingParentIdentity }
    $parts = @(1, $directory.target.ToLowerInvariant(), $source, $home, [int]$portableExists, [int]$directory.targetExists,
        $directory.targetIdentity, $directory.nearestExistingParent.ToLowerInvariant(), $directory.nearestExistingParentIdentity)
    $context['contextToken'] = 'mpvnet-kit-target-v1:' + (Get-KitTokenHash $parts)
    return [pscustomobject]$context
}
function New-KitLockedDirectory([string]$Path, $Locks) {
    $path = Get-KitRoot $Path
    if ($Locks.ContainsKey($path)) { return }
    $parent = [IO.Directory]::GetParent($path)
    if (-not $parent) { throw "No locked parent for directory creation: $path" }
    New-KitLockedDirectory $parent.FullName $Locks
    Assert-KitNoReparse $path
    # All directories that existed at preflight were locked before any writes.
    if (-not [MpvnetKitNative]::CreateDirectory($path, [IntPtr]::Zero)) { throw "Directory appeared after preflight or cannot be created: $path" }
    $Locks[$path] = Lock-KitDirectory $path
}
function Get-KitInstallPlanToken($Plan) {
    $parts = @(1, $Plan.player.ToLowerInvariant(), $Plan.targetContext.contextToken, $Plan.package.root.ToLowerInvariant(),
        $Plan.package.manifestSha256, $Plan.backupRoot.ToLowerInvariant(), [int]$Plan.backupContext.targetExists,
        $Plan.backupContext.targetIdentity, $Plan.backupContext.nearestExistingParent.ToLowerInvariant(),
        $Plan.backupContext.nearestExistingParentIdentity, $(if ($Plan.receipt) { $Plan.receipt.sha256 } else { $null }))
    foreach ($file in $Plan.files) { $parts += @($file.path, [int]$file.oldExists, $file.oldSha256) }
    return 'mpvnet-kit-install-v1:' + (Get-KitTokenHash $parts)
}
function Get-KitInstallPlan([string]$PlayerPath, [string]$ConfigDirectory, [string]$BackupRoot, [string]$PackageRoot) {
    $player = Get-KitPlayer $PlayerPath
    $context = Get-KitTargetContext -PlayerPath $player -ConfigDirectory $ConfigDirectory
    $package = Get-KitPackage $PackageRoot
    if (-not $BackupRoot) { $BackupRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'mpvnet-kit/backups' }
    $target = $context.target; $backup = Get-KitRoot $BackupRoot
    Assert-KitNoReparse $target; Assert-KitNoReparse $backup
    Assert-KitSeparate @($package.root, $target, $backup)
    if ($player.StartsWith($target.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'The configuration directory cannot contain the player executable.' }
    $backupContext = Get-KitDirectoryContext $backup
    $receipt = Get-KitReceipt $target
    $files = @()
    if ($receipt) {
        $oldSet = @{}; foreach ($f in $receipt.value.files) { $oldSet[$f.path] = $true }
        $newPaths = @($package.runtime | ForEach-Object { $_.path })
        if (@($receipt.value.files | Where-Object { $newPaths -cnotcontains $_.path }).Count) { throw 'Runtime files removed or renamed; restore the active installation before installing this package.' }
    }
    foreach ($item in $package.runtime) {
        $path = Get-KitPath $target $item.path
        if ([IO.Directory]::Exists($path)) { throw "A directory occupies a runtime file: $($item.path)" }
        $oldExists = [IO.File]::Exists($path)
        if ($receipt -and -not $oldSet.ContainsKey($item.path) -and $oldExists) { throw "Unknown file occupies a new runtime path: $($item.path)" }
        $oldBytes = $null
        if ($oldExists) { $oldBytes = [IO.File]::ReadAllBytes($path) }
        $oldSha = if ($oldExists) { Get-KitHashBytes $oldBytes } else { $null }
        $files += [pscustomobject]@{ path = $item.path; target = $path; oldExists = $oldExists; oldSha256 = $oldSha; newSha256 = $item.sha256;
            changed = ($oldSha -cne $item.sha256); oldBytes = $oldBytes; newBytes = $item.bytes }
    }
    $noop = $receipt -and $receipt.value.packageManifestSha256 -ceq $package.manifestSha256
    if ((Get-KitTargetContext -PlayerPath $player -ConfigDirectory $ConfigDirectory).contextToken -cne $context.contextToken) { throw 'Target directory context changed during preflight; preview again.' }
    $warnings = @()
    if ($context.source -eq 'environment') { $warnings += '目录按安装器当前进程的 MPVNET_HOME 判断；启动播放器时须使用相同环境。' }
    $view = [ordered]@{ mode = 'preview'; action = $(if ($noop) { 'no-op' } elseif (-not @($files | Where-Object changed).Count) { 'record-ownership' } else { 'install' });
        target = $target; player = $player; backupRoot = $backup; packageVersion = $package.version; verifiedPackageFiles = $package.verifiedFileCount;
        targetSource = $context.source; targetSourceLabel = $context.sourceLabel; targetExists = $context.targetExists; warnings = $warnings;
        runtimeFiles = $files.Count; changedFiles = @($files | Where-Object changed).Count; requirement = 'Close affected player instances before Apply; this tool never launches or kills players.';
        files = @($files | ForEach-Object { [ordered]@{ path = $_.path; oldExists = $_.oldExists; oldSha256 = $_.oldSha256; newSha256 = $_.newSha256; changed = $_.changed } }) }
    $plan = [pscustomobject]@{ player = $player; package = $package; target = $target; targetContext = $context;
        backupRoot = $backup; backupContext = $backupContext; receipt = $receipt; files = $files; noop = $noop; view = $view; planToken = '' }
    $plan.planToken = Get-KitInstallPlanToken $plan
    $view['planToken'] = $plan.planToken
    return $plan
}
function Invoke-KitInstall([string]$PlayerPath, [string]$ConfigDirectory, [string]$BackupRoot, [string]$PackageRoot, [switch]$Apply, [string]$ExpectedPlanToken = '') {
    $plan = Get-KitInstallPlan $PlayerPath $ConfigDirectory $BackupRoot $PackageRoot
    if (-not $Apply) { return $plan.view }
    if (-not $ConfigDirectory -and -not $ExpectedPlanToken) { throw 'Automatic target Apply requires -ExpectedPlanToken from a reviewed preview.' }
    if ($ExpectedPlanToken -and $ExpectedPlanToken -cne $plan.planToken) { throw 'Install plan changed; preview and confirm the new plan before Apply.' }
    if ($plan.noop) { return $plan.view }
    $locks = @{}
    try {
        # Acquire every existing directory chain before creating target or backup entries.
        foreach ($root in @($plan.target, $plan.backupRoot, $plan.package.root)) { Add-KitExistingDirectoryLocks $root $locks }
        foreach ($f in $plan.files) { Add-KitExistingDirectoryLocks ([IO.Path]::GetDirectoryName($f.target)) $locks }
        foreach ($f in $plan.package.runtime) { Add-KitExistingDirectoryLocks ([IO.Path]::GetDirectoryName((Get-KitPath $plan.package.root ('config/' + $f.path)))) $locks }
        $current = Get-KitInstallPlan $PlayerPath $ConfigDirectory $BackupRoot $PackageRoot
        if ($current.planToken -cne $plan.planToken) { throw 'Install plan changed while acquiring directory locks; preview again.' }
        $plan = $current
        $id = [Guid]::NewGuid().ToString('N'); $directory = Get-KitPath $plan.backupRoot $id
        foreach ($f in $plan.files) { Assert-KitExpected $f.target $f.oldSha256 }
        $receiptPath = Get-KitPath $plan.target $script:ReceiptName
        $oldReceiptSha = if ($plan.receipt) { $plan.receipt.sha256 } else { $null }
        Assert-KitExpected $receiptPath $oldReceiptSha
        if ([IO.Directory]::Exists($directory) -or [IO.File]::Exists($directory)) { throw 'Backup ID already exists.' }
        New-KitLockedDirectory $directory $locks
        foreach ($f in $plan.files) {
            if ($f.oldExists -and $f.changed) { New-KitLockedDirectory ([IO.Path]::GetDirectoryName((Get-KitPath $directory ('files/' + $f.path)))) $locks }
        }
        $recordFiles = @()
        foreach ($f in $plan.files) {
            $saved = if ($f.oldExists -and $f.changed) { 'files/' + $f.path } else { $null }
            if ($saved) { Write-KitFile (Get-KitPath $directory $saved) $f.oldBytes $null }
            $recordFiles += [ordered]@{ path = $f.path; oldExists = $f.oldExists; oldSha256 = $f.oldSha256; newSha256 = $f.newSha256; changed = $f.changed; backup = $saved }
        }
        if ($plan.receipt) { Write-KitFile (Get-KitPath $directory 'previous-receipt.json') $plan.receipt.bytes $null }
        $record = [ordered]@{ schema = 1; owner = $script:KitOwner; kind = 'backup'; id = $id; target = $plan.target; packageVersion = $plan.package.version;
            packageManifestSha256 = $plan.package.manifestSha256; createdUtc = [DateTime]::UtcNow.ToString('o'); files = $recordFiles;
            previousReceipt = [ordered]@{ exists = [bool]$plan.receipt; sha256 = $oldReceiptSha; backup = $(if ($plan.receipt) { 'previous-receipt.json' } else { $null }) } }
        $dataSha = Get-KitHashBytes (Get-KitBytes $record)
        $receipt = [ordered]@{ schema = 1; owner = $script:KitOwner; kind = 'receipt'; id = $id; target = $plan.target; packageVersion = $plan.package.version;
            packageManifestSha256 = $plan.package.manifestSha256; backupDirectory = $directory; backupDataSha256 = $dataSha;
            files = @($plan.files | ForEach-Object { [ordered]@{ path = $_.path; sha256 = $_.newSha256 } }) }
        $receiptBytes = Get-KitBytes $receipt; $receiptSha = Get-KitHashBytes $receiptBytes
        $record['dataSha256'] = $dataSha; $record['receiptSha256'] = $receiptSha
        Write-KitFile (Get-KitPath $directory 'manifest.json') (Get-KitBytes $record) $null
        $statusSha = Save-KitStatus $directory 'prepared' 'All preflight and backup data complete; no target writes yet.' $null
        $written = @(); $receiptWritten = $false
        try {
            New-KitLockedDirectory $plan.target $locks
            foreach ($f in $plan.files) { New-KitLockedDirectory ([IO.Path]::GetDirectoryName($f.target)) $locks }
            foreach ($f in $plan.files) {
                if ($f.changed) { Write-KitFile $f.target $f.newBytes $f.oldSha256; $written += $f }
            }
            Write-KitFile $receiptPath $receiptBytes $oldReceiptSha; $receiptWritten = $true
            $statusSha = Save-KitStatus $directory 'installed' 'Installation completed; backup retained.' $statusSha
            $plan.view['mode'] = 'applied'; $plan.view['id'] = $id; $plan.view['backupManifest'] = (Get-KitPath $directory 'manifest.json')
            return $plan.view
        } catch {
            $failure = $_.Exception.Message; $rollbackErrors = @()
            if ($receiptWritten) {
                try { if ($plan.receipt) { Write-KitFile $receiptPath $plan.receipt.bytes $receiptSha } else { Remove-KitFile $receiptPath $receiptSha } }
                catch { $rollbackErrors += $_.Exception.Message }
            }
            [array]::Reverse($written)
            foreach ($f in $written) {
                try { if ($f.oldExists) { Write-KitFile $f.target $f.oldBytes $f.newSha256 } else { Remove-KitFile $f.target $f.newSha256 } }
                catch { $rollbackErrors += $_.Exception.Message }
            }
            try { [void](Save-KitStatus $directory $(if ($rollbackErrors.Count) { 'rollback-incomplete' } else { 'rolled-back' }) ($failure + '; ' + ($rollbackErrors -join '; ')) $statusSha) } catch { $rollbackErrors += $_.Exception.Message }
            throw "Installation failed. Best-effort rollback recorded in $directory. $failure"
        }
    } finally { foreach ($handle in $locks.Values) { $handle.Dispose() } }
}
function Test-KitRestored($Loaded) {
    $record = $Loaded.value
    $receiptPath = Get-KitPath $Loaded.target $script:ReceiptName
    $expectedReceipt = if ($record.previousReceipt.exists) { $record.previousReceipt.sha256 } else { $null }
    Assert-KitExpected $receiptPath $expectedReceipt
    if ($record.previousReceipt.exists) { [void](Get-KitReceipt $Loaded.target) }
    foreach ($f in $record.files) {
        $expected = if ($f.oldExists) { $f.oldSha256 } else { $null }
        Assert-KitExpected (Get-KitPath $Loaded.target $f.path) $expected
    }
}
function Invoke-KitRestore([string]$BackupManifest, [switch]$Apply) {
    $loaded = Read-KitRecord $BackupManifest; $record = $loaded.value
    $statusPath = Get-KitPath $loaded.directory 'status.json'
    $statusSha = Get-KitHash $statusPath
    $status = if ($statusSha) { Read-KitJson $statusPath } else { $null }
    if ($status -and $status.state -eq 'restored') {
        Test-KitRestored $loaded
        return [ordered]@{ mode = 'preview'; action = 'no-op'; target = $loaded.target; id = $record.id; reason = 'This backup is already fully restored.' }
    }
    $active = Get-KitReceipt $loaded.target
    if (-not $active -or $active.value.id -cne $record.id -or $active.sha256 -cne $record.receiptSha256) { throw 'Restore requires the latest active receipt ID; wrong order or missing state refused.' }
    foreach ($f in $record.files) { Assert-KitExpected (Get-KitPath $loaded.target $f.path) $f.newSha256 }
    $previousBytes = $null
    if ($record.previousReceipt.exists) {
        $previousBytes = [IO.File]::ReadAllBytes((Get-KitPath $loaded.directory 'previous-receipt.json'))
        $previous = $script:KitUtf8.GetString($previousBytes) | ConvertFrom-Json
        [void](Assert-KitReceiptData $previous $loaded.target $record.previousReceipt.sha256)
        if ($previous.id -ceq $record.id) { throw 'Cyclic receipt refused.' }
    }
    $view = [ordered]@{ mode = 'preview'; action = 'restore'; target = $loaded.target; id = $record.id; changedFiles = @($record.files | Where-Object changed).Count;
        requirement = 'Close affected player instances before Apply.'; files = $record.files }
    if (-not $Apply) { return $view }
    try {
        foreach ($f in $record.files) {
            if (-not $f.changed) { continue }
            $path = Get-KitPath $loaded.target $f.path
            if ($f.oldExists) { Write-KitFile $path ([IO.File]::ReadAllBytes((Get-KitPath $loaded.directory $f.backup))) $f.newSha256 }
            else { Remove-KitFile $path $f.newSha256 }
        }
        if ($record.previousReceipt.exists) { Write-KitFile $active.path $previousBytes $active.sha256 }
        else { Remove-KitFile $active.path $active.sha256 }
        [void](Save-KitStatus $loaded.directory 'restored' 'Previous files and receipt restored; backup retained.' $statusSha)
        $view['mode'] = 'applied'
        return $view
    } catch {
        $failure = $_.Exception.Message
        try { [void](Save-KitStatus $loaded.directory 'restore-incomplete' $failure $statusSha) } catch { }
        throw "Restore interrupted; retained backup and report in $($loaded.directory). Partial state is preserved; do not blindly retry. Compare retained hashes before manual recovery."
    }
}
function Write-KitResult($Value, [ValidateSet('Json', 'Text')][string]$OutputFormat = 'Json', [switch]$Details) {
    [Console]::OutputEncoding = $script:KitUtf8
    if ($OutputFormat -eq 'Json') {
        [Console]::WriteLine(($Value | ConvertTo-Json -Depth 20))
        return
    }
    # Normalize dictionary/object access once; missing optional fields remain null under StrictMode.
    $data = @{}
    if ($Value -is [System.Collections.IDictionary]) { foreach ($key in $Value.Keys) { $data[$key] = $Value[$key] } }
    else { foreach ($property in $Value.PSObject.Properties) { $data[$property.Name] = $property.Value } }
    $lines = New-Object 'System.Collections.Generic.List[string]'
    if ($data['status'] -eq 'refused-or-failed') {
        $lines.Add('未完成：检查或操作被拒绝／失败')
        $lines.Add('请保留现场，查看下方原因；修正后重新预览。若已开始写入，请先核对备份与失败记录，不要盲目重试。')
        $lines.Add(''); $lines.Add('原始错误：'); $lines.Add([string]$data['error'])
        [Console]::WriteLine(($lines -join "`r`n")); return
    }
    $operation = if ($data['mode'] -eq 'read-only') { '依赖检查（只读）' }
        elseif ($data['action'] -eq 'restore') { '恢复' }
        elseif ($data['action'] -eq 'no-op') { '无需变更' }
        elseif ($data['action'] -eq 'record-ownership') { '记录安装归属' } else { '安装' }
    $state = if ($data['mode'] -eq 'applied') { '已完成' } elseif ($data['mode'] -eq 'read-only') { '检查结果' } else { '预览，尚未写入' }
    $lines.Add("$operation · $state")
    if ($data['target']) { $lines.Add("配置目录：$($data['target'])") }
    elseif ($data['configDirectory']) { $lines.Add("配置目录：$($data['configDirectory'])") }
    if ($data['targetSourceLabel']) { $lines.Add("识别来源：$($data['targetSourceLabel'])") }
    if ($data.ContainsKey('targetExists')) { $lines.Add('目录状态：' + $(if ($data['targetExists']) { '检查时已存在' } else { '检查时不存在' })) }
    if ($data['targetSource'] -eq 'explicit') { $lines.Add('提示：显式目录仅指定操作位置，请确认播放器实际读取该目录。') }
    if ($data['packageVersion']) { $lines.Add("包版本：$($data['packageVersion'])") }
    if ($data.ContainsKey('verifiedPackageFiles')) { $lines.Add("已校验包文件：$($data['verifiedPackageFiles'])") }
    if ($data.ContainsKey('runtimeFiles')) { $lines.Add("受管运行文件：$($data['runtimeFiles'])") }
    if ($data.ContainsKey('changedFiles')) { $lines.Add("本次变更文件：$($data['changedFiles'])") }
    if ($data['backupRoot']) { $lines.Add("备份根目录：$($data['backupRoot'])") }
    if ($data['backupManifest']) { $lines.Add("本次恢复清单：$($data['backupManifest'])") }
    if ($data['id']) { $lines.Add("记录 ID：$($data['id'])") }
    if ($data['warnings']) { foreach ($warning in $data['warnings']) { $lines.Add("提示：$warning") } }
    if ($data['mode'] -eq 'read-only') {
        $lines.Add('')
        foreach ($name in @('ffmpeg', 'python', 'powershell', 'thumbnailWorker')) {
            $tool = $data[$name]
            if ($tool) {
                $label = @{ ffmpeg = 'FFmpeg'; python = 'Python'; powershell = 'PowerShell'; thumbnailWorker = '缩略图后端' }[$name]
                $lines.Add("${label}：" + $(if ($tool.present) { '已找到' } else { '未找到' }))
                if ($Details) { $lines.Add("  路径：$($tool.path)"); $lines.Add("  来源：$($tool.source)") }
            }
        }
        $lines.Add('缺少 FFmpeg 影响片段导出；缺少 Python 影响弹幕转换，不阻止基本安装。')
        $lines.Add('以上仅为路径与静态元数据检查，未运行依赖程序，不代表播放能力已验证。')
    }
    if ($data['planToken'] -and $data['mode'] -ne 'applied') {
        $lines.Add(''); $lines.Add("预览校验值：$($data['planToken'])")
        $lines.Add('确认目标及变更后，在相同参数后追加：')
        $lines.Add("  -Apply -ExpectedPlanToken '$($data['planToken'])'")
    } elseif ($data['action'] -eq 'restore' -and $data['mode'] -ne 'applied') {
        $lines.Add('下一步：核对恢复清单后，在相同命令后追加 -Apply。')
    } elseif ($data['mode'] -eq 'applied') {
        $lines.Add('下一步：保留备份与结果，重新启动受影响的播放器。')
    }
    if ($data['mode'] -ne 'read-only') { $lines.Add('执行前请退出受影响播放器；工具不会启动或关闭播放器。') }
    if ($data['reason']) { $lines.Add("说明：$($data['reason'])") }
    if ($Details -and $data['files']) {
        $lines.Add(''); $lines.Add('文件明细：')
        foreach ($file in $data['files']) {
            $lines.Add('  [' + $(if ($file.changed) { '变更' } else { '保持' }) + "] $($file.path)")
            $lines.Add("    原 SHA256：$($file.oldSha256)")
            $lines.Add("    包 SHA256：$($file.newSha256)")
        }
    }
    [Console]::WriteLine(($lines -join "`r`n"))
}

Export-ModuleMember -Function Get-KitHash,Get-KitRoot,Get-KitPath,Get-KitPlayer,Get-KitPackage,Get-KitTargetContext,Get-KitDirectoryIdentity,Initialize-KitNative,Lock-KitDirectory,Add-KitExistingDirectoryLocks,Get-KitInstallPlan,Invoke-KitInstall,Invoke-KitRestore,Write-KitResult
