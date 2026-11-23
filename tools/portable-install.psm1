Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:Common = Import-Module (Join-Path $PSScriptRoot 'common.psm1') -PassThru
$script:Maintenance = Import-Module (Join-Path $PSScriptRoot 'maintenance.psm1') -PassThru

function Test-KitPortablePackage([string]$PackageRoot) {
    # Presence only, for choosing the UI. The plan verifies both manifest entries.
    if ([IO.File]::Exists((Join-Path $PackageRoot 'tools/portable-release.json')) -or
        [IO.Directory]::Exists((Join-Path $PackageRoot 'upstream'))) { return $true }
    try {
        $manifest = Get-KitPath $PackageRoot 'manifest.json'
        if (-not [IO.File]::Exists($manifest)) { return $false }
        $files = ([IO.File]::ReadAllText($manifest) | ConvertFrom-Json).files
        return [bool](@($files | Where-Object { $_.path -eq 'tools/portable-release.json' -or $_.path -like 'upstream/*' }).Count)
    } catch { return $false } # The regular maintenance check reports malformed packages.
}

function Assert-PortableDirectoryEmpty([string]$Path, [string]$Staging = '') {
    if (-not [IO.Directory]::Exists($Path)) { return }
    foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($Path)) {
        if ($Staging -and $entry -ieq $Staging) { continue }
        throw "安装目录已包含 $([IO.Path]::GetFileName($entry))。请选择空文件夹，或选择已有播放器中的 mpvnet.exe。"
    }
}

function Get-KitPortablePlan {
    param([Parameter(Mandatory=$true)][string]$InstallDirectory, [Parameter(Mandatory=$true)][string]$PackageRoot, [string]$BackupRoot = '')
    $plan = [ordered]@{ mode = 'preview'; action = 'blocked'; eligible = $false; reason = ''; planToken = ''; target = ''; targetExists = $false;
        targetSource = 'portable'; targetSourceLabel = '新播放器的便携配置目录'; installDirectory = ''; playerPath = ''; launcherPath = ''; packageVersion = '';
        backupRoot = ''; installedVersion = $null; changedFiles = 0; addedFiles = 0; files = @(); canRestore = $false; warnings = @(); runningProcesses = @(); releaseNotice = '' }
    try {
        if (-not [Environment]::Is64BitOperatingSystem) { throw '随包播放器需要 64 位 Windows。' }
        $location = & $script:Common { param($Path) Get-KitDirectoryContext $Path } $InstallDirectory
        $root = $location.target; $plan.installDirectory = $root
        $plan.launcherPath = Get-KitPath $root 'Play.cmd'
        $plan.playerPath = Get-KitPath $root 'player/mpvnet.exe'
        $plan.target = Get-KitPath $root 'player/portable_config'
        Assert-PortableDirectoryEmpty $root
        if (-not $BackupRoot) { $BackupRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'mpvnet-kit/backups' }
        $backup = & $script:Common { param($Path) Get-KitDirectoryContext $Path } $BackupRoot
        $plan.backupRoot = $backup.target
        & $script:Common { param($Roots) Assert-KitSeparate $Roots } @($root,$PackageRoot,$backup.target)
        $package = Get-KitPackage $PackageRoot
        if (-not $package.portableRelease) { throw '此安装包没有随附官方播放器，请使用完整离线安装包。' }
        & $script:Maintenance { Assert-MaintenancePlayersStopped }
        $plan.packageVersion = $package.version
        $plan['packageManifestSha256'] = $package.manifestSha256
        $plan.changedFiles = $package.runtime.Count; $plan.addedFiles = $package.runtime.Count
        $plan.files = @($package.runtime | ForEach-Object { [ordered]@{path = $_.path; change = 'added'} })
        $plan.action = 'install-player'; $plan.eligible = $true
        $plan.reason = "将从随包附件安装官方 mpv.net $($package.portableRelease.version) x64，再安装配置包。"
        $parts = @($root.ToLowerInvariant(),$location.targetIdentity,$location.nearestExistingParent,$location.nearestExistingParentIdentity,
            $backup.target.ToLowerInvariant(),$backup.targetIdentity,$backup.nearestExistingParent,$backup.nearestExistingParentIdentity,
            $package.root.ToLowerInvariant(),$package.manifestSha256)
        $plan.planToken = 'mpvnet-kit-portable-v1:' + (& $script:Common { param($Fields) Get-KitTokenHash $Fields } $parts)
    } catch {
        $plan.eligible = $false; $plan.action = 'blocked'; $plan.reason = Get-KitMaintenanceReason $_.Exception.Message
    }
    return $plan
}

function Expand-KitPortableArchive($Package, [string]$Staging) {
    Add-Type -AssemblyName System.IO.Compression
    $release = $Package.portableRelease
    $archivePath = Get-KitPath $Package.root $release.archive.path
    # Hash and extract through the same read-only handle. Nothing is run from the archive.
    $stream = [IO.File]::OpenRead($archivePath)
    try {
        $hash = [Security.Cryptography.SHA256]::Create()
        try { $digest = [BitConverter]::ToString($hash.ComputeHash($stream)).Replace('-','').ToLowerInvariant() } finally { $hash.Dispose() }
        if ($digest -cne $release.archive.sha256) { throw '官方 portable ZIP 在检查后发生变化，请重新运行完整安装程序。' }
        $stream.Position = 0
        $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Read)
        try {
            foreach ($entry in $archive.Entries) {
                $path = Get-KitPath $Staging $entry.FullName.TrimEnd('/')
                if ($entry.FullName.EndsWith('/')) { [void][IO.Directory]::CreateDirectory($path); continue }
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
                $output = [IO.File]::Open($path, 'CreateNew', 'Write', 'None')
                try {
                    $inputStream = $entry.Open()
                    try { $inputStream.CopyTo($output) } finally { $inputStream.Dispose() }
                } finally { $output.Dispose() }
            }
        } finally { $archive.Dispose() }
    } finally { $stream.Dispose() }
    $player = Get-KitPath $Staging $release.runtime.executable
    & $script:Common { param($Player,$Release) Assert-KitCompatiblePlayer $Player $Release } $player $release
}

function Invoke-KitPortableInstall {
    param([Parameter(Mandatory=$true)][string]$InstallDirectory, [Parameter(Mandatory=$true)][string]$PackageRoot, [string]$BackupRoot = '',
        [Parameter(Mandatory=$true)][string]$ExpectedPlanToken)
    $root = Get-KitRoot $InstallDirectory
    $locks = @{}; $mutex = $null; $staging = ''; $published = $false
    try {
        $mutex = Enter-KitMaintenanceMutex $root
        Add-KitExistingDirectoryLocks $root $locks
        $plan = Get-KitPortablePlan -InstallDirectory $root -PackageRoot $PackageRoot -BackupRoot $BackupRoot
        if (-not $plan.eligible) { throw $plan.reason }
        if ($plan.planToken -cne $ExpectedPlanToken) { throw '安装位置、备份位置或安装包发生变化，请重新检查并确认。' }
        # Keep the verified package in place across extraction and kit maintenance.
        Add-KitExistingDirectoryLocks $PackageRoot $locks
        $manifest = [IO.File]::OpenRead((Get-KitPath $PackageRoot 'manifest.json'))
        try {
            $package = Get-KitPackage $PackageRoot
            if ($package.manifestSha256 -cne $plan.packageManifestSha256) { throw '安装包已变化，请重新检查。' }
            & $script:Common { param($Path,$Locks) New-KitLockedDirectory $Path $Locks } $root $locks
            Assert-PortableDirectoryEmpty $root
            $staging = Get-KitPath $root ('.mpvnet-kit-stage-' + [Guid]::NewGuid().ToString('N'))
            if (-not [MpvnetKitNative]::CreateDirectory($staging,[IntPtr]::Zero)) { throw '无法创建解压暂存目录，请检查安装位置。' }
            $stageLock = Lock-KitDirectory $staging
            try {
                Expand-KitPortableArchive $package $staging
                [void][IO.Directory]::CreateDirectory((Get-KitPath $staging 'portable_config'))
                Assert-PortableDirectoryEmpty $root $staging
                & $script:Maintenance { Assert-MaintenancePlayersStopped }
                & $script:Common { param($Path) Write-KitFile $Path (Get-KitLauncherBytes) $null } $plan.launcherPath
            } finally { $stageLock.Dispose() }
            [IO.Directory]::Move($staging,(Get-KitPath $root 'player'))
            $published = $true
            # A kit receipt records final absolute paths. Use the normal maintenance
            # transaction only after publishing the complete original player.
            $argsKit = @{ PlayerPath = $plan.playerPath; BackupRoot = $plan.backupRoot; PackageRoot = $package.root }
            $kit = Get-KitMaintenancePlan @argsKit
            if (-not $kit.eligible -or $kit.action -ne 'install' -or $kit.target -ine $plan.target) { throw ('配置安装检查未通过。' + $kit.reason) }
            $result = Invoke-KitMaintenance @argsKit -Operation Apply -ExpectedPlanToken $kit.planToken
            $result.action = 'install-player'; $result['playerPath'] = $plan.playerPath; $result['launcherPath'] = $plan.launcherPath
            return $result
        } finally { $manifest.Dispose() }
    } catch {
        if ($published) { throw "官方播放器已完整解压。请保留配置和备份，选择 $($plan.playerPath) 重新检查并继续。$($_.Exception.Message)" }
        if ($staging -and [IO.Directory]::Exists($staging)) { throw "解压未完成，已保留暂存目录 $staging。请检查原因后另选空目录。$($_.Exception.Message)" }
        throw
    } finally {
        foreach ($handle in $locks.Values) { $handle.Dispose() }
        Exit-KitMaintenanceMutex $mutex
    }
}

Export-ModuleMember -Function Test-KitPortablePackage,Get-KitPortablePlan,Invoke-KitPortableInstall
