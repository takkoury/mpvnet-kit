param([string]$SourceRoot, [string]$PackageRoot, [string]$FixtureRoot)
$ErrorActionPreference = 'Stop'
if (-not [IO.Path]::IsPathRooted($FixtureRoot) -or (Test-Path -LiteralPath $FixtureRoot)) { throw 'A new absolute fixture directory is required.' }
[void][IO.Directory]::CreateDirectory($FixtureRoot)
$script:fixtureRoot = $FixtureRoot
$script:fixtureTarget = Join-Path $FixtureRoot '配置 空格/长路径用于检查换行与完整选择/portable_config'
[void][IO.Directory]::CreateDirectory($script:fixtureTarget)
$script:fixturePlayer = Join-Path $FixtureRoot 'mpvnet.exe'
[IO.File]::WriteAllText($script:fixturePlayer, 'Fixture only; never execute.')
$env:MPVNET_HOME = $script:fixtureTarget
$script:fixtureChecks = New-Object 'System.Collections.Generic.List[string]'
$script:fixtureError = ''; $script:fixtureStage = 0; $script:fixtureTicks = 0
function Assert-Fixture($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
# Only modal answers are simulated. No external input injection or UI Automation is used.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
public static class FixtureMessageBox {
    public static System.Windows.Forms.DialogResult Answer = System.Windows.Forms.DialogResult.No;
    public static int Confirmations;
    public static System.Windows.Forms.DialogResult Show(params object[] args) {
        if (args.Length > 3 && args[3].ToString() == "YesNo") { Confirmations++; return Answer; }
        if (args.Length > 3 && args[3].ToString() == "OKCancel") {
            Confirmations++;
            return Answer == System.Windows.Forms.DialogResult.Yes ? System.Windows.Forms.DialogResult.OK : System.Windows.Forms.DialogResult.Cancel;
        }
        return System.Windows.Forms.DialogResult.OK;
    }
}
'@
$source = [IO.File]::ReadAllText((Join-Path $SourceRoot 'tools/installer.ps1'))
$source = $source.Replace('[Windows.Forms.MessageBox]::Show', '[FixtureMessageBox]::Show')
# Keep this isolated event fixture independent of any real user playback.
$source = $source.Replace('Import-Module $Module -Force', 'Import-Module $Module -Force; & (Get-Module maintenance) { Set-Item Function:script:Get-MaintenanceRunningPlayers { @() } }')
$hook = @'
    $script:fixtureTimer = New-Object Windows.Forms.Timer
    $script:fixtureTimer.Interval = 100
    $script:fixtureTimer.Add_Tick({
        try {
            $script:fixtureTicks++
            if ($script:fixtureError) {
                if (-not $script:busy) { $script:fixtureTimer.Stop(); $script:form.Close() }
                return
            }
            if ($script:fixtureTicks -gt 600) { throw 'Timed out waiting for native installer state.' }
            if ($script:busy) { return }
            $SnapshotPath = Join-Path $script:fixtureRoot ("stage-$($script:fixtureStage).png")
            $script:snapshotTaken = $false
            switch ($script:fixtureStage) {
                0 {
                    Assert-Fixture ([MpvnetInstallerDpi]::GetAwarenessFromDpiAwarenessContext([MpvnetInstallerDpi]::GetWindowDpiAwarenessContext($script:form.Handle)) -eq 1) 'Installer is not system DPI aware'
                    $area = [Windows.Forms.Screen]::FromControl($script:form).WorkingArea
                    Assert-Fixture ($script:form.Width -le $area.Width -and $script:form.Height -le $area.Height) 'Initial window exceeds working area'
                    Assert-Fixture ($script:resultState -eq 'idle' -and -not $script:installButton.Enabled -and -not $script:recheckButton.Enabled) 'Initial controls not disabled'
                    Save-InstallerSnapshot
                    $script:fixtureChecks.Add('initial DPI awareness and scaled metrics, disabled apply/recheck, native form snapshot')
                    $script:playerBox.Text = $script:fixturePlayer
                    Start-AutomaticCheck; $script:fixtureStage++
                }
                1 {
                    Assert-Fixture ($script:resultState -eq 'ready' -and $script:installButton.Enabled -and $script:recheckButton.Enabled) 'Ready state missing'
                    Assert-Fixture ($script:targetBox.Text -eq $script:fixtureTarget.Replace('/', '\') -and $script:targetBox.ReadOnly -and $script:targetBox.Multiline -and $script:targetBox.WordWrap) 'Full selectable target missing'
                    Save-InstallerSnapshot
                    $script:detailsButton.PerformClick()
                    Assert-Fixture ($script:logBox.Visible -and $script:detailsExpanded) 'Details did not expand'
                    $SnapshotPath = Join-Path $script:fixtureRoot 'details.png'; $script:snapshotTaken = $false; Save-InstallerSnapshot
                    $script:detailsButton.PerformClick()
                    Assert-Fixture (-not $script:logBox.Visible) 'Details did not collapse'
                    $script:fixtureChecks.Add('ready target, details expand/collapse using real button handlers')
                    $script:installButton.PerformClick()
                    Assert-Fixture (-not $script:busy -and -not $script:installed -and [FixtureMessageBox]::Confirmations -eq 1) 'Simulated No did not cancel'
                    [IO.File]::WriteAllText((Join-Path $script:fixtureTarget 'unknown.txt'), 'preserve unknown fixture')
                    $script:recheckButton.PerformClick(); $script:fixtureStage++
                }
                2 {
                    Assert-Fixture ($script:resultState -eq 'blocked' -and -not $script:installButton.Enabled -and $script:recheckButton.Enabled) 'Unknown file did not block GUI'
                    Assert-Fixture ($script:detailsExpanded -and $script:playerBox.Text -eq $script:fixturePlayer) 'Blocked state lost details/player'
                    $script:form.Size = $script:form.MinimumSize
                    Save-InstallerSnapshot
                    $script:fixtureChecks.Add('unknown refusal, preserved selection, minimum window, disabled apply')
                    [IO.File]::Move((Join-Path $script:fixtureTarget 'unknown.txt'), (Join-Path $script:fixtureRoot 'preserved-unknown.txt'))
                    $script:recheckButton.PerformClick(); $script:fixtureStage++
                }
                3 {
                    Assert-Fixture ($script:resultState -eq 'ready') 'Recheck did not recover'
                    $env:MPVNET_HOME = Join-Path $script:fixtureRoot 'other-target'
                    [void][IO.Directory]::CreateDirectory($env:MPVNET_HOME)
                    [FixtureMessageBox]::Answer = [Windows.Forms.DialogResult]::Yes
                    $script:installButton.PerformClick(); $script:fixtureStage++
                }
                4 {
                    Assert-Fixture ($script:resultState -eq 'blocked' -and $null -eq $script:plan) 'Stale target did not invalidate GUI plan'
                    Assert-Fixture (@([IO.Directory]::EnumerateFileSystemEntries($script:fixtureTarget)).Count -eq 0 -and @([IO.Directory]::EnumerateFileSystemEntries($env:MPVNET_HOME)).Count -eq 0) 'Stale GUI target wrote files'
                    Save-InstallerSnapshot
                    $script:fixtureChecks.Add('changed environment refused through install handler; both targets untouched')
                    $env:MPVNET_HOME = $script:fixtureTarget
                    $script:recheckButton.PerformClick(); $script:fixtureStage++
                }
                5 {
                    Assert-Fixture ($script:resultState -eq 'ready') 'Final recheck not ready'
                    $script:installButton.PerformClick(); $script:fixtureStage++
                }
                6 {
                    Assert-Fixture ($script:installed -and -not $script:installButton.Enabled -and $script:recheckButton.Enabled -and $script:playerBrowse.Enabled -and $script:restoreButton.Enabled) 'Completion controls invalid'
                    Assert-Fixture ($script:plan.action -eq 'current' -and $script:plan.canRestore) 'Completion did not refresh restore state'
                    Save-InstallerSnapshot
                    $script:fixtureChecks.Add('confirmed install handler, actual isolated install, completed controls')
                    $script:restoreButton.PerformClick(); $script:fixtureStage++
                }
                7 {
                    Assert-Fixture (-not $script:plan.canRestore -and $script:plan.action -eq 'install' -and $script:installButton.Enabled -and -not $script:restoreButton.Enabled) 'Restore did not refresh install state'
                    Assert-Fixture (@([IO.Directory]::EnumerateFiles($script:fixtureTarget, '*', [IO.SearchOption]::AllDirectories)).Count -eq 0) 'New install rollback left files in target'
                    Save-InstallerSnapshot
                    $script:fixtureChecks.Add('restore confirmation handler, real rollback, preserved completion result and refreshed actions')
                    $script:fixtureTimer.Stop(); $script:form.Close()
                }
            }
        } catch {
            $script:fixtureError = $_.Exception.ToString()
            if (-not $script:busy) { $script:fixtureTimer.Stop(); $script:form.Close() }
        }
    })
    $script:fixtureTimer.Start()
'@
$needle = '    try { [void]$script:form.ShowDialog() }'
if (-not $source.Contains($needle)) { throw 'Installer test hook missing; review harness against source.' }
$source = $source.Replace($needle, $hook + "`n" + $needle)
# Supply source directory because ScriptBlock.Create has no file-backed PSScriptRoot.
$source = $source.Replace('$PSScriptRoot', ("'" + (Join-Path $SourceRoot 'tools').Replace("'", "''") + "'"))
& ([scriptblock]::Create($source)) -PackageRoot $PackageRoot -BackupRoot (Join-Path $FixtureRoot 'backups')
if ($script:fixtureTimer) { $script:fixtureTimer.Dispose() }
$report = [ordered]@{ checks = $script:fixtureChecks.ToArray(); error = $script:fixtureError; confirmation = 'simulated native dialog answers (Yes/No or OK/Cancel)'; input = 'in-process native control events; no physical input'; source = (Join-Path $SourceRoot 'tools/installer.ps1') }
[IO.File]::WriteAllText((Join-Path $FixtureRoot 'result.json'), ($report | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
if ($script:fixtureError) { throw $script:fixtureError }
Write-Output ($report | ConvertTo-Json -Depth 8)
