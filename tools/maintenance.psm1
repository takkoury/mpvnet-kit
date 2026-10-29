Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
# Keep each module instance: importing common with -Force can remove another module's commands.
$script:MaintenanceCommon = Import-Module (Join-Path $PSScriptRoot 'common.psm1') -PassThru
$script:MaintenanceClean = Import-Module (Join-Path $PSScriptRoot 'clean-install.psm1') -PassThru
$script:MaintenanceLegacy = Import-Module (Join-Path $PSScriptRoot 'legacy-install.psm1') -PassThru
$script:MaintenanceUtf8 = New-Object Text.UTF8Encoding($false)
$script:MaintenancePendingName = '.mpvnet-kit-operation.json'
$script:MaintenanceReceiptName = '.mpvnet-kit-install.json'

function Get-MaintenanceBytes($Value) { return ,$script:MaintenanceUtf8.GetBytes(($Value | ConvertTo-Json -Depth 24) + "`n") }
function Get-MaintenanceHashBytes([byte[]]$Bytes) { return & $script:MaintenanceCommon { param($Data) Get-KitHashBytes $Data } $Bytes }
function Get-MaintenanceHashParts([object[]]$Parts) { return & $script:MaintenanceCommon { param($Data) Get-KitTokenHash $Data } $Parts }
function Get-MaintenanceDirectoryContext([string]$Path) { return & $script:MaintenanceCommon { param($Value) Get-KitDirectoryContext $Value } $Path }
function New-MaintenanceDirectory([string]$Path, $Locks) { & $script:MaintenanceCommon { param($Value, $Handles) New-KitLockedDirectory $Value $Handles } $Path $Locks }
function Write-MaintenanceFile([string]$Path, [byte[]]$Bytes, [string]$ExpectedHash) { & $script:MaintenanceCommon { param($Value, $Data, $Expected) Write-KitFile $Value $Data $Expected } $Path $Bytes $ExpectedHash }
function Remove-MaintenanceFile([string]$Path, [string]$ExpectedHash) { & $script:MaintenanceCommon { param($Value, $Expected) Remove-KitFile $Value $Expected } $Path $ExpectedHash }
function Assert-MaintenanceExpected([string]$Path, [string]$ExpectedHash) { & $script:MaintenanceCommon { param($Value, $Expected) Assert-KitExpected $Value $Expected } $Path $ExpectedHash }
function Write-MaintenanceTargetFile([string]$Path, [byte[]]$Bytes, [string]$ExpectedHash) { Write-MaintenanceFile $Path $Bytes $ExpectedHash }
function Get-MaintenanceRunningPlayers {
    # Read only names and PIDs. Do not request command lines, paths or playback data.
    $players = @(Get-Process -ErrorAction Stop | Where-Object { $_.ProcessName -ieq 'mpvnet' })
    return @($players | Sort-Object Id | ForEach-Object { [pscustomobject]@{ pid = $_.Id; name = $_.ProcessName } })
}
function Assert-MaintenancePlayersStopped {
    if (@(Get-MaintenanceRunningPlayers).Count) { throw '请先退出所有 mpv.net 播放器，再重新检查。安装器不会关闭播放器。' }
}
function Assert-MaintenanceFields($Value, [string[]]$Names) {
    if ($Value -isnot [pscustomobject]) { throw '操作记录格式无效，请保留现场。' }
    $actual = @($Value.PSObject.Properties | ForEach-Object { $_.Name })
    if ($actual.Count -ne $Names.Count) { throw '操作记录字段无效，请保留现场。' }
    foreach ($name in $Names) { if ($actual -cnotcontains $name) { throw '操作记录缺少必要字段，请保留现场。' } }
}
function Assert-MaintenanceRuntimePath($Path) {
    if ($Path -isnot [string]) { throw '操作记录中的文件路径无效。' }
    & $script:MaintenanceCommon { param($Value) Assert-KitRelative $Value } $Path
    if ($Path.StartsWith('config/', [StringComparison]::OrdinalIgnoreCase) -or $Path.EndsWith('.example', [StringComparison]::OrdinalIgnoreCase) -or
        $Path -iin @('mpvnet-user.json', 'script-opts/mpvnet-local.conf', 'mpvnet-local.conf', 'local.conf', 'settings.xml', 'desktop.ini',
            '.mpvnet-kit-install.json', '.mpvnet-kit-operation.json') -or $Path.Split('/')[0] -iin @('cache', 'watch_later')) {
        throw '操作记录不能包含个人配置、播放记录或安装状态文件。'
    }
}
function Assert-MaintenanceStateHash($Exists, $Hash) {
    if ($Exists -isnot [bool] -or ($Exists -and ($Hash -isnot [string] -or $Hash -cnotmatch '^[0-9a-f]{64}$')) -or (-not $Exists -and $null -ne $Hash)) {
        throw '操作记录中的文件状态或校验值无效。'
    }
}
function Test-MaintenanceSchema($Value) { return (($Value -is [int] -or $Value -is [long]) -and $Value -eq 1) }
function Assert-MaintenanceJournalRecord($Journal, $ReceiptBefore, [string]$Directory, [string]$Target) {
    $relative = if ($Journal.operation -ceq 'Apply') { 'manifest.json' } else { 'source/manifest.json' }
    $loaded = & $script:MaintenanceCommon { param($Value) Read-KitRecord $Value } (Get-KitPath $Directory $relative)
    $record = $loaded.value
    if ($loaded.target -ine $Target -or @($record.files).Count -ne $Journal.files.Count) { throw '恢复记录与真实备份清单不一致。' }
    $recordFiles = @{}; foreach ($file in $record.files) { Assert-MaintenanceRuntimePath $file.path; $recordFiles[$file.path] = $file }
    if ($Journal.operation -ceq 'Apply') {
        if ($record.id -cne $Journal.id) { throw '恢复记录与真实备份清单的标识不一致。' }
        $installedBytes = [IO.File]::ReadAllBytes((Get-KitPath $Directory 'installed-receipt.json'))
        $installedHash = Get-MaintenanceHashBytes $installedBytes
        $installed = $script:MaintenanceUtf8.GetString($installedBytes) | ConvertFrom-Json
        & $script:MaintenanceCommon { param($Value) Assert-KitFields $Value @('backupDirectory') } $installed
        # Check the pointer before invoking the old receipt validator; it may only read this operation directory.
        if ($installed.backupDirectory -isnot [string] -or (Get-KitRoot $installed.backupDirectory) -ine $Directory) { throw '更新后的安装记录指向其他备份位置。' }
        [void](& $script:MaintenanceCommon { param($Value, $Root, $Hash) Assert-KitReceiptData $Value $Root $Hash } $installed $Target $installedHash)
        if ($installed.id -cne $Journal.id -or $installed.packageVersion -cne $record.packageVersion -or $installed.packageManifestSha256 -cne $record.packageManifestSha256 -or
            $Journal.receipt.afterExists -ne $true -or $Journal.receipt.afterSha256 -cne $installedHash -or
            $Journal.receipt.beforeExists -ne $record.previousReceipt.exists -or $Journal.receipt.beforeSha256 -cne $record.previousReceipt.sha256) { throw '恢复记录与安装记录的前后状态不一致。' }
    } else {
        if (-not $ReceiptBefore -or $ReceiptBefore.id -cne $record.id -or $ReceiptBefore.backupDataSha256 -cne $record.dataSha256 -or
            $Journal.receipt.beforeExists -ne $true -or $Journal.receipt.beforeSha256 -cne $record.receiptSha256 -or
            $Journal.receipt.afterExists -ne $record.previousReceipt.exists -or $Journal.receipt.afterSha256 -cne $record.previousReceipt.sha256 -or
            @($ReceiptBefore.files).Count -ne @($record.files).Count) { throw '还原操作的恢复记录与原安装记录不一致。' }
        foreach ($file in $ReceiptBefore.files) {
            if (-not $recordFiles.ContainsKey($file.path) -or $recordFiles[$file.path].newSha256 -cne $file.sha256) { throw '还原操作的文件集合与原安装记录不一致。' }
        }
    }
    foreach ($file in $Journal.files) {
        if (-not $recordFiles.ContainsKey($file.path)) { throw '恢复记录包含不属于真实备份清单的文件。' }
        $known = $recordFiles[$file.path]
        if ($Journal.operation -ceq 'Apply') {
            if ($file.beforeExists -ne $known.oldExists -or $file.beforeSha256 -cne $known.oldSha256 -or
                $file.afterExists -ne $true -or $file.afterSha256 -cne $known.newSha256 -or $file.backup -cne $known.backup) { throw '更新操作的恢复记录与真实备份不一致。' }
        } elseif ($file.beforeExists -ne $true -or $file.beforeSha256 -cne $known.newSha256 -or
            $file.afterExists -ne $known.oldExists -or $file.afterSha256 -cne $known.oldSha256 -or
            $file.backup -cne $(if ($known.changed) { 'recovery/' + $known.path } else { $null })) { throw '还原操作的恢复记录与真实备份不一致。' }
    }
    return $loaded
}
function Read-MaintenancePending([string]$Target, [string]$BackupRoot) {
    $path = Get-KitPath $Target $script:MaintenancePendingName
    if (-not [IO.File]::Exists($path)) {
        if ([IO.Directory]::Exists($path)) { throw '未完成操作的状态路径被目录占用，请保留现场。' }
        return $null
    }
    $bytes = [IO.File]::ReadAllBytes($path); $sha = Get-MaintenanceHashBytes $bytes
    $pending = $script:MaintenanceUtf8.GetString($bytes) | ConvertFrom-Json
    Assert-MaintenanceFields $pending @('schema', 'owner', 'kind', 'id', 'target', 'backupRoot', 'journalSha256')
    # Validate every pointer component before reading outside the target. The caller's root is authoritative.
    if (-not (Test-MaintenanceSchema $pending.schema) -or $pending.owner -cne 'mpvnet-kit' -or $pending.kind -cne 'pending-operation' -or
        $pending.id -isnot [string] -or $pending.id -cnotmatch '^[0-9a-f]{32}$' -or $pending.target -isnot [string] -or
        $pending.backupRoot -isnot [string] -or (Get-KitRoot $pending.target) -ine $Target -or
        (Get-KitRoot $pending.backupRoot) -ine $BackupRoot -or $pending.journalSha256 -isnot [string] -or $pending.journalSha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw '未完成操作的状态与当前目录或备份位置不一致，请保留现场并核对原备份位置。'
    }
    $directory = Get-KitPath $BackupRoot $pending.id
    & $script:MaintenanceCommon { param($Roots) Assert-KitSeparate $Roots } @($directory, $Target)
    $journalPath = Get-KitPath $directory 'operation.json'
    $journalBytes = [IO.File]::ReadAllBytes($journalPath)
    if ((Get-MaintenanceHashBytes $journalBytes) -cne $pending.journalSha256) { throw '未完成操作的恢复记录已变化，请保留现场。' }
    $journal = $script:MaintenanceUtf8.GetString($journalBytes) | ConvertFrom-Json
    Assert-MaintenanceFields $journal @('schema', 'owner', 'kind', 'id', 'target', 'backupRoot', 'operation', 'files', 'receipt')
    if (-not (Test-MaintenanceSchema $journal.schema) -or $journal.owner -cne 'mpvnet-kit' -or $journal.kind -cne 'maintenance-operation' -or
        $journal.id -cne $pending.id -or $journal.target -cne $pending.target -or $journal.backupRoot -cne $pending.backupRoot -or
        $journal.operation -cnotin @('Apply', 'Restore') -or $journal.files -isnot [array] -or $journal.files.Count -eq 0) { throw '未完成操作的恢复记录无效。' }
    $seen = @{}
    foreach ($file in $journal.files) {
        Assert-MaintenanceFields $file @('path', 'beforeExists', 'beforeSha256', 'afterExists', 'afterSha256', 'backup')
        Assert-MaintenanceRuntimePath $file.path
        if ($seen.ContainsKey($file.path)) { throw '恢复记录包含重复文件路径。' }; $seen[$file.path] = $true
        Assert-MaintenanceStateHash $file.beforeExists $file.beforeSha256; Assert-MaintenanceStateHash $file.afterExists $file.afterSha256
        if ($file.beforeExists -and $file.beforeSha256 -cne $file.afterSha256) {
            $prefix = if ($journal.operation -ceq 'Apply') { 'files/' } else { 'recovery/' }
            if ($file.backup -cne ($prefix + $file.path)) { throw '恢复记录包含无效的备份路径。' }
            if ((Get-KitHash (Get-KitPath $directory $file.backup)) -cne $file.beforeSha256) { throw "操作前备份已变化：$($file.path)。请保留现场。" }
        } elseif ($null -ne $file.backup) { throw '恢复记录包含多余的备份路径。' }
        [void](Get-KitPath $Target $file.path)
    }
    $receipt = $journal.receipt
    Assert-MaintenanceFields $receipt @('beforeExists', 'beforeSha256', 'afterExists', 'afterSha256', 'backup')
    Assert-MaintenanceStateHash $receipt.beforeExists $receipt.beforeSha256; Assert-MaintenanceStateHash $receipt.afterExists $receipt.afterSha256
    $saved = $null
    if ($receipt.beforeExists) {
        $name = if ($journal.operation -ceq 'Apply') { 'previous-receipt.json' } else { 'receipt-before.json' }
        if ($receipt.backup -cne $name -or (Get-KitHash (Get-KitPath $directory $name)) -cne $receipt.beforeSha256) { throw '操作前安装记录的备份已变化，请保留现场。' }
        $saved = $script:MaintenanceUtf8.GetString([IO.File]::ReadAllBytes((Get-KitPath $directory $name))) | ConvertFrom-Json
        # Do not follow backupDirectory from journal bytes. Recovery needs only these saved bytes;
        # the receipt chain was fully verified before the operation began.
        & $script:MaintenanceCommon { param($Value) Assert-KitFields $Value @('schema', 'owner', 'kind', 'id', 'target', 'packageVersion', 'packageManifestSha256', 'backupDirectory', 'backupDataSha256', 'files') } $saved
        if (-not (Test-MaintenanceSchema $saved.schema) -or $saved.owner -cne 'mpvnet-kit' -or $saved.kind -cne 'receipt' -or
            $saved.id -isnot [string] -or $saved.id -cnotmatch '^[0-9a-f]{32}$' -or $saved.target -isnot [string] -or
            (Get-KitRoot $saved.target) -ine $Target -or $saved.backupDirectory -isnot [string] -or
            $saved.packageManifestSha256 -cnotmatch '^[0-9a-f]{64}$' -or $saved.backupDataSha256 -cnotmatch '^[0-9a-f]{64}$' -or
            $saved.files -isnot [array] -or $saved.files.Count -eq 0) { throw '操作前安装记录的备份格式无效。' }
        [void](Get-KitRoot $saved.backupDirectory)
        $savedPaths = @{}
        foreach ($savedFile in $saved.files) {
            & $script:MaintenanceCommon { param($Value) Assert-KitFields $Value @('path', 'sha256') } $savedFile
            Assert-MaintenanceRuntimePath $savedFile.path
            if ($savedPaths.ContainsKey($savedFile.path) -or -not $seen.ContainsKey($savedFile.path) -or $savedFile.sha256 -cnotmatch '^[0-9a-f]{64}$') { throw '操作前安装记录的文件集合无效。' }
            $savedPaths[$savedFile.path] = $true
            $known = @($journal.files | Where-Object { $_.path -ceq $savedFile.path })
            if ($known.Count -ne 1 -or $known[0].beforeSha256 -cne $savedFile.sha256) { throw '操作前安装记录与恢复记录不一致。' }
        }
    } elseif ($null -ne $receipt.backup) { throw '恢复记录包含多余的安装记录备份。' }
    $sourceRecord = Assert-MaintenanceJournalRecord $journal $saved $directory $Target
    return [pscustomobject]@{ path = $path; sha256 = $sha; value = $pending; directory = $directory; journal = $journal; journalPath = $journalPath; sourceRecord = $sourceRecord }
}
function Get-MaintenanceActualHash([string]$Path) {
    # Hash-only reads always refuse a directory or reparse point; missing is an explicit state.
    & $script:MaintenanceCommon { param($Value) Assert-KitNoReparse $Value } $Path
    if ([IO.Directory]::Exists($Path)) { throw '应为文件的位置被文件夹占用，请保留现场。' }
    return Get-KitHash $Path
}
function Assert-MaintenanceRecoverable($Pending, [string]$Target) {
    foreach ($file in $Pending.journal.files) {
        $actual = Get-MaintenanceActualHash (Get-KitPath $Target $file.path)
        if ($actual -cne $file.beforeSha256 -and $actual -cne $file.afterSha256) {
            throw "文件在操作后被其他程序修改或删除：$($file.path)。为保留这些内容，无法自动恢复，请保留现场和备份。"
        }
    }
    $actual = Get-MaintenanceActualHash (Get-KitPath $Target $script:MaintenanceReceiptName)
    if ($actual -cne $Pending.journal.receipt.beforeSha256 -and $actual -cne $Pending.journal.receipt.afterSha256) {
        throw '安装记录在操作后发生了其他变化，无法自动恢复，请保留现场和备份。'
    }
    Assert-MaintenanceExpected $Pending.path $Pending.sha256
}
function Get-MaintenanceReason([string]$Message) {
    if ($Message -match 'Managed file modified or deleted: (.+)') { return "配置包文件已修改或缺失：$($Matches[1])。请先保存并处理这些改动，再重新检查；安装器不会覆盖或合并。" }
    if ($Message -match 'Unknown file occupies a new runtime path: (.+)') { return "新文件位置已被其他内容占用：$($Matches[1])。请先自行保存并处理，安装器不会覆盖。" }
    if ($Message -match '[\u4e00-\u9fff]') { return $Message }
    if ($Message -match 'removed or renamed') { return '新版配置包移除或重命名了部分已安装文件，当前暂不支持这类更新。请保留现有配置与备份。' }
    if ($Message -match 'receipt|Receipt|backup|Backup') { return '安装记录或备份未通过完整性检查。请保留配置目录和原备份，再核对安装来源。' }
    if ($Message -match 'Reparse|reparse|directory|Directory|path|Path') { return '配置目录、配置包或备份路径不符合安全要求，请检查是否存在链接、占用或目录重叠。' }
    if ($Message -match 'checksum|manifest|package') { return '配置包未通过完整性检查，请重新获取完整配置包后再试。' }
    return '无法完成检查。请保留现有配置，并核对播放器、配置包及备份目录是否可访问。'
}
function Test-MaintenanceClean($Context, $Package, [string]$PlayerPath, [string]$ConfigDirectory) {
    if (-not $ConfigDirectory) {
        # Preserve the existing automatic clean-install policy and directory selection unchanged.
        try {
            $original = Get-CleanInstallPlan -PlayerPath $PlayerPath -PackageRoot $Package.root
            $original | Add-Member -NotePropertyName reusableRuntimeDirectories -NotePropertyValue (New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase))
            return $original
        } catch { }
    }
    $paths = @{}; $directories = @{}
    foreach ($file in $Package.runtime) {
        $paths[$file.path] = $true
        $parent = [IO.Path]::GetDirectoryName((Get-KitPath $Context.target $file.path))
        while ($parent -and $parent -ine $Context.target) { $directories[$parent.Substring($Context.target.Length + 1).Replace('\', '/')] = $true; $parent = [IO.Path]::GetDirectoryName($parent) }
    }
    foreach ($relative in $directories.Keys) { if ($paths.ContainsKey($relative)) { throw '配置包的文件与子目录发生冲突。' } }
    # A recovered first installation may leave empty nested runtime ancestors. Reuse only
    # paths proved by this verified payload; the original checker still rejects every file
    # and every unknown directory in those trees. Never remove directories during recovery.
    $reusable = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($relative in $directories.Keys) {
        $path = Get-KitPath $Context.target $relative
        if ([IO.Directory]::Exists($path)) { [void]$reusable.Add($path) }
    }
    $baseline = & $script:MaintenanceClean { param($Target, $Paths, $Directories, $Reusable) Get-CleanTargetState $Target $Paths $Directories @{} $Reusable } $Context.target $paths $directories $reusable
    return [pscustomobject]@{ baseline = $baseline; runtimePaths = $paths; runtimeDirectories = $directories; reusableRuntimeDirectories = $reusable; warnings = @() }
}
function Get-MaintenanceRestoreData($Receipt, [string]$Target) {
    $loaded = $Receipt.record; $record = $loaded.value
    foreach ($file in $record.files) { Assert-MaintenanceRuntimePath $file.path; Assert-MaintenanceExpected (Get-KitPath $Target $file.path) $file.newSha256 }
    # Existing restore validates receipt history and backup contents without writing.
    [void](Invoke-KitRestore -BackupManifest $loaded.manifest)
    $previousBytes = $null; $previousVersion = $null
    if ($record.previousReceipt.exists) {
        $previousBytes = [IO.File]::ReadAllBytes((Get-KitPath $loaded.directory 'previous-receipt.json'))
        $previous = $script:MaintenanceUtf8.GetString($previousBytes) | ConvertFrom-Json
        $previousVersion = $previous.packageVersion
    }
    $kind = if (-not $record.previousReceipt.exists -and -not @($record.files | Where-Object oldExists).Count) { 'remove-install' } else { 'restore-version' }
    return [pscustomobject]@{ loaded = $loaded; previousBytes = $previousBytes; previousVersion = $previousVersion; kind = $kind;
        files = @($record.files | ForEach-Object { [ordered]@{ path = $_.path; change = $(if (-not $_.changed) { 'unchanged' } elseif ($_.oldExists) { 'restore' } else { 'remove' }) } }) }
}
function Get-MaintenanceState {
    param([string]$PlayerPath, [string]$ConfigDirectory = '', [string]$BackupRoot = '', [string]$PackageRoot = '')
    if (-not $PackageRoot) { $PackageRoot = Split-Path -Parent $PSScriptRoot }
    $view = [ordered]@{ mode = 'preview'; target = ''; targetSource = ''; targetSourceLabel = ''; targetExists = $false; packageVersion = $null; installedVersion = $null;
        action = 'blocked'; eligible = $false; reason = ''; files = @(); changedFiles = 0; addedFiles = 0; backupRoot = ''; planToken = '';
        canRestore = $false; restorePlanToken = ''; restoreManifest = $null; restoreFiles = @(); restoreChangedFiles = 0; restorePreviousVersion = $null;
        restoreKind = $null; runningProcesses = @(); warnings = @(); releaseNotice = '' }
    $state = [pscustomobject]@{ view = $view; context = $null; package = $null; packageContext = $null; backupContext = $null;
        install = $null; legacy = $null; clean = $null; pending = $null; restore = $null; restoreError = ''; processError = ''; kind = '' }
    try {
        $context = Get-KitTargetContext -PlayerPath $PlayerPath -ConfigDirectory $ConfigDirectory; $state.context = $context
        if ([IO.Path]::GetFileName($PlayerPath) -ine 'mpvnet.exe') { throw '请选择名为 mpvnet.exe 的 mpv.net 播放器程序。' }
        $view.target = $context.target; $view.targetSource = $context.source; $view.targetSourceLabel = $context.sourceLabel; $view.targetExists = $context.targetExists
        if (-not $BackupRoot) { $BackupRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'mpvnet-kit/backups' }
        $backup = Get-KitRoot $BackupRoot; $view.backupRoot = $backup
        $state.backupContext = Get-MaintenanceDirectoryContext $backup
        $package = Get-KitPackage $PackageRoot; $state.package = $package; $view.packageVersion = $package.version
        $view.releaseNotice = $package.releaseNotice
        $state.packageContext = Get-MaintenanceDirectoryContext $package.root
        & $script:MaintenanceCommon { param($Roots) Assert-KitSeparate $Roots } @($context.target, $package.root, $backup)
        if ((Get-KitPlayer $PlayerPath).StartsWith($context.target.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw '配置目录不能包含播放器程序。' }
        if ($context.source -eq 'environment') { $view.warnings += '目录按当前进程的 MPVNET_HOME 判断；启动播放器时须使用相同环境。' }
        try { $view.runningProcesses = @(Get-MaintenanceRunningPlayers) }
        catch { $state.processError = '无法检查 mpv.net 运行状态。为避免写入正在使用的配置，本次操作已停止。' }
        $pending = Read-MaintenancePending $context.target $backup; $state.pending = $pending
        if ($pending) {
            $state.kind = 'recover'; $view.action = 'recover'
            Assert-MaintenanceRecoverable $pending $context.target
            $view.files = @($pending.journal.files | ForEach-Object { [ordered]@{ path = $_.path; change = $(if ($_.beforeSha256 -ceq $_.afterSha256) { 'unchanged' } elseif (-not $_.beforeExists) { 'added' } else { 'modified' }) } })
            $view.reason = '检测到尚未完成的操作。请先恢复到该操作开始前的配置，原备份将保留。'; $view.eligible = $true
        } else {
            $receiptPath = Get-KitPath $context.target $script:MaintenanceReceiptName
            if ([IO.File]::Exists($receiptPath) -or [IO.Directory]::Exists($receiptPath)) { $state.kind = 'managed' }
            else {
                $cleanFailure = ''
                try { $state.clean = Test-MaintenanceClean $context $package $PlayerPath $ConfigDirectory; $state.kind = 'clean'; $view.warnings += @($state.clean.warnings) }
                catch { $cleanFailure = $_.Exception.Message }
                if (-not $state.clean) {
                    try { $state.legacy = Get-KitLegacyPlan -PlayerPath $PlayerPath -ConfigDirectory $ConfigDirectory -BackupRoot $backup -PackageRoot $package.root }
                    catch { throw $cleanFailure }
                    if (-not $state.legacy.view.eligible) {
                        $conflicts = @($state.legacy.view.conflicts | ForEach-Object { $_.path } | Where-Object { $_ })
                        if ($conflicts.Count) { throw ('旧配置存在冲突：' + ($conflicts -join '、') + '。请先保存并处理这些内容，安装器不会覆盖或合并。') }
                        $closest = @($state.legacy.view.candidates | Sort-Object matchedFiles -Descending | Select-Object -First 1)
                        if ($closest.Count -and $closest[0].matchedFiles -gt 0) {
                            $different = @($closest[0].differences | Select-Object -First 5 | ForEach-Object { $_.path })
                            throw ('旧配置未完整匹配已知发行版，存在修改、缺失或混用的文件：' + ($different -join '、') + '。请先自行保存并处理，安装器不会覆盖或合并。')
                        }
                        if ($cleanFailure -match '[\u4e00-\u9fff]') { throw $cleanFailure }
                        throw '现有配置未完整匹配已知发行版，可能已修改、缺失、混用或来源不明。请先自行保存和处理，安装器不会接管或合并。'
                    }
                    $state.kind = 'legacy'; $view.installedVersion = $state.legacy.matchedRelease.version
                    $view.warnings += '更新前会完整备份已识别的旧配置；个人配置和未知文件不纳入备份或覆盖。'
                }
            }
            $install = Get-KitInstallPlan -PlayerPath $PlayerPath -ConfigDirectory $ConfigDirectory -BackupRoot $backup -PackageRoot $package.root; $state.install = $install
            foreach ($file in $install.files) { Assert-MaintenanceRuntimePath $file.path }
            $view.files = @($install.files | ForEach-Object { [ordered]@{ path = $_.path; change = $(if (-not $_.oldExists) { 'added' } elseif ($_.changed) { 'modified' } else { 'unchanged' }) } })
            if ($state.kind -eq 'managed') {
                $view.installedVersion = $install.receipt.value.packageVersion
                try {
                    $state.restore = Get-MaintenanceRestoreData $install.receipt $context.target
                    $view.restoreManifest = $install.receipt.record.manifest; $view.restoreFiles = $state.restore.files
                    $view.restoreChangedFiles = @($install.receipt.record.value.files | Where-Object changed).Count
                    $view.restoreKind = $state.restore.kind; $view.restorePreviousVersion = $state.restore.previousVersion; $view.canRestore = $true
                } catch { $state.restoreError = Get-MaintenanceReason $_.Exception.Message; $view.warnings += ('无法还原上一步：' + $state.restoreError) }
            }
            if ($state.kind -eq 'managed' -and -not @($install.files | Where-Object changed).Count) { $view.action = 'current'; $view.reason = '当前配置与此配置包一致，无需更新。'; $view.eligible = $false }
            elseif ($state.kind -eq 'clean') { $view.action = 'install'; $view.reason = '配置目录符合首次安装要求，可以开始安装。'; $view.eligible = $true }
            else { $view.action = 'update'; $view.reason = '配置检查通过，更新前将备份本次会修改的文件。'; $view.eligible = $true }
        }
        $view.changedFiles = @($view.files | Where-Object { $_.change -ne 'unchanged' }).Count
        $view.addedFiles = @($view.files | Where-Object { $_.change -eq 'added' }).Count
        if ((Get-KitTargetContext -PlayerPath $PlayerPath -ConfigDirectory $ConfigDirectory).contextToken -cne $context.contextToken) { throw '检查过程中配置目录发生变化，请重新检查。' }
        $parts = @('maintenance-v1', (Get-KitPlayer $PlayerPath).ToLowerInvariant(), $context.contextToken,
            $backup.ToLowerInvariant(), [int]$state.backupContext.targetExists, $state.backupContext.targetIdentity,
            $state.backupContext.nearestExistingParent.ToLowerInvariant(), $state.backupContext.nearestExistingParentIdentity, $state.kind)
        if ($package) { $parts += @($package.root.ToLowerInvariant(), $package.manifestSha256, $state.packageContext.targetIdentity) }
        if ($state.install) { $parts += $state.install.planToken }
        if ($state.legacy) { $parts += $state.legacy.planToken }
        if ($pending) {
            $parts += @($pending.sha256, $pending.value.journalSha256)
            foreach ($file in $pending.journal.files) { $parts += @( $file.path, (Get-MaintenanceActualHash (Get-KitPath $context.target $file.path)) ) }
            $parts += Get-MaintenanceActualHash (Get-KitPath $context.target $script:MaintenanceReceiptName)
        }
        if ($state.clean) { foreach ($key in @($state.clean.baseline.entries.Keys | Sort-Object -CaseSensitive)) { $parts += @($key, $state.clean.baseline.entries[$key]) } }
        $view.planToken = 'mpvnet-kit-maintenance-v1:' + (Get-MaintenanceHashParts $parts)
        if ($view.canRestore) { $view.restorePlanToken = 'mpvnet-kit-restore-v1:' + (Get-MaintenanceHashParts @($view.planToken, $state.install.receipt.sha256,
            (Get-KitHash $state.install.receipt.record.manifest), $state.install.receipt.record.value.previousReceipt.sha256)) }
        if ($state.processError -or $view.runningProcesses.Count) {
            $view.eligible = $false; $view.canRestore = $false
            if (-not $state.pending) { $view.action = 'blocked' }
            $view.reason = if ($state.processError) { $state.processError } else { '请先退出所有 mpv.net 播放器，再重新检查。安装器不会关闭播放器。' }
        }
    } catch {
        $view.action = if ($state.pending) { 'recover' } else { 'blocked' }; $view.eligible = $false; $view.canRestore = $false
        $view.reason = Get-MaintenanceReason $_.Exception.Message; $view.planToken = ''; $view.restorePlanToken = ''
    }
    return $state
}
function Get-KitMaintenancePlan {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$PlayerPath, [string]$ConfigDirectory = '', [string]$BackupRoot = '', [string]$PackageRoot = '')
    return (Get-MaintenanceState $PlayerPath $ConfigDirectory $BackupRoot $PackageRoot).view
}
function Assert-MaintenanceContext($State, [string]$PlayerPath, [string]$ConfigDirectory) {
    if ((Get-KitTargetContext -PlayerPath $PlayerPath -ConfigDirectory $ConfigDirectory).contextToken -cne $State.context.contextToken) { throw '配置目录来源或身份已变化，请重新检查。' }
    Assert-MaintenancePlayersStopped
}
function Add-MaintenancePlanLocks($State, $Locks) {
    foreach ($root in @($State.context.target, $State.view.backupRoot)) { Add-KitExistingDirectoryLocks $root $Locks }
    if ($State.package) {
        Add-KitExistingDirectoryLocks $State.package.root $Locks
        foreach ($file in $State.package.runtime) { Add-KitExistingDirectoryLocks ([IO.Path]::GetDirectoryName((Get-KitPath $State.package.root ('config/' + $file.path)))) $Locks }
    }
    if ($State.install) {
        foreach ($file in $State.install.files) { Add-KitExistingDirectoryLocks ([IO.Path]::GetDirectoryName($file.target)) $Locks }
        if ($State.install.receipt) { Add-KitExistingDirectoryLocks $State.install.receipt.record.directory $Locks }
    }
    if ($State.pending) {
        Add-KitExistingDirectoryLocks $State.pending.directory $Locks
        foreach ($file in $State.pending.journal.files) {
            Add-KitExistingDirectoryLocks ([IO.Path]::GetDirectoryName((Get-KitPath $State.context.target $file.path))) $Locks
            if ($file.backup) { Add-KitExistingDirectoryLocks ([IO.Path]::GetDirectoryName((Get-KitPath $State.pending.directory $file.backup))) $Locks }
        }
        Add-KitExistingDirectoryLocks $State.pending.sourceRecord.directory $Locks
        foreach ($file in $State.pending.sourceRecord.value.files) {
            if ($file.backup) { Add-KitExistingDirectoryLocks ([IO.Path]::GetDirectoryName((Get-KitPath $State.pending.sourceRecord.directory $file.backup))) $Locks }
        }
    }
}
function New-MaintenanceJournal($State, [string]$Id, [string]$Directory, [string]$Operation, [object[]]$Files, $Receipt, $Locks) {
    $journal = [ordered]@{ schema = 1; owner = 'mpvnet-kit'; kind = 'maintenance-operation'; id = $Id; target = $State.context.target;
        backupRoot = $State.view.backupRoot; operation = $Operation; files = $Files; receipt = $Receipt }
    $journalBytes = Get-MaintenanceBytes $journal
    Write-MaintenanceFile (Get-KitPath $Directory 'operation.json') $journalBytes $null
    $marker = [ordered]@{ schema = 1; owner = 'mpvnet-kit'; kind = 'pending-operation'; id = $Id; target = $State.context.target;
        backupRoot = $State.view.backupRoot; journalSha256 = Get-MaintenanceHashBytes $journalBytes }
    # All rollback bytes and the immutable journal exist before the first runtime/receipt write.
    New-MaintenanceDirectory $State.context.target $Locks
    $markerPath = Get-KitPath $State.context.target $script:MaintenancePendingName
    Write-MaintenanceFile $markerPath (Get-MaintenanceBytes $marker) $null
    return Read-MaintenancePending $State.context.target $State.view.backupRoot
}
function Invoke-MaintenanceRecovery($Pending, [string]$Target, $Locks) {
    Assert-MaintenancePlayersStopped
    Assert-MaintenanceRecoverable $Pending $Target
    # Validate the entire state first: third-party changes cause zero recovery writes.
    $files = @($Pending.journal.files); [array]::Reverse($files)
    foreach ($file in $files) {
        Assert-MaintenancePlayersStopped
        $path = Get-KitPath $Target $file.path; $actual = Get-MaintenanceActualHash $path
        if ($actual -ceq $file.beforeSha256) { continue }
        if ($actual -cne $file.afterSha256) { throw "恢复过程中出现其他改动：$($file.path)。现场已保留。" }
        if ($file.beforeExists) {
            New-MaintenanceDirectory ([IO.Path]::GetDirectoryName($path)) $Locks
            $bytes = [IO.File]::ReadAllBytes((Get-KitPath $Pending.directory $file.backup))
            if ((Get-MaintenanceHashBytes $bytes) -cne $file.beforeSha256) { throw '操作前备份在恢复过程中发生变化。' }
            Write-MaintenanceTargetFile $path $bytes $actual
        } else { Remove-MaintenanceFile $path $actual }
    }
    Assert-MaintenancePlayersStopped
    $receipt = $Pending.journal.receipt; $receiptPath = Get-KitPath $Target $script:MaintenanceReceiptName; $actual = Get-MaintenanceActualHash $receiptPath
    if ($actual -cne $receipt.beforeSha256) {
        if ($actual -cne $receipt.afterSha256) { throw '安装记录在恢复过程中发生了其他变化。' }
        if ($receipt.beforeExists) {
            $bytes = [IO.File]::ReadAllBytes((Get-KitPath $Pending.directory $receipt.backup))
            if ((Get-MaintenanceHashBytes $bytes) -cne $receipt.beforeSha256) { throw '操作前安装记录的备份在恢复过程中发生变化。' }
            Write-MaintenanceTargetFile $receiptPath $bytes $actual
        } else { Remove-MaintenanceFile $receiptPath $actual }
    }
    foreach ($file in $Pending.journal.files) { Assert-MaintenanceExpected (Get-KitPath $Target $file.path) $file.beforeSha256 }
    Assert-MaintenanceExpected $receiptPath $receipt.beforeSha256
    Remove-MaintenanceFile $Pending.path $Pending.sha256
}
function Invoke-MaintenanceApply($State, [string]$PlayerPath, [string]$ConfigDirectory, $Locks) {
    $plan = $State.install; $legacyManifest = $null; $pending = $null
    Assert-MaintenanceContext $State $PlayerPath $ConfigDirectory
    if ($State.legacy) {
        $snapshot = Invoke-KitLegacyBackup -PlayerPath $PlayerPath -ConfigDirectory $ConfigDirectory -BackupRoot $State.view.backupRoot -PackageRoot $State.package.root -Apply -ExpectedPlanToken $State.legacy.planToken
        $legacyManifest = $snapshot.backupManifest
        Assert-MaintenanceContext $State $PlayerPath $ConfigDirectory
        Add-KitExistingDirectoryLocks $State.view.backupRoot $Locks
    }
    $id = [Guid]::NewGuid().ToString('N'); $directory = Get-KitPath $State.view.backupRoot $id
    New-MaintenanceDirectory $directory $Locks
    $recordFiles = @(); $journalFiles = @()
    foreach ($file in $plan.files) {
        Assert-MaintenanceExpected $file.target $file.oldSha256
        $backup = if ($file.oldExists -and $file.changed) { 'files/' + $file.path } else { $null }
        if ($backup) {
            $saved = Get-KitPath $directory $backup; New-MaintenanceDirectory ([IO.Path]::GetDirectoryName($saved)) $Locks
            $bytes = [IO.File]::ReadAllBytes($file.target)
            if ((Get-MaintenanceHashBytes $bytes) -cne $file.oldSha256) { throw '配置文件在备份过程中发生变化，请重新检查。' }
            Write-MaintenanceFile $saved $bytes $null
        }
        $recordFiles += [ordered]@{ path = $file.path; oldExists = $file.oldExists; oldSha256 = $file.oldSha256; newSha256 = $file.newSha256; changed = $file.changed; backup = $backup }
        $journalFiles += [ordered]@{ path = $file.path; beforeExists = $file.oldExists; beforeSha256 = $file.oldSha256; afterExists = $true; afterSha256 = $file.newSha256; backup = $backup }
    }
    $oldReceiptSha = if ($plan.receipt) { $plan.receipt.sha256 } else { $null }
    $receiptPath = Get-KitPath $plan.target $script:MaintenanceReceiptName
    Assert-MaintenanceExpected $receiptPath $oldReceiptSha
    if ($plan.receipt) { Write-MaintenanceFile (Get-KitPath $directory 'previous-receipt.json') $plan.receipt.bytes $null }
    # Keep the original schema1 record and receipt byte layout for restore.ps1 compatibility.
    $record = [ordered]@{ schema = 1; owner = 'mpvnet-kit'; kind = 'backup'; id = $id; target = $plan.target; packageVersion = $plan.package.version;
        packageManifestSha256 = $plan.package.manifestSha256; createdUtc = [DateTime]::UtcNow.ToString('o'); files = $recordFiles;
        previousReceipt = [ordered]@{ exists = [bool]$plan.receipt; sha256 = $oldReceiptSha; backup = $(if ($plan.receipt) { 'previous-receipt.json' } else { $null }) } }
    $dataSha = Get-MaintenanceHashBytes (Get-MaintenanceBytes $record)
    $receipt = [ordered]@{ schema = 1; owner = 'mpvnet-kit'; kind = 'receipt'; id = $id; target = $plan.target; packageVersion = $plan.package.version;
        packageManifestSha256 = $plan.package.manifestSha256; backupDirectory = $directory; backupDataSha256 = $dataSha;
        files = @($plan.files | ForEach-Object { [ordered]@{ path = $_.path; sha256 = $_.newSha256 } }) }
    $receiptBytes = Get-MaintenanceBytes $receipt; $receiptSha = Get-MaintenanceHashBytes $receiptBytes
    $record['dataSha256'] = $dataSha; $record['receiptSha256'] = $receiptSha
    Write-MaintenanceFile (Get-KitPath $directory 'manifest.json') (Get-MaintenanceBytes $record) $null
    Write-MaintenanceFile (Get-KitPath $directory 'installed-receipt.json') $receiptBytes $null
    [void](& $script:MaintenanceCommon { param($Value) Read-KitRecord $Value } (Get-KitPath $directory 'manifest.json'))
    $statusSha = & $script:MaintenanceCommon { param($Value) Save-KitStatus $Value 'prepared' 'Backup complete; target writes have not started.' $null } $directory
    Assert-MaintenanceContext $State $PlayerPath $ConfigDirectory
    foreach ($file in $plan.files) { Assert-MaintenanceExpected $file.target $file.oldSha256 }
    Assert-MaintenanceExpected $receiptPath $oldReceiptSha
    if ($State.clean) { [void](Test-MaintenanceClean $State.context $State.package $PlayerPath $ConfigDirectory) }
    $journalReceipt = [ordered]@{ beforeExists = [bool]$plan.receipt; beforeSha256 = $oldReceiptSha; afterExists = $true; afterSha256 = $receiptSha;
        backup = $(if ($plan.receipt) { 'previous-receipt.json' } else { $null }) }
    try {
        $pending = New-MaintenanceJournal $State $id $directory 'Apply' $journalFiles $journalReceipt $Locks
        $ownedFiles = @{}; $ownedFiles[$pending.path] = $pending.sha256
        $ownedDirectories = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        if ($State.clean) { foreach ($path in $State.clean.reusableRuntimeDirectories) { [void]$ownedDirectories.Add($path) } }
        foreach ($file in $plan.files) {
            $parent = [IO.Path]::GetDirectoryName($file.target)
            if (-not [IO.Directory]::Exists($parent)) {
                $cursor = $parent
                while ($cursor -and $cursor -ine $plan.target -and -not [IO.Directory]::Exists($cursor)) { [void]$ownedDirectories.Add($cursor); $cursor = [IO.Path]::GetDirectoryName($cursor) }
            }
            New-MaintenanceDirectory $parent $Locks
        }
        foreach ($file in $plan.files) {
            Assert-MaintenancePlayersStopped
            if ($State.clean) {
                [void](& $script:MaintenanceClean { param($Target, $Paths, $Directories, $Owned, $OwnedDirs, $Baseline) Get-CleanTargetState $Target $Paths $Directories $Owned $OwnedDirs $Baseline } $plan.target $State.clean.runtimePaths $State.clean.runtimeDirectories $ownedFiles $ownedDirectories $State.clean.baseline.entries)
            }
            if ($file.changed) { Write-MaintenanceTargetFile $file.target $file.newBytes $file.oldSha256; $ownedFiles[$file.target] = $file.newSha256 }
        }
        Assert-MaintenancePlayersStopped
        foreach ($file in $plan.files) { Assert-MaintenanceExpected $file.target $file.newSha256 }
        Write-MaintenanceTargetFile $receiptPath $receiptBytes $oldReceiptSha
        [void](& $script:MaintenanceCommon { param($Value) Get-KitReceipt $Value } $plan.target)
        [void](& $script:MaintenanceCommon { param($Value, $Expected) Save-KitStatus $Value 'installed' 'Installation completed; backup retained.' $Expected } $directory $statusSha)
        Remove-MaintenanceFile $pending.path $pending.sha256
        $result = [ordered]@{ mode = 'applied'; action = $State.view.action; target = $plan.target; changedFiles = $State.view.changedFiles; backupManifest = Get-KitPath $directory 'manifest.json' }
        if ($legacyManifest) { $result['legacySnapshotManifest'] = $legacyManifest }
        return $result
    } catch {
        $failure = $_.Exception.Message
        if ($pending -or [IO.File]::Exists((Get-KitPath $plan.target $script:MaintenancePendingName))) {
            try { $pending = Read-MaintenancePending $plan.target $State.view.backupRoot; Invoke-MaintenanceRecovery $pending $plan.target $Locks }
            catch { throw "操作未完成，自动恢复也未完成。请保留现场和备份，退出播放器后重新检查。备份位置：$directory。$failure $($_.Exception.Message)" }
        }
        throw "操作未完成，已恢复到操作前的配置，备份保留在：$directory。$failure"
    }
}
function Invoke-MaintenanceRestore($State, [string]$PlayerPath, [string]$ConfigDirectory, $Locks) {
    Assert-MaintenanceContext $State $PlayerPath $ConfigDirectory
    $loaded = $State.restore.loaded; $record = $loaded.value; $active = $State.install.receipt
    $id = [Guid]::NewGuid().ToString('N'); $directory = Get-KitPath $State.view.backupRoot $id; $pending = $null
    New-MaintenanceDirectory $directory $Locks
    # Freeze the already verified schema1 source record and its real backup bytes locally.
    # Recovery never follows the backupDirectory pointer contained in a journal's receipt bytes.
    $source = Get-KitPath $directory 'source'; New-MaintenanceDirectory $source $Locks
    foreach ($file in $record.files) {
        if ($file.oldExists -and $file.changed) {
            $savedPath = Get-KitPath $source $file.backup; New-MaintenanceDirectory ([IO.Path]::GetDirectoryName($savedPath)) $Locks
            $bytes = [IO.File]::ReadAllBytes((Get-KitPath $loaded.directory $file.backup))
            if ((Get-MaintenanceHashBytes $bytes) -cne $file.oldSha256) { throw '原备份在准备还原时发生变化。' }
            Write-MaintenanceFile $savedPath $bytes $null
        }
    }
    if ($record.previousReceipt.exists) {
        if ((Get-MaintenanceHashBytes $State.restore.previousBytes) -cne $record.previousReceipt.sha256) { throw '原安装记录的备份已变化。' }
        Write-MaintenanceFile (Get-KitPath $source 'previous-receipt.json') $State.restore.previousBytes $null
    }
    $sourceManifestBytes = [IO.File]::ReadAllBytes($loaded.manifest)
    $reloaded = & $script:MaintenanceCommon { param($Value) Read-KitRecord $Value } $loaded.manifest
    if ($reloaded.value.dataSha256 -cne $record.dataSha256 -or $reloaded.value.receiptSha256 -cne $record.receiptSha256) { throw '原备份清单在准备还原时发生变化。' }
    Write-MaintenanceFile (Get-KitPath $source 'manifest.json') $sourceManifestBytes $null
    $journalFiles = @(); $writes = @()
    foreach ($file in $record.files) {
        $path = Get-KitPath $State.context.target $file.path; Assert-MaintenanceExpected $path $file.newSha256
        $afterSha = if ($file.oldExists) { $file.oldSha256 } else { $null }
        $backup = if ($file.changed) { 'recovery/' + $file.path } else { $null }
        if ($backup) {
            $saved = Get-KitPath $directory $backup; New-MaintenanceDirectory ([IO.Path]::GetDirectoryName($saved)) $Locks
            $beforeBytes = [IO.File]::ReadAllBytes($path)
            if ((Get-MaintenanceHashBytes $beforeBytes) -cne $file.newSha256) { throw '配置文件在备份过程中发生变化。' }
            Write-MaintenanceFile $saved $beforeBytes $null
        }
        $afterBytes = $null
        if ($file.changed -and $file.oldExists) {
            $afterBytes = [IO.File]::ReadAllBytes((Get-KitPath $loaded.directory $file.backup))
            if ((Get-MaintenanceHashBytes $afterBytes) -cne $file.oldSha256) { throw '旧配置备份在准备还原时发生变化。' }
        }
        $writes += [pscustomobject]@{ path = $path; changed = $file.changed; exists = $file.oldExists; bytes = $afterBytes; beforeSha256 = $file.newSha256; afterSha256 = $afterSha }
        $journalFiles += [ordered]@{ path = $file.path; beforeExists = $true; beforeSha256 = $file.newSha256; afterExists = $file.oldExists; afterSha256 = $afterSha; backup = $backup }
    }
    Write-MaintenanceFile (Get-KitPath $directory 'receipt-before.json') $active.bytes $null
    $journalReceipt = [ordered]@{ beforeExists = $true; beforeSha256 = $active.sha256; afterExists = $record.previousReceipt.exists;
        afterSha256 = $(if ($record.previousReceipt.exists) { $record.previousReceipt.sha256 } else { $null }); backup = 'receipt-before.json' }
    Assert-MaintenanceContext $State $PlayerPath $ConfigDirectory
    foreach ($write in $writes) { Assert-MaintenanceExpected $write.path $write.beforeSha256 }
    Assert-MaintenanceExpected $active.path $active.sha256
    try {
        $pending = New-MaintenanceJournal $State $id $directory 'Restore' $journalFiles $journalReceipt $Locks
        foreach ($write in $writes) {
            Assert-MaintenancePlayersStopped
            if (-not $write.changed) { continue }
            if ($write.exists) { Write-MaintenanceTargetFile $write.path $write.bytes $write.beforeSha256 }
            else { Remove-MaintenanceFile $write.path $write.beforeSha256 }
        }
        Assert-MaintenancePlayersStopped
        if ($record.previousReceipt.exists) { Write-MaintenanceTargetFile $active.path $State.restore.previousBytes $active.sha256 }
        else { Remove-MaintenanceFile $active.path $active.sha256 }
        foreach ($write in $writes) { Assert-MaintenanceExpected $write.path $write.afterSha256 }
        Assert-MaintenanceExpected $active.path $journalReceipt.afterSha256
        if ($record.previousReceipt.exists) { [void](& $script:MaintenanceCommon { param($Value) Get-KitReceipt $Value } $State.context.target) }
        Remove-MaintenanceFile $pending.path $pending.sha256
        return [ordered]@{ mode = 'applied'; action = 'restore'; target = $State.context.target; changedFiles = $State.view.restoreChangedFiles; backupManifest = $loaded.manifest }
    } catch {
        $failure = $_.Exception.Message
        try { $pending = Read-MaintenancePending $State.context.target $State.view.backupRoot; if ($pending) { Invoke-MaintenanceRecovery $pending $State.context.target $Locks } }
        catch { throw "还原未完成，自动恢复也未完成。请保留现场和备份，退出播放器后重新检查。备份位置：$directory。$failure $($_.Exception.Message)" }
        throw "还原未完成，已恢复到还原开始前的配置。备份保留在：$directory。$failure"
    }
}
function Invoke-KitMaintenance {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$PlayerPath, [string]$ConfigDirectory = '', [string]$BackupRoot = '', [string]$PackageRoot = '',
        [ValidateSet('Apply', 'Restore', 'Recover')][string]$Operation = 'Apply', [Parameter(Mandatory=$true)][string]$ExpectedPlanToken)
    if (-not $ExpectedPlanToken) { throw '执行前必须先检查并确认本次计划。' }
    $state = Get-MaintenanceState $PlayerPath $ConfigDirectory $BackupRoot $PackageRoot
    $token = if ($Operation -eq 'Restore') { $state.view.restorePlanToken } else { $state.view.planToken }
    if ($token -cne $ExpectedPlanToken) { throw '配置或操作计划已变化，请重新检查并确认。' }
    if ($Operation -eq 'Restore') { if (-not $state.view.canRestore) { throw ('无法还原上一步。' + $state.view.reason) } }
    elseif (-not $state.view.eligible) { throw $state.view.reason }
    if (($Operation -eq 'Recover') -ne [bool]$state.pending) { throw '当前状态与所选操作不一致，请重新检查。' }
    $locks = @{}; $mutex = $null; $ownsMutex = $false
    try {
        $name = 'Local\mpvnet-kit-maintenance-' + (Get-MaintenanceHashParts @($state.context.target.ToLowerInvariant()))
        $mutex = New-Object Threading.Mutex($false, $name)
        try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
        if (-not $ownsMutex) { throw '另一个安装器正在维护此配置目录，请待其结束后重新检查。' }
        Add-MaintenancePlanLocks $state $locks
        $current = Get-MaintenanceState $PlayerPath $ConfigDirectory $BackupRoot $PackageRoot
        $currentToken = if ($Operation -eq 'Restore') { $current.view.restorePlanToken } else { $current.view.planToken }
        if ($currentToken -cne $ExpectedPlanToken) { throw '取得目录保护后，配置或操作计划已变化，请重新检查。' }
        if ($Operation -eq 'Restore') {
            if (-not $current.view.canRestore) { throw ('无法还原上一步。' + $current.view.reason) }
        } elseif (-not $current.view.eligible) { throw $current.view.reason }
        $state = $current
        Assert-MaintenanceContext $state $PlayerPath $ConfigDirectory
        if ($Operation -eq 'Recover') {
            Invoke-MaintenanceRecovery $state.pending $state.context.target $locks
            return [ordered]@{ mode = 'applied'; action = 'recover'; target = $state.context.target; changedFiles = $state.view.changedFiles; backupManifest = $state.pending.journalPath }
        }
        if ($Operation -eq 'Restore') { return Invoke-MaintenanceRestore $state $PlayerPath $ConfigDirectory $locks }
        return Invoke-MaintenanceApply $state $PlayerPath $ConfigDirectory $locks
    } finally {
        foreach ($handle in $locks.Values) { $handle.Dispose() }
        if ($ownsMutex) { $mutex.ReleaseMutex() }
        if ($mutex) { $mutex.Dispose() }
    }
}
function Write-KitMaintenanceResult($Value, [ValidateSet('Json', 'Text')][string]$OutputFormat = 'Json', [switch]$Details) {
    [Console]::OutputEncoding = $script:MaintenanceUtf8
    if ($OutputFormat -eq 'Json') { [Console]::WriteLine(($Value | ConvertTo-Json -Depth 24)); return }
    $data = @{}; if ($Value -is [Collections.IDictionary]) { foreach ($key in $Value.Keys) { $data[$key] = $Value[$key] } } else { foreach ($property in $Value.PSObject.Properties) { $data[$property.Name] = $property.Value } }
    if ($data['error']) { [Console]::WriteLine('操作未完成：' + [string]$data['error']); return }
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $labels = @{ install = '首次安装'; update = '更新配置'; current = '无需更新'; blocked = '暂时无法继续'; recover = '恢复未完成的操作'; restore = '还原上一步配置' }
    $lines.Add([string]$labels[$data['action']] + $(if ($data['mode'] -eq 'applied') { ' · 已完成' } else { ' · 检查结果' }))
    $lines.Add('配置目录：' + [string]$data['target'])
    foreach ($pair in @(@('targetSourceLabel', '识别来源'), @('packageVersion', '配置包版本'), @('installedVersion', '当前版本'), @('reason', '说明'), @('backupRoot', '备份目录'), @('backupManifest', '备份清单'))) {
        if ($data[$pair[0]]) { $lines.Add($pair[1] + '：' + [string]$data[$pair[0]]) }
    }
    if ($data.ContainsKey('changedFiles')) { $lines.Add('变更文件：' + [string]$data['changedFiles']) }
    if ($data['mode'] -eq 'preview' -and $data['action'] -in @('install','update') -and $data['releaseNotice']) { $lines.Add(''); $lines.Add([string]$data['releaseNotice']); $lines.Add('') }
    foreach ($warning in $data['warnings']) { $lines.Add('提示：' + $warning) }
    foreach ($player in $data['runningProcesses']) { $lines.Add('仍在运行：' + $player.name + '（PID ' + $player.pid + '）') }
    if ($data['planToken']) { $lines.Add('操作校验值：' + $data['planToken']) }
    if ($data['canRestore']) { $lines.Add('可还原上一步：是'); $lines.Add('还原校验值：' + $data['restorePlanToken']) }
    if ($Details) {
        foreach ($file in $data['files']) { $lines.Add('  [' + $file.change + '] ' + $file.path) }
        if ($data['restoreFiles']) { $lines.Add('还原文件：'); foreach ($file in $data['restoreFiles']) { $lines.Add('  [' + $file.change + '] ' + $file.path) } }
    }
    [Console]::WriteLine(($lines -join "`r`n"))
}

Export-ModuleMember -Function Get-KitMaintenancePlan,Invoke-KitMaintenance,Write-KitMaintenanceResult
