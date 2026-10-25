Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
# Do not force-reload common: another installer module may still use its exports.
$script:LegacyCommon = Import-Module (Join-Path $PSScriptRoot 'common.psm1') -PassThru
$script:LegacyUtf8 = New-Object Text.UTF8Encoding($false)
$script:LegacyOwner = 'mpvnet-kit'
$script:LegacyReceiptName = '.mpvnet-kit-install.json'

function Assert-LegacyNoReparse([string]$Path) {
    & $script:LegacyCommon { param($Value) Assert-KitNoReparse $Value } $Path
}
function Assert-LegacySeparate([string[]]$Roots) {
    & $script:LegacyCommon { param($Values) Assert-KitSeparate $Values } $Roots
}
function Get-LegacyDirectoryContext([string]$Path) {
    return & $script:LegacyCommon { param($Value) Get-KitDirectoryContext $Value } $Path
}
function New-LegacyLockedDirectory([string]$Path, $Locks) {
    & $script:LegacyCommon { param($Value, $Handles) New-KitLockedDirectory $Value $Handles } $Path $Locks
}
function Write-LegacyFile([string]$Path, [byte[]]$Bytes, [string]$ExpectedHash) {
    & $script:LegacyCommon { param($Value, $Data, $Expected) Write-KitFile $Value $Data $Expected } $Path $Bytes $ExpectedHash
}
function Get-LegacyHashBytes([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
function Get-LegacyBytes($Value) {
    return ,$script:LegacyUtf8.GetBytes(($Value | ConvertTo-Json -Depth 20) + "`n")
}
function Get-LegacyTokenHash([object[]]$Parts) {
    # The common length-prefixed format is stable in Windows PowerShell 5.1 and PowerShell 7.
    return & $script:LegacyCommon { param($Values) Get-KitTokenHash $Values } $Parts
}
function Assert-LegacyFields($Value, [string[]]$Names) {
    if ($Value -isnot [pscustomobject]) { throw 'A JSON object is required.' }
    $actual = @($Value.PSObject.Properties | ForEach-Object { $_.Name })
    if ($actual.Count -ne $Names.Count) { throw 'Unexpected or missing JSON fields.' }
    foreach ($name in $Names) {
        if ($actual -cnotcontains $name) { throw "Missing JSON field: $name" }
    }
}
function Test-LegacySchema($Value) {
    return (($Value -is [int] -or $Value -is [long]) -and $Value -eq 1)
}
function Assert-LegacySha($Value) {
    if ($Value -isnot [string] -or $Value -cnotmatch '^[0-9a-f]{64}$') { throw 'A lowercase SHA256 checksum is required.' }
}
function Assert-LegacyRuntimePath($Value) {
    if ($Value -isnot [string]) { throw 'A runtime path must be a string.' }
    & $script:LegacyCommon { param($Path) Assert-KitRelative $Path } $Value
    if ($Value.StartsWith('config/', [StringComparison]::OrdinalIgnoreCase) -or
        $Value.EndsWith('.example', [StringComparison]::OrdinalIgnoreCase) -or
        $Value -iin @('mpvnet-user.json', 'script-opts/mpvnet-local.conf', 'mpvnet-local.conf', 'local.conf',
            '.mpvnet-kit-install.json', 'settings.xml', 'desktop.ini') -or
        $Value.Split('/')[0] -iin @('watch_later', 'cache')) {
        throw "Private, state, or non-runtime path refused: $Value"
    }
}
function Get-LegacyUtcText($Value) {
    # PowerShell 7 may deserialize an ISO timestamp as DateTime; 5.1 keeps a string.
    if ($Value -is [DateTime]) {
        if ($Value.Kind -ne [DateTimeKind]::Utc) { throw 'A UTC timestamp is required.' }
        return $Value.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -isnot [string] -or $Value -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$') { throw 'An ISO UTC timestamp is required.' }
    $parsed = [DateTime]::MinValue
    if (-not [DateTime]::TryParseExact($Value, 'o', [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) { throw 'Invalid UTC timestamp.' }
    return $Value
}
function Read-LegacyJsonBytes([byte[]]$Bytes) {
    return ($script:LegacyUtf8.GetString($Bytes).TrimStart([char]0xfeff) | ConvertFrom-Json)
}
function Assert-LegacyReleaseMetadata($Release) {
    Assert-LegacyFields $Release @('version', 'tag', 'commit', 'manifestSha256')
    if ($Release.version -isnot [string] -or $Release.version -cnotmatch '^\d+\.\d+\.\d+$' -or
        $Release.tag -isnot [string] -or $Release.tag -cne ('v' + $Release.version) -or
        $Release.commit -isnot [string] -or $Release.commit -cnotmatch '^[0-9a-f]{40}$') { throw 'Invalid legacy release metadata.' }
    Assert-LegacySha $Release.manifestSha256
}
function Get-LegacyReleaseMetadata($Release) {
    return [pscustomobject][ordered]@{ version = $Release.version; tag = $Release.tag; commit = $Release.commit; manifestSha256 = $Release.manifestSha256 }
}
function Get-LegacyCatalog($Package) {
    $manifestBytes = [IO.File]::ReadAllBytes((Get-KitPath $Package.root 'manifest.json'))
    if ((Get-LegacyHashBytes $manifestBytes) -cne $Package.manifestSha256) { throw 'Package manifest changed during legacy preflight.' }
    $manifest = Read-LegacyJsonBytes $manifestBytes
    $entries = @($manifest.files | Where-Object { $_.path -ceq 'tools/legacy-releases.json' })
    if ($entries.Count -ne 1) { throw 'The legacy catalog must be covered by the verified package manifest.' }
    $path = Get-KitPath $Package.root 'tools/legacy-releases.json'
    $bytes = [IO.File]::ReadAllBytes($path); $sha = Get-LegacyHashBytes $bytes
    if ($sha -cne $entries[0].sha256) { throw 'Legacy catalog changed after package verification.' }
    $catalog = Read-LegacyJsonBytes $bytes
    Assert-LegacyFields $catalog @('schema', 'releases')
    if (-not (Test-LegacySchema $catalog.schema) -or $catalog.releases -isnot [array] -or $catalog.releases.Count -eq 0) { throw 'Unsupported or empty legacy catalog.' }
    $versions = @{}; $tags = @{}; $commits = @{}; $allPaths = @{}; $releases = @()
    foreach ($release in $catalog.releases) {
        Assert-LegacyFields $release @('version', 'tag', 'commit', 'manifestSha256', 'files')
        $metadata = Get-LegacyReleaseMetadata $release
        Assert-LegacyReleaseMetadata $metadata
        if ($versions.ContainsKey($release.version) -or $tags.ContainsKey($release.tag) -or $commits.ContainsKey($release.commit) -or
            $release.files -isnot [array] -or $release.files.Count -eq 0) { throw 'Duplicate or empty legacy release.' }
        $versions[$release.version] = $true; $tags[$release.tag] = $true; $commits[$release.commit] = $true
        $seen = @{}; $files = @()
        foreach ($file in $release.files) {
            Assert-LegacyFields $file @('path', 'sha256')
            Assert-LegacyRuntimePath $file.path; Assert-LegacySha $file.sha256
            if ($seen.ContainsKey($file.path) -or ($allPaths.ContainsKey($file.path) -and $allPaths[$file.path] -cne $file.path)) { throw 'Duplicate or case-colliding legacy runtime path.' }
            $seen[$file.path] = $true; $allPaths[$file.path] = $file.path
            $files += [pscustomobject]@{ path = $file.path; sha256 = $file.sha256 }
        }
        $releases += [pscustomobject]@{ version = $metadata.version; tag = $metadata.tag; commit = $metadata.commit; manifestSha256 = $metadata.manifestSha256; files = $files }
    }
    return [pscustomobject]@{ path = $path; sha256 = $sha; releases = $releases; paths = $allPaths }
}
function Get-LegacyTargetEntry([string]$Target, [string]$Relative, [switch]$MetadataOnly) {
    $path = Get-KitPath $Target $Relative
    try { $attributes = [IO.File]::GetAttributes($path) }
    catch [IO.FileNotFoundException] { return [pscustomobject]@{ path = $Relative; target = $path; state = 'missing'; sha256 = $null; bytes = $null } }
    catch [IO.DirectoryNotFoundException] { return [pscustomobject]@{ path = $Relative; target = $path; state = 'missing'; sha256 = $null; bytes = $null } }
    if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
        return [pscustomobject]@{ path = $Relative; target = $path; state = 'directory'; sha256 = $null; bytes = $null }
    }
    $bytes = $null; $sha = $null
    if (-not $MetadataOnly) { $bytes = [IO.File]::ReadAllBytes($path); $sha = Get-LegacyHashBytes $bytes }
    return [pscustomobject]@{ path = $Relative; target = $path; state = 'file'; sha256 = $sha; bytes = $bytes }
}
function Get-LegacyPlanToken($Plan) {
    $parts = @(1, $Plan.player.ToLowerInvariant(), $Plan.targetContext.contextToken, $Plan.package.root.ToLowerInvariant(),
        $Plan.package.manifestSha256, $Plan.catalog.sha256, $Plan.packageContext.targetIdentity,
        $Plan.packageContext.nearestExistingParent.ToLowerInvariant(), $Plan.packageContext.nearestExistingParentIdentity,
        $Plan.backupRoot.ToLowerInvariant(), [int]$Plan.backupContext.targetExists, $Plan.backupContext.targetIdentity,
        $Plan.backupContext.nearestExistingParent.ToLowerInvariant(), $Plan.backupContext.nearestExistingParentIdentity,
        $Plan.receiptState, [int]$Plan.view.eligible)
    if ($Plan.matchedRelease) {
        $parts += @($Plan.matchedRelease.version, $Plan.matchedRelease.tag, $Plan.matchedRelease.commit, $Plan.matchedRelease.manifestSha256)
    } else { $parts += @($null, $null, $null, $null) }
    foreach ($file in $Plan.files) { $parts += @($file.path, $file.state, $file.sha256, $file.newSha256, [int]$file.legacy) }
    return 'mpvnet-kit-legacy-v1:' + (Get-LegacyTokenHash $parts)
}
function Get-KitLegacyPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$PlayerPath, [string]$ConfigDirectory = '', [string]$BackupRoot = '', [string]$PackageRoot = '')
    if (-not $PackageRoot) { $PackageRoot = Split-Path -Parent $PSScriptRoot }
    $player = Get-KitPlayer $PlayerPath
    $context = Get-KitTargetContext -PlayerPath $player -ConfigDirectory $ConfigDirectory
    $package = Get-KitPackage $PackageRoot; $catalog = Get-LegacyCatalog $package
    if (-not $BackupRoot) { $BackupRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'mpvnet-kit/backups' }
    $target = $context.target; $backup = Get-KitRoot $BackupRoot
    Assert-LegacyNoReparse $target; Assert-LegacyNoReparse $backup
    Assert-LegacySeparate @($package.root, $target, $backup)
    if ($player.StartsWith($target.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'The configuration directory cannot contain the player executable.' }
    $backupContext = Get-LegacyDirectoryContext $backup; $packageContext = Get-LegacyDirectoryContext $package.root
    # Receipt bytes and their referenced backup chain are deliberately not read here.
    $receipt = Get-LegacyTargetEntry $target $script:LegacyReceiptName -MetadataOnly
    $paths = @{}; $newFiles = @{}
    foreach ($path in $catalog.paths.Values) { $paths[$path] = $path }
    foreach ($file in $package.runtime) {
        Assert-LegacyRuntimePath $file.path
        if ($paths.ContainsKey($file.path) -and $paths[$file.path] -cne $file.path) { throw 'The package and legacy catalog disagree on path casing.' }
        $paths[$file.path] = $file.path; $newFiles[$file.path] = $file
    }
    $orderedPaths = New-Object 'System.Collections.Generic.List[string]'
    foreach ($path in $paths.Values) { $orderedPaths.Add($path) }
    $orderedPaths.Sort([StringComparer]::Ordinal)
    $files = @(); $byPath = @{}
    foreach ($path in $orderedPaths) {
        $entry = Get-LegacyTargetEntry $target $path -MetadataOnly:(-not $catalog.paths.ContainsKey($path))
        $file = [pscustomobject]@{ path = $path; target = $entry.target; state = $entry.state; sha256 = $entry.sha256; bytes = $entry.bytes;
            newSha256 = $(if ($newFiles.ContainsKey($path)) { $newFiles[$path].sha256 } else { $null }); legacy = $catalog.paths.ContainsKey($path) }
        $files += $file; $byPath[$path] = $file
    }
    $candidates = @(); $matches = @()
    foreach ($release in $catalog.releases) {
        $differences = @(); $matchedFiles = 0
        foreach ($file in $release.files) {
            $actual = $byPath[$file.path]
            if ($actual.state -eq 'file' -and $actual.sha256 -ceq $file.sha256) { $matchedFiles++ }
            else {
                $differences += [ordered]@{ path = $file.path; state = $(if ($actual.state -eq 'file') { 'modified' } else { $actual.state });
                    expectedSha256 = $file.sha256; actualSha256 = $actual.sha256 }
            }
        }
        $matched = $differences.Count -eq 0
        $candidates += [ordered]@{ version = $release.version; tag = $release.tag; commit = $release.commit; manifestSha256 = $release.manifestSha256;
            matched = $matched; matchedFiles = $matchedFiles; totalFiles = $release.files.Count; differences = $differences }
        if ($matched) { $matches += $release }
    }
    $matchedRelease = if ($matches.Count -eq 1) { $matches[0] } else { $null }
    $conflicts = @(); $eligible = $false; $classification = 'unrecognized'
    if ($receipt.state -ne 'missing') {
        $classification = 'receipt-present'; $reason = 'Existing CLI receipt state must use the existing installation and restore workflow.'
        $conflicts += [ordered]@{ type = 'receipt-present'; path = $script:LegacyReceiptName; state = $receipt.state }
    } elseif ($matches.Count -gt 1) {
        $classification = 'ambiguous'; $reason = 'The target completely matches more than one catalog release; no version is assumed.'
        $conflicts += [ordered]@{ type = 'ambiguous-release'; path = $null; versions = @($matches | ForEach-Object { $_.version }) }
    } elseif (-not $matchedRelease) {
        $reason = 'No complete known release matches; missing, modified, mixed or unknown contents are not adopted.'
    } else {
        $oldPaths = @{}; foreach ($file in $matchedRelease.files) { $oldPaths[$file.path] = $true }
        foreach ($file in $matchedRelease.files) {
            if (-not $newFiles.ContainsKey($file.path)) { $conflicts += [ordered]@{ type = 'retired-runtime'; path = $file.path } }
        }
        foreach ($file in $package.runtime) {
            if (-not $oldPaths.ContainsKey($file.path) -and $byPath[$file.path].state -ne 'missing') {
                $conflicts += [ordered]@{ type = 'new-runtime-collision'; path = $file.path; state = $byPath[$file.path].state; sha256 = $byPath[$file.path].sha256 }
            }
        }
        if ($conflicts.Count) { $classification = 'conflict'; $reason = 'Retired runtime paths or occupied new runtime paths prevent legacy preparation.' }
        else { $eligible = $true; $classification = 'recognized-legacy'; $reason = 'All catalog runtime bytes match one known release and new runtime paths are absent.' }
    }
    if ((Get-KitTargetContext -PlayerPath $player -ConfigDirectory $ConfigDirectory).contextToken -cne $context.contextToken) { throw 'Target directory context changed during preflight; preview again.' }
    $warnings = @('内容匹配只能识别发行字节，不能证明原先使用哪一种安装方式。')
    if ($context.source -eq 'environment') { $warnings += '目录按当前进程的 MPVNET_HOME 判断；启动播放器时须使用相同环境。' }
    $view = [ordered]@{ mode = 'preview'; action = 'legacy-backup'; eligible = $eligible; classification = $classification; reason = $reason;
        target = $target; player = $player; backupRoot = $backup; packageVersion = $package.version; verifiedPackageFiles = $package.verifiedFileCount;
        catalogSha256 = $catalog.sha256; targetSource = $context.source; targetSourceLabel = $context.sourceLabel; targetExists = $context.targetExists;
        matchedRelease = $(if ($matchedRelease) { Get-LegacyReleaseMetadata $matchedRelease } else { $null }); candidates = $candidates; conflicts = $conflicts;
        snapshotFiles = $(if ($matchedRelease) { $matchedRelease.files.Count } else { 0 }); runtimeFiles = $package.runtime.Count; warnings = $warnings;
        requirement = 'Close affected player instances before Apply; this tool never launches or kills players and never changes target files.';
        files = @($files | ForEach-Object { [ordered]@{ path = $_.path; state = $_.state; sha256 = $_.sha256; newSha256 = $_.newSha256; legacy = $_.legacy } }); planToken = '' }
    $plan = [pscustomobject]@{ player = $player; package = $package; packageContext = $packageContext; catalog = $catalog; target = $target; targetContext = $context;
        backupRoot = $backup; backupContext = $backupContext; receiptState = $receipt.state; files = $files; matchedRelease = $matchedRelease; view = $view; planToken = '' }
    $plan.planToken = Get-LegacyPlanToken $plan; $view['planToken'] = $plan.planToken
    return $plan
}
function Get-LegacyRecordHash($Record) {
    $parts = @(1, $Record.owner, $Record.kind, $Record.id, $Record.target, $Record.release.version, $Record.release.tag,
        $Record.release.commit, $Record.release.manifestSha256, $Record.packageVersion, $Record.catalogSha256,
        $Record.packageManifestSha256, (Get-LegacyUtcText $Record.createdUtc))
    foreach ($file in $Record.files) { $parts += @($file.path, $file.sha256, $file.backup) }
    return Get-LegacyTokenHash $parts
}
function Save-LegacyStatus([string]$Directory, [string]$Id, [string]$State, [string]$ManifestHash, [string]$Message, [string]$ExpectedHash) {
    $bytes = Get-LegacyBytes ([ordered]@{ schema = 1; owner = $script:LegacyOwner; kind = 'legacy-snapshot-status'; id = $Id;
        state = $State; manifestSha256 = $ManifestHash; message = $Message; updatedUtc = [DateTime]::UtcNow.ToString('o') })
    Write-LegacyFile (Get-KitPath $Directory 'status.json') $bytes $ExpectedHash
    return Get-LegacyHashBytes $bytes
}
function Read-LegacySnapshot([string]$SnapshotManifest, [switch]$AllowPrepared) {
    $path = Get-KitRoot $SnapshotManifest; Assert-LegacyNoReparse $path
    if ([IO.Path]::GetFileName($path) -cne 'manifest.json') { throw 'A legacy snapshot manifest.json is required.' }
    $directory = [IO.Path]::GetDirectoryName($path)
    $manifestBytes = [IO.File]::ReadAllBytes($path); $manifestSha = Get-LegacyHashBytes $manifestBytes
    $record = Read-LegacyJsonBytes $manifestBytes
    Assert-LegacyFields $record @('schema', 'owner', 'kind', 'id', 'target', 'release', 'packageVersion', 'catalogSha256', 'packageManifestSha256', 'createdUtc', 'files', 'dataSha256')
    if (-not (Test-LegacySchema $record.schema) -or $record.owner -isnot [string] -or $record.owner -cne $script:LegacyOwner -or
        $record.kind -isnot [string] -or $record.kind -cne 'legacy-snapshot' -or
        $record.id -isnot [string] -or $record.id -cnotmatch '^[0-9a-f]{32}$' -or $record.target -isnot [string] -or
        $record.packageVersion -isnot [string] -or -not $record.packageVersion -or $record.files -isnot [array] -or $record.files.Count -eq 0) { throw 'Unowned or invalid legacy snapshot.' }
    Assert-LegacyReleaseMetadata $record.release
    Assert-LegacySha $record.catalogSha256; Assert-LegacySha $record.packageManifestSha256; Assert-LegacySha $record.dataSha256
    [void](Get-LegacyUtcText $record.createdUtc)
    $target = Get-KitRoot $record.target
    Assert-LegacySeparate @($directory, $target)
    $seen = @{}
    foreach ($file in $record.files) {
        Assert-LegacyFields $file @('path', 'sha256', 'backup')
        Assert-LegacyRuntimePath $file.path; Assert-LegacySha $file.sha256
        if ($seen.ContainsKey($file.path) -or $file.backup -isnot [string] -or $file.backup -cne ('files/' + $file.path)) { throw 'Duplicate or unsafe legacy snapshot file entry.' }
        $seen[$file.path] = $true
        if ((Get-KitHash (Get-KitPath $directory $file.backup)) -cne $file.sha256) { throw "Legacy snapshot checksum mismatch: $($file.path)" }
    }
    if ((Get-LegacyRecordHash $record) -cne $record.dataSha256) { throw 'Legacy snapshot record data changed.' }
    $status = Read-LegacyJsonBytes ([IO.File]::ReadAllBytes((Get-KitPath $directory 'status.json')))
    Assert-LegacyFields $status @('schema', 'owner', 'kind', 'id', 'state', 'manifestSha256', 'message', 'updatedUtc')
    Assert-LegacySha $status.manifestSha256
    if (-not (Test-LegacySchema $status.schema) -or $status.owner -isnot [string] -or $status.owner -cne $script:LegacyOwner -or
        $status.kind -isnot [string] -or $status.kind -cne 'legacy-snapshot-status' -or $status.id -isnot [string] -or
        $status.id -cne $record.id -or $status.state -isnot [string] -or $status.message -isnot [string] -or $status.manifestSha256 -cne $manifestSha -or
        ($status.state -cne 'complete' -and -not ($AllowPrepared -and $status.state -ceq 'prepared'))) { throw 'Legacy snapshot is incomplete, failed, or its completion record changed.' }
    [void](Get-LegacyUtcText $status.updatedUtc)
    return [pscustomobject]@{ value = $record; directory = $directory; manifest = $path; manifestSha256 = $manifestSha; target = $target; state = $status.state }
}
function Write-LegacySnapshotFile([string]$Path, [byte[]]$Bytes, [string]$ExpectedHash) {
    if ((Get-LegacyHashBytes $Bytes) -cne $ExpectedHash) { throw 'Target bytes changed before the snapshot copy.' }
    Write-LegacyFile $Path $Bytes $null
    if ((Get-KitHash $Path) -cne $ExpectedHash) { throw 'Snapshot bytes changed after the copy.' }
}
function Assert-LegacySourceUnchanged($Plan, [string]$ConfigDirectory) {
    if ((Get-KitTargetContext -PlayerPath $Plan.player -ConfigDirectory $ConfigDirectory).contextToken -cne $Plan.targetContext.contextToken) {
        throw 'Target directory context changed while preparing the snapshot.'
    }
    if ((Get-LegacyTargetEntry $Plan.target $script:LegacyReceiptName -MetadataOnly).state -cne 'missing') {
        throw 'A CLI receipt appeared while preparing the legacy snapshot.'
    }
    foreach ($file in $Plan.files) {
        $actual = Get-LegacyTargetEntry $Plan.target $file.path -MetadataOnly:(-not $file.legacy)
        if ($actual.state -cne $file.state -or $actual.sha256 -cne $file.sha256) {
            throw "Target contents changed while preparing the snapshot: $($file.path)"
        }
    }
}
function Invoke-KitLegacyBackup {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$PlayerPath, [string]$ConfigDirectory = '', [string]$BackupRoot = '', [string]$PackageRoot = '',
        [switch]$Apply, [string]$ExpectedPlanToken = '')
    $plan = Get-KitLegacyPlan -PlayerPath $PlayerPath -ConfigDirectory $ConfigDirectory -BackupRoot $BackupRoot -PackageRoot $PackageRoot
    if (-not $Apply) { return $plan.view }
    if (-not $ExpectedPlanToken) { throw 'Legacy backup Apply always requires -ExpectedPlanToken from a reviewed preview.' }
    if ($ExpectedPlanToken -cne $plan.planToken) { throw 'Legacy backup plan changed; preview and confirm the new plan before Apply.' }
    if (-not $plan.view.eligible) { throw ('Legacy backup is not eligible. ' + $plan.view.reason) }
    $locks = @{}; $directory = $null; $statusSha = $null; $manifestSha = $null; $id = $null
    try {
        foreach ($root in @($plan.target, $plan.backupRoot, $plan.package.root)) { Add-KitExistingDirectoryLocks $root $locks }
        foreach ($file in $plan.files) { Add-KitExistingDirectoryLocks ([IO.Path]::GetDirectoryName($file.target)) $locks }
        foreach ($file in $plan.package.runtime) { Add-KitExistingDirectoryLocks ([IO.Path]::GetDirectoryName((Get-KitPath $plan.package.root ('config/' + $file.path)))) $locks }
        Add-KitExistingDirectoryLocks ([IO.Path]::GetDirectoryName($plan.catalog.path)) $locks
        $current = Get-KitLegacyPlan -PlayerPath $PlayerPath -ConfigDirectory $ConfigDirectory -BackupRoot $BackupRoot -PackageRoot $PackageRoot
        if ($current.planToken -cne $ExpectedPlanToken -or -not $current.view.eligible) { throw 'Legacy backup plan changed while acquiring directory locks; preview again.' }
        $plan = $current
        $id = [Guid]::NewGuid().ToString('N'); $directory = Get-KitPath $plan.backupRoot $id
        if ([IO.Directory]::Exists($directory) -or [IO.File]::Exists($directory)) { throw 'Snapshot ID already exists.' }
        New-LegacyLockedDirectory $directory $locks
        $recordFiles = @($plan.matchedRelease.files | ForEach-Object { [ordered]@{ path = $_.path; sha256 = $_.sha256; backup = 'files/' + $_.path } })
        $record = [ordered]@{ schema = 1; owner = $script:LegacyOwner; kind = 'legacy-snapshot'; id = $id; target = $plan.target;
            release = (Get-LegacyReleaseMetadata $plan.matchedRelease); packageVersion = $plan.package.version; catalogSha256 = $plan.catalog.sha256;
            packageManifestSha256 = $plan.package.manifestSha256; createdUtc = [DateTime]::UtcNow.ToString('o'); files = $recordFiles; dataSha256 = '' }
        $record['dataSha256'] = Get-LegacyRecordHash $record
        $manifestBytes = Get-LegacyBytes $record; $manifestSha = Get-LegacyHashBytes $manifestBytes
        Write-LegacyFile (Get-KitPath $directory 'manifest.json') $manifestBytes $null
        $statusSha = Save-LegacyStatus $directory $id 'prepared' $manifestSha 'Snapshot plan recorded; file copies are not yet complete.' $null
        foreach ($file in $recordFiles) {
            $saved = Get-KitPath $directory $file.backup
            New-LegacyLockedDirectory ([IO.Path]::GetDirectoryName($saved)) $locks
            # Copy only freshly read target bytes, including files unchanged in the new package.
            $source = Get-KitPath $plan.target $file.path
            $bytes = [IO.File]::ReadAllBytes($source)
            Write-LegacySnapshotFile $saved $bytes $file.sha256
        }
        [void](Read-LegacySnapshot (Get-KitPath $directory 'manifest.json') -AllowPrepared)
        Assert-LegacySourceUnchanged $plan $ConfigDirectory
        $statusSha = Save-LegacyStatus $directory $id 'complete' $manifestSha 'All legacy runtime bytes copied and verified; target files were not changed.' $statusSha
        [void](Test-KitLegacySnapshot -SnapshotManifest (Get-KitPath $directory 'manifest.json'))
        $plan.view['mode'] = 'applied'; $plan.view['status'] = 'complete'; $plan.view['id'] = $id
        $plan.view['backupManifest'] = Get-KitPath $directory 'manifest.json'
        return $plan.view
    } catch {
        $failure = $_.Exception.Message
        if ($directory -and [IO.Directory]::Exists($directory)) {
            try { [void](Save-LegacyStatus $directory $id 'failed' $manifestSha $failure $statusSha) } catch { }
            throw "Legacy snapshot failed; retained partial evidence in $directory. Target files were not changed. $failure"
        }
        throw
    } finally { foreach ($handle in $locks.Values) { $handle.Dispose() } }
}
function Test-KitLegacySnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$SnapshotManifest)
    $loaded = Read-LegacySnapshot $SnapshotManifest
    return [ordered]@{ mode = 'read-only'; action = 'verify-legacy-snapshot'; status = 'verified'; kind = 'legacy-snapshot'; id = $loaded.value.id;
        target = $loaded.target; release = $loaded.value.release; snapshotFiles = $loaded.value.files.Count; backupManifest = $loaded.manifest;
        manifestSha256 = $loaded.manifestSha256; catalogSha256 = $loaded.value.catalogSha256; packageManifestSha256 = $loaded.value.packageManifestSha256;
        reason = 'All snapshot bytes and completion metadata verified; the current target was not inspected.';
        files = @($loaded.value.files) }
}
function Write-KitLegacyResult($Value, [ValidateSet('Json', 'Text')][string]$OutputFormat = 'Json', [switch]$Details) {
    [Console]::OutputEncoding = $script:LegacyUtf8
    if ($OutputFormat -eq 'Json') { [Console]::WriteLine(($Value | ConvertTo-Json -Depth 20)); return }
    $data = @{}
    if ($Value -is [Collections.IDictionary]) { foreach ($key in $Value.Keys) { $data[$key] = $Value[$key] } }
    else { foreach ($property in $Value.PSObject.Properties) { $data[$property.Name] = $property.Value } }
    $lines = New-Object 'System.Collections.Generic.List[string]'
    if ($data['status'] -eq 'refused-or-failed') {
        $lines.Add('未完成：旧安装检查或备份被拒绝／失败'); $lines.Add([string]$data['error'])
        $lines.Add('请保留现场并核对失败记录；未完成的快照不能作为完整备份。')
        [Console]::WriteLine(($lines -join "`r`n")); return
    }
    if ($data['action'] -eq 'verify-legacy-snapshot') { $lines.Add('旧安装快照 · 完整性验证通过（只读）') }
    elseif ($data['mode'] -eq 'applied') { $lines.Add('旧安装快照 · 已备份并验证，配置目录未写入') }
    else { $lines.Add('旧安装快照 · 预览，尚未写入'); $lines.Add('可准备备份：' + $(if ($data['eligible']) { '是' } else { '否' })) }
    $lines.Add("配置目录：$($data['target'])")
    if ($data['targetSourceLabel']) { $lines.Add("识别来源：$($data['targetSourceLabel'])") }
    if ($data['targetSource'] -eq 'explicit') { $lines.Add('提示：显式目录仅指定操作位置，请确认播放器实际读取该目录。') }
    if ($data['matchedRelease']) { $lines.Add("内容匹配发行：$($data['matchedRelease'].tag)") }
    if ($data['release']) { $lines.Add("快照发行：$($data['release'].tag)") }
    if ($data['backupRoot']) { $lines.Add("备份根目录：$($data['backupRoot'])") }
    if ($data['backupManifest']) { $lines.Add("快照清单：$($data['backupManifest'])") }
    $lines.Add("快照文件数：$($data['snapshotFiles'])")
    if ($data['reason']) { $lines.Add("说明：$($data['reason'])") }
    if ($data['warnings']) { foreach ($warning in $data['warnings']) { $lines.Add("提示：$warning") } }
    if ($data['conflicts']) { foreach ($conflict in $data['conflicts']) { $lines.Add("冲突：$($conflict.type) $($conflict.path)") } }
    if ($data['mode'] -eq 'preview' -and $data['eligible']) {
        $lines.Add('执行前请退出受影响播放器；工具不会启动或关闭播放器。')
        $lines.Add("预览校验值：$($data['planToken'])")
        $lines.Add("确认后在相同参数后追加：-Apply -ExpectedPlanToken '$($data['planToken'])'")
    }
    if ($Details -and $data['candidates']) {
        foreach ($candidate in $data['candidates']) {
            $lines.Add("候选 $($candidate.tag)：匹配 $($candidate.matchedFiles)/$($candidate.totalFiles)")
            foreach ($difference in $candidate.differences) { $lines.Add("  [$($difference.state)] $($difference.path)"); $lines.Add("    预期：$($difference.expectedSha256)"); $lines.Add("    实际：$($difference.actualSha256)") }
        }
    }
    if ($Details -and $data['files']) {
        $lines.Add('文件明细：')
        foreach ($file in $data['files']) { $lines.Add("  $($file.path)"); $lines.Add("    SHA256：$($file.sha256)") }
    }
    [Console]::WriteLine(($lines -join "`r`n"))
}

Export-ModuleMember -Function Get-KitLegacyPlan,Invoke-KitLegacyBackup,Test-KitLegacySnapshot,Write-KitLegacyResult
