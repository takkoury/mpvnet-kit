param([string]$SourceRoot, [string]$CaseRoot, [string]$Case)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
if (-not [IO.Path]::IsPathRooted($CaseRoot) -or (Test-Path -LiteralPath $CaseRoot)) { throw 'A new absolute fixture directory is required.' }
[void][IO.Directory]::CreateDirectory($CaseRoot)
$tools = Join-Path $SourceRoot 'tools'
Import-Module (Join-Path $tools 'common.psm1') -Force
Import-Module (Join-Path $tools 'clean-install.psm1') -Force
$common = Get-Module common
$clean = Get-Module clean-install
$utf8 = New-Object Text.UTF8Encoding($false)
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function New-Dir([string]$Path) { [void][IO.Directory]::CreateDirectory($Path); return $Path }
function Put([string]$Path, [string]$Text) { [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)); [IO.File]::WriteAllText($Path, $Text, $utf8) }
function Refused([scriptblock]$Action, [string]$Pattern = '') {
    $failure = ''
    try { & $Action | Out-Null } catch { $failure = $_.Exception.Message }
    Assert ([bool]$failure) 'Expected refusal'
    if ($Pattern) { Assert ($failure -match $Pattern) "Unexpected refusal: $failure" }
}
function Snapshot([string]$Root) {
    if (-not (Test-Path -LiteralPath $Root)) { return 'absent' }
    return (@(Get-ChildItem -LiteralPath $Root -Recurse -Force | Sort-Object FullName | ForEach-Object {
        $_.FullName + '|' + $(if ($_.PSIsContainer) { 'directory' } else { Get-KitHash $_.FullName })
    }) -join "`n")
}
function Package([string]$Name, [string]$Version, [hashtable]$Files) {
    $root = New-Dir (Join-Path $CaseRoot $Name)
    $entries = @()
    foreach ($name in @($Files.Keys | Sort-Object)) {
        $path = Join-Path $root ('config/' + $name)
        Put $path $Files[$name]
        $entries += [ordered]@{ path = 'config/' + $name; sha256 = Get-KitHash $path }
    }
    Put (Join-Path $root 'manifest.json') (([ordered]@{ schema = 1; version = $Version; files = $entries }) | ConvertTo-Json -Depth 8)
    return $root
}
$player = Join-Path (New-Dir (Join-Path $CaseRoot 'player 空格')) 'mpvnet.exe'
Put $player 'Fixture only. Never execute.'
$portable = Join-Path ([IO.Path]::GetDirectoryName($player)) 'portable_config'
$roaming = New-Dir (Join-Path $CaseRoot 'roaming')
$appdataTarget = Join-Path $roaming 'mpv.net'
$target = Join-Path $CaseRoot 'target'
$backup = Join-Path $CaseRoot 'backups'
$package = Package 'package' 'fixture-1' @{ 'mpv.conf' = 'fixture=1'; 'scripts/sample.lua' = '-- fixture' }
$env:MPVNET_HOME = ''
# Test seam stays in this disposable process; never redirect the real user profile.
& $common { param($Root) $script:FixtureRoamingRoot = $Root; Set-Item Function:script:Get-KitRoamingRoot { $script:FixtureRoamingRoot } } $roaming
function Preview([string]$Explicit = '') { Invoke-KitInstall -PlayerPath $player -ConfigDirectory $Explicit -BackupRoot $backup -PackageRoot $package }
function Apply([string]$Explicit = '', [string]$Token = '') { Invoke-KitInstall -PlayerPath $player -ConfigDirectory $Explicit -BackupRoot $backup -PackageRoot $package -ExpectedPlanToken $Token -Apply }
function CleanPlan { Get-CleanInstallPlan -PlayerPath $player -PackageRoot $package }
function Expect-Stale($Preview, [scriptblock]$Mutation, [string]$Explicit = '') {
    & $Mutation
    $before = Snapshot $CaseRoot
    Refused { Apply $Explicit $Preview.planToken }
    Assert ((Snapshot $CaseRoot) -ceq $before) 'Stale plan changed fixture bytes or directories'
}
switch ($Case) {
    'appdata-preview' {
        $gui = CleanPlan; $cli = Preview
        Assert ($gui.target -ieq $appdataTarget -and $cli.target -ieq $gui.target) 'AppData resolution differs'
        Assert ($cli.targetSource -eq 'appdata') 'Missing source'
        Assert (-not (Test-Path $appdataTarget) -and -not (Test-Path $backup)) 'Preview wrote directories'
        Assert ($cli.planToken -ceq (Preview).planToken) 'Plan is nondeterministic'
    }
    'home-priority' {
        [void](New-Dir $portable); $env:MPVNET_HOME = New-Dir $target
        Assert ((CleanPlan).target -ieq $target -and (Preview).target -ieq $target) 'HOME priority differs'
    }
    'missing-home-portable' {
        [void](New-Dir $portable); $env:MPVNET_HOME = Join-Path $CaseRoot 'missing-home'
        Assert ((CleanPlan).target -ieq $portable -and (Preview).target -ieq $portable) 'Portable resolution differs'
        Assert (-not (Test-Path $env:MPVNET_HOME)) 'Missing HOME was created'
    }
    'explicit-direct-and-restore' {
        [void](New-Dir $target); Put (Join-Path $target 'unknown.txt') 'keep'; Put (Join-Path $target 'mpvnet-user.json') '{ "schema":1, "future":7 }'
        $before = Snapshot $target
        $p = Preview $target
        Assert ($p.targetSource -eq 'explicit') 'Explicit source missing'
        $installed = Apply $target
        Assert ($installed.mode -eq 'applied') 'Direct explicit apply failed'
        $restored = Invoke-KitRestore -BackupManifest $installed.backupManifest -Apply
        Assert ($restored.mode -eq 'applied') 'Restore failed'
        Assert ((Get-Content (Join-Path $target 'unknown.txt') -Raw) -ceq 'keep') 'Unknown file changed'
        Assert ((Get-Content (Join-Path $target 'mpvnet-user.json') -Raw) -ceq '{ "schema":1, "future":7 }') 'User JSON changed'
        Assert (-not (Test-Path (Join-Path $target '.mpvnet-kit-install.json'))) 'Receipt not removed'
        Assert (-not (Test-Path (Join-Path $target 'mpv.conf'))) 'New runtime not removed'
    }
    'auto-token-required' {
        $before = Snapshot $CaseRoot
        Refused { Apply }
        Assert ((Snapshot $CaseRoot) -ceq $before) 'Missing token wrote files'
    }
    'auto-apply' {
        $p = Preview; $r = Apply '' $p.planToken
        Assert ($r.mode -eq 'applied' -and $r.target -ieq $appdataTarget) 'Confirmed automatic install failed'
        Assert (-not (Test-Path $portable)) 'Unwanted portable directory created'
    }
    'source-switch' { $p = Preview; Expect-Stale $p { [void](New-Dir $portable) } }
    'environment-switch' { $p = Preview; Expect-Stale $p { $env:MPVNET_HOME = New-Dir $target } }
    'identity-switch' {
        [void](New-Dir $target); $p = Preview $target
        Expect-Stale $p { Move-Item -LiteralPath $target -Destination ($target + '.original'); [void](New-Dir $target) } $target
    }
    'ancestor-switch' {
        $parent = New-Dir (Join-Path $CaseRoot 'parent'); $target = Join-Path $parent 'missing/target'; $p = Preview $target
        Expect-Stale $p { Move-Item -LiteralPath $parent -Destination ($parent + '.original'); [void](New-Dir $parent) } $target
    }
    'target-appeared' { $p = Preview $target; Expect-Stale $p { [void](New-Dir $target) } $target }
    'package-changed' {
        $p = Preview $target
        Expect-Stale $p { $package = Package 'package-next' 'fixture-2' @{ 'mpv.conf' = 'fixture=2'; 'scripts/sample.lua' = '-- fixture' }; $script:package = $package } $target
    }
    'runtime-changed' {
        [void](New-Dir $target); Put (Join-Path $target 'mpv.conf') 'old'; $p = Preview $target
        Expect-Stale $p { Put (Join-Path $target 'mpv.conf') 'external edit' } $target
    }
    'user-state-excluded' {
        [void](New-Dir $target); $p = Preview $target
        Put (Join-Path $target 'mpvnet-user.json') '{ "future": 8 }'
        Assert ($p.planToken -ceq (Preview $target).planToken) 'User state polluted token'
        $r = Apply $target $p.planToken
        Assert ((Get-Content (Join-Path $target 'mpvnet-user.json') -Raw) -ceq '{ "future": 8 }') 'User state overwritten'
    }
    'unsafe-candidates' {
        Put $target 'not a directory'; $env:MPVNET_HOME = $target
        Refused { Preview }; Refused { CleanPlan }
        $env:MPVNET_HOME = ''; Put $portable 'not a directory'
        Refused { Preview }; Refused { CleanPlan }
        Assert (-not (Test-Path $appdataTarget)) 'Unsafe candidate fell back'
    }
    'unsafe-roots-overlap' {
        Refused { Preview ([IO.Path]::GetPathRoot($CaseRoot)) }
        Refused { Preview $package }
        Refused { Preview ([IO.Path]::GetDirectoryName($player)) }
        Refused { Preview $backup }
    }
    'junction' {
        [void](New-Dir $target)
        [void](New-Item -ItemType Junction -Path $portable -Target $target)
        Refused { Preview }; Refused { CleanPlan }
        Assert ((Snapshot $target) -ceq '') 'Junction target changed'
    }
    'live-directory-lock' {
        $parent = New-Dir (Join-Path $CaseRoot 'parent')
        $target = Join-Path $parent 'missing/target'; $p = Preview $target
        $locks = @{}
        try {
            Add-KitExistingDirectoryLocks $target $locks
            Refused { [IO.Directory]::Move($parent, ($parent + '.moved')) }
            Assert (Test-Path -LiteralPath $parent) 'Locked parent renamed'
        } finally { foreach ($handle in $locks.Values) { $handle.Dispose() } }
        [IO.Directory]::Move($parent, ($parent + '.moved')); [void](New-Dir $parent)
        $before = Snapshot $CaseRoot
        Refused { Apply $target $p.planToken }
        Assert ((Snapshot $CaseRoot) -ceq $before) 'Replaced unlocked parent accepted stale plan'
    }
    'gui-stale-source' {
        $p = CleanPlan; [void](New-Dir $portable); $before = Snapshot $CaseRoot
        Refused { Invoke-CleanInstall -Plan $p }
        Assert ((Snapshot $CaseRoot) -ceq $before) 'GUI stale source wrote'
    }
    'gui-stale-ancestor' {
        $p = CleanPlan
        Move-Item -LiteralPath $roaming -Destination ($roaming + '.original'); [void](New-Dir $roaming)
        $before = Snapshot $CaseRoot
        Refused { Invoke-CleanInstall -Plan $p }
        Assert ((Snapshot $CaseRoot) -ceq $before) 'GUI stale ancestor wrote'
    }
    'gui-preserve-and-failure' {
        $env:MPVNET_HOME = New-Dir $target
        Put (Join-Path $target 'mpvnet-user.json') '{ "future": 9 }'; Put (Join-Path $target 'cache/opaque') 'history fixture'
        $p = CleanPlan
        & $clean {
            $script:OriginalWriter = (Get-Command Write-CleanFile).ScriptBlock; $script:WriteCount = 0
            Set-Item Function:script:Write-CleanFile {
                param($Item, $OwnedFiles)
                & $script:OriginalWriter $Item $OwnedFiles
                $script:WriteCount++
                if ($script:WriteCount -eq 1) { throw 'Injected fixture failure' }
            }
        }
        Refused { Invoke-CleanInstall -Plan $p } 'Injected fixture failure'
        Assert ((Get-Content (Join-Path $target 'mpvnet-user.json') -Raw) -ceq '{ "future": 9 }') 'GUI cleanup changed user state'
        Assert ((Get-Content (Join-Path $target 'cache/opaque') -Raw) -ceq 'history fixture') 'GUI cleanup changed cache'
        Assert (-not (Test-Path (Join-Path $target 'mpv.conf'))) 'GUI cleanup left owned runtime'
        Put (Join-Path $target 'unknown.txt') 'keep'
        Refused { CleanPlan } 'unknown.txt'
    }
    default { throw "Unknown case: $Case" }
}
[Console]::WriteLine((@{ case = $Case; passed = $true; playerLaunched = $false } | ConvertTo-Json -Compress))
