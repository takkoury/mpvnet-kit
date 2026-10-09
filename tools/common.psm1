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
function Get-KitRoot([string]$Path) {
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
    $manifest = Read-KitJson $manifestPath
    Assert-KitFields $manifest @('schema', 'version', 'files')
    if ($manifest.schema -ne 1 -or $manifest.version -isnot [string] -or -not $manifest.version -or @($manifest.files).Count -eq 0) { throw 'Unsupported package manifest.' }
    $seen = @{}; $runtime = @()
    foreach ($file in $manifest.files) {
        Assert-KitFields $file @('path', 'sha256')
        if ($file.path -isnot [string] -or $file.sha256 -notmatch '^[0-9a-f]{64}$' -or $seen.ContainsKey($file.path)) { throw 'Invalid or case-colliding package entry.' }
        $seen[$file.path] = $true
        $path = Get-KitPath $root $file.path
        $bytes = [IO.File]::ReadAllBytes($path)
        if ((Get-KitHashBytes $bytes) -cne $file.sha256) { throw "Package checksum mismatch: $($file.path)" }
        if ($file.path.StartsWith('config/', [StringComparison]::Ordinal) -and -not $file.path.EndsWith('.example', [StringComparison]::OrdinalIgnoreCase)) {
            $relative = $file.path.Substring(7)
            if ($relative -eq 'script-opts/mpvnet-local.conf' -or $relative -eq $script:ReceiptName) { throw 'Private or state files cannot be package runtime files.' }
            $runtime += [pscustomobject]@{ path = $relative; sha256 = $file.sha256; bytes = $bytes }
        }
    }
    if ($runtime.Count -eq 0) { throw 'The package has no runtime payload.' }
    return [pscustomobject]@{ root = $root; version = $manifest.version; manifestSha256 = (Get-KitHash $manifestPath); runtime = $runtime; verifiedFileCount = @($manifest.files).Count }
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
function Get-KitInstallPlan([string]$PlayerPath, [string]$ConfigDirectory, [string]$BackupRoot, [string]$PackageRoot) {
    $player = Get-KitPlayer $PlayerPath
    $package = Get-KitPackage $PackageRoot
    if (-not $ConfigDirectory) { $ConfigDirectory = Join-Path ([IO.Path]::GetDirectoryName($player)) 'portable_config' }
    if (-not $BackupRoot) { $BackupRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'mpvnet-kit/backups' }
    $target = Get-KitRoot $ConfigDirectory; $backup = Get-KitRoot $BackupRoot
    Assert-KitNoReparse $target; Assert-KitNoReparse $backup
    Assert-KitSeparate @($package.root, $target, $backup)
    $receipt = Get-KitReceipt $target
    $files = @()
    if ($receipt) {
        $oldSet = @{}; foreach ($f in $receipt.value.files) { $oldSet[$f.path] = $true }
        if ($oldSet.Count -ne $package.runtime.Count -or @($package.runtime | Where-Object { -not $oldSet.ContainsKey($_.path) }).Count) { throw 'Runtime file set changed; restore the active installation before installing this package.' }
    }
    foreach ($item in $package.runtime) {
        $path = Get-KitPath $target $item.path
        if ([IO.Directory]::Exists($path)) { throw "A directory occupies a runtime file: $($item.path)" }
        $oldExists = [IO.File]::Exists($path)
        $oldBytes = $null
        if ($oldExists) { $oldBytes = [IO.File]::ReadAllBytes($path) }
        $oldSha = if ($oldExists) { Get-KitHashBytes $oldBytes } else { $null }
        $files += [pscustomobject]@{ path = $item.path; target = $path; oldExists = $oldExists; oldSha256 = $oldSha; newSha256 = $item.sha256;
            changed = ($oldSha -cne $item.sha256); oldBytes = $oldBytes; newBytes = $item.bytes }
    }
    $noop = $receipt -and $receipt.value.packageManifestSha256 -ceq $package.manifestSha256
    $view = [ordered]@{ mode = 'preview'; action = $(if ($noop) { 'no-op' } elseif (-not @($files | Where-Object changed).Count) { 'record-ownership' } else { 'install' });
        target = $target; player = $player; backupRoot = $backup; packageVersion = $package.version; verifiedPackageFiles = $package.verifiedFileCount;
        runtimeFiles = $files.Count; changedFiles = @($files | Where-Object changed).Count; requirement = 'Close affected player instances before Apply; this tool never launches or kills players.';
        files = @($files | ForEach-Object { [ordered]@{ path = $_.path; oldExists = $_.oldExists; oldSha256 = $_.oldSha256; newSha256 = $_.newSha256; changed = $_.changed } }) }
    return [pscustomobject]@{ package = $package; target = $target; backupRoot = $backup; receipt = $receipt; files = $files; noop = $noop; view = $view }
}
function Invoke-KitInstall([string]$PlayerPath, [string]$ConfigDirectory, [string]$BackupRoot, [string]$PackageRoot, [switch]$Apply) {
    $plan = Get-KitInstallPlan $PlayerPath $ConfigDirectory $BackupRoot $PackageRoot
    if (-not $Apply -or $plan.noop) { return $plan.view }
    $id = [Guid]::NewGuid().ToString('N'); $directory = Get-KitPath $plan.backupRoot $id
    foreach ($f in $plan.files) { Assert-KitExpected $f.target $f.oldSha256 }
    $receiptPath = Get-KitPath $plan.target $script:ReceiptName
    $oldReceiptSha = if ($plan.receipt) { $plan.receipt.sha256 } else { $null }
    Assert-KitExpected $receiptPath $oldReceiptSha
    if ([IO.Directory]::Exists($directory) -or [IO.File]::Exists($directory)) { throw 'Backup ID already exists.' }
    [void][IO.Directory]::CreateDirectory($directory)
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
function Write-KitResult($Value) {
    [Console]::OutputEncoding = $script:KitUtf8
    [Console]::WriteLine(($Value | ConvertTo-Json -Depth 20))
}
Export-ModuleMember -Function Get-KitHash,Get-KitRoot,Get-KitPath,Get-KitPlayer,Get-KitPackage,Invoke-KitInstall,Invoke-KitRestore,Write-KitResult
