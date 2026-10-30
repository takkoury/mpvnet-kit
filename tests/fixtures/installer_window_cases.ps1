param([string]$SourceRoot, [string]$PackageRoot, [string]$FixtureRoot, [switch]$NoShow, [string]$UpgradeFrom)
$ErrorActionPreference = 'Stop'
if (-not [IO.Path]::IsPathRooted($FixtureRoot) -or (Test-Path -LiteralPath $FixtureRoot)) { throw 'A new absolute fixture directory is required.' }
[void][IO.Directory]::CreateDirectory($FixtureRoot)
$script:fixtureRoot = $FixtureRoot
$script:fixtureTarget = Join-Path $FixtureRoot '配置 空格/长路径用于检查换行与完整选择/portable_config'
[void][IO.Directory]::CreateDirectory($script:fixtureTarget)
$script:fixturePlayer = Join-Path $FixtureRoot 'mpvnet.exe'
[IO.File]::WriteAllText($script:fixturePlayer, 'Fixture only; never execute.')
$env:MPVNET_HOME = $script:fixtureTarget
function Get-FixtureFingerprint {
    $items=Get-ChildItem -LiteralPath $script:fixtureTarget -File -Recurse | Sort-Object FullName
    return (@($items|ForEach-Object {$_.FullName.Substring($script:fixtureTarget.Length)+':'+(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}) -join "`n")
}
if($UpgradeFrom) {
    Import-Module (Join-Path $SourceRoot 'tools/maintenance.psm1') -Force
    & (Get-Module maintenance) {Set-Item Function:script:Get-MaintenanceRunningPlayers {@()}}
    [IO.File]::WriteAllText((Join-Path $script:fixtureTarget 'mpvnet-user.json'),' {"schema":1,"shortcuts":{},"settings":{"sub-scale":1.2},"future":{"keep":true}} ')
    $seed=@{PlayerPath=$script:fixturePlayer;PackageRoot=$UpgradeFrom;BackupRoot=(Join-Path $FixtureRoot 'backups')}
    $seedPlan=Get-KitMaintenancePlan @seed
    [void](Invoke-KitMaintenance @seed -Operation Apply -ExpectedPlanToken $seedPlan.planToken)
    $script:upgradeBaseline=Get-FixtureFingerprint
}
$script:fixtureChecks = New-Object 'System.Collections.Generic.List[string]'
$script:fixtureError = ''; $script:fixtureStage = 0; $script:fixtureTicks = 0
function Assert-Fixture($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
# Only modal answers are simulated. No external input injection or UI Automation is used.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
public static class FixtureMessageBox {
    public static System.Windows.Forms.DialogResult Answer = System.Windows.Forms.DialogResult.No;
    public static int Confirmations;
    public static bool Hidden;
    public static bool DefaultCancel = true;
    public static string LastMessage = "";
    public static bool ClosingCancelled(System.Windows.Forms.Form owner) {
        var args=new System.Windows.Forms.FormClosingEventArgs(System.Windows.Forms.CloseReason.UserClosing,false);
        typeof(System.Windows.Forms.Form).GetMethod("OnFormClosing",System.Reflection.BindingFlags.Instance|System.Reflection.BindingFlags.NonPublic).Invoke(owner,new object[]{args});
        return args.Cancel;
    }
    public static System.Windows.Forms.DialogResult ShowConfirmation(object value, System.Windows.Forms.Form owner) {
        Confirmations++;
        var dialog=(System.Windows.Forms.Form)value;
        var type=value.GetType();
        var cancel=(System.Windows.Forms.Button)type.GetField("CancelAction").GetValue(value);
        var accept=(System.Windows.Forms.Button)type.GetField("ConfirmButton").GetValue(value);
        LastMessage=((System.Windows.Forms.TextBox)type.GetField("MessageText").GetValue(value)).Text;
        DefaultCancel &= object.ReferenceEquals(dialog.AcceptButton,cancel) && object.ReferenceEquals(dialog.CancelButton,cancel);
        var button=Answer==System.Windows.Forms.DialogResult.Yes ? accept : cancel;
        if(Hidden) {
            dialog.PerformLayout();
            typeof(System.Windows.Forms.Button).GetMethod("OnClick",System.Reflection.BindingFlags.Instance|System.Reflection.BindingFlags.NonPublic).Invoke(button,new object[]{System.EventArgs.Empty});
            return dialog.DialogResult;
        }
        using(var timer=new System.Windows.Forms.Timer()) {
            timer.Interval=50;timer.Tick+=delegate {timer.Stop();button.PerformClick();};timer.Start();
            return dialog.ShowDialog(owner);
        }
    }
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
[FixtureMessageBox]::Hidden = [bool]$NoShow
function Invoke-FixtureClick([Windows.Forms.Button]$Button) {
    $method=[Windows.Forms.Button].GetMethod('OnClick',[Reflection.BindingFlags]'Instance,NonPublic')
    [void]$method.Invoke($Button,@([EventArgs]::Empty))
}
$script:visibleState=[Windows.Forms.Control].GetMethod('GetState',[Reflection.BindingFlags]'Instance,NonPublic')
function Paint-FixtureControl($Control,$Bitmap,$Window,[Drawing.Rectangle]$Clip) {
    if($Control -ne $Window -and -not $script:visibleState.Invoke($Control,@(2))){return}
    if($Control.Width -lt 1 -or $Control.Height -lt 1){return}
    $Control.PerformLayout();[void]$Control.Handle
    $point=if($Control -eq $Window){[Drawing.Point]::Empty}else{$Window.PointToClient($Control.Parent.PointToScreen($Control.Location))}
    $surface=New-Object Drawing.Bitmap($Control.Width,$Control.Height)
    try {
        $Control.DrawToBitmap($surface,(New-Object Drawing.Rectangle(0,0,$Control.Width,$Control.Height)))
        $graphics=[Drawing.Graphics]::FromImage($Bitmap)
        try {$graphics.SetClip($Clip);$graphics.DrawImageUnscaled($surface,$point)}finally{$graphics.Dispose()}
    } finally {$surface.Dispose()}
    $client=$Window.PointToClient($Control.PointToScreen([Drawing.Point]::Empty))
    $childClip=[Drawing.Rectangle]::Intersect($Clip,(New-Object Drawing.Rectangle($client,$Control.ClientSize)))
    for($i=$Control.Controls.Count-1;$i -ge 0;$i--){Paint-FixtureControl $Control.Controls[$i] $Bitmap $Window $childClip}
}
function Paint-FixtureWindow($Window,$Bitmap) {
    # Native children may be lazily created while their root remains hidden.
    function Prepare-FixtureControl($Control) {
        [void]$Control.Handle
        foreach($child in $Control.Controls){Prepare-FixtureControl $child}
        $Control.PerformLayout()
    }
    Prepare-FixtureControl $Window
    Paint-FixtureControl $Window $Bitmap $Window (New-Object Drawing.Rectangle(0,0,$Bitmap.Width,$Bitmap.Height))
}
function Show-FixtureConfirmation($Dialog,$Owner) {
    if(-not $script:confirmationGuardChecked) {
        $script:confirmationGuardChecked=$true
        Assert-Fixture ($script:confirming -and -not $script:playerBrowse.Enabled -and -not $script:recheckButton.Enabled -and -not $script:installButton.Enabled) 'Owner actions enabled during confirmation'
        $before=[FixtureMessageBox]::Confirmations
        Invoke-FixtureClick $script:installButton
        Assert-Fixture ([FixtureMessageBox]::Confirmations -eq $before -and -not $script:busy) 'Repeated confirmation was not blocked'
        Assert-Fixture ([FixtureMessageBox]::ClosingCancelled($Owner)) 'Owner closed during confirmation'
    }
    if($NoShow) {
        $Dialog.Owner=$Owner;[void]$Dialog.Handle;$Dialog.PerformLayout()
        $bitmap=New-Object Drawing.Bitmap($Dialog.Width,$Dialog.Height)
        try {
            Paint-FixtureWindow $Dialog $bitmap
            $bitmap.Save((Join-Path $script:fixtureRoot ('confirm-'+[FixtureMessageBox]::Confirmations+'.png')),[Drawing.Imaging.ImageFormat]::Png)
        }finally{$bitmap.Dispose()}
    }
    return [FixtureMessageBox]::ShowConfirmation($Dialog,$Owner)
}
$source = [IO.File]::ReadAllText((Join-Path $SourceRoot 'tools/installer.ps1'))
$source = $source.Replace('[Windows.Forms.MessageBox]::Show', '[FixtureMessageBox]::Show')
$source = $source.Replace('$confirmation.ShowDialog($script:form)', '(Show-FixtureConfirmation $confirmation $script:form)')
if($NoShow) {
    $source=$source.Replace('$script:form.DrawToBitmap($bitmap, (New-Object Drawing.Rectangle(0, 0, $script:form.Width, $script:form.Height)))','Paint-FixtureWindow $script:form $bitmap')
}
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
            if($UpgradeFrom) {
                switch($script:fixtureStage) {
                    0 {$script:playerBox.Text=$script:fixturePlayer;Start-AutomaticCheck;$script:fixtureStage++}
                    1 {
                        Assert-Fixture ($script:plan.action -eq 'update' -and $script:installButton.Enabled) 'Upgrade state missing'
                        Save-InstallerSnapshot
                        [FixtureMessageBox]::Answer=[Windows.Forms.DialogResult]::No
                        Invoke-FixtureClick $script:installButton
                        Assert-Fixture (-not $script:busy -and (Get-FixtureFingerprint) -ceq $script:upgradeBaseline) 'Update cancel wrote files'
                        if($script:plan.releaseNotice){Assert-Fixture ([FixtureMessageBox]::LastMessage.Replace("`r`n","`n").Contains($script:plan.releaseNotice.Replace("`r`n","`n"))) 'Upgrade notice missing from confirmation'}
                        [FixtureMessageBox]::Answer=[Windows.Forms.DialogResult]::Yes
                        Invoke-FixtureClick $script:installButton;$script:fixtureStage++
                        $script:fixtureChecks.Add('update confirmation contains release notice, cancel preserves all files, real apply started')
                    }
                    2 {
                        Assert-Fixture ($script:plan.canRestore -and $script:plan.restoreKind -eq 'restore-version') 'Update restore state missing'
                        Assert-Fixture ((Get-FixtureFingerprint) -cne $script:upgradeBaseline) 'Update did not change runtime files'
                        Save-InstallerSnapshot
                        $beforeRestore=Get-FixtureFingerprint
                        [FixtureMessageBox]::Answer=[Windows.Forms.DialogResult]::No
                        Invoke-FixtureClick $script:restoreButton
                        Assert-Fixture (-not $script:busy -and (Get-FixtureFingerprint) -ceq $beforeRestore) 'Restore cancel wrote files'
                        [FixtureMessageBox]::Answer=[Windows.Forms.DialogResult]::Yes
                        Invoke-FixtureClick $script:restoreButton;$script:fixtureStage++
                    }
                    3 {
                        Assert-Fixture ((Get-FixtureFingerprint) -ceq $script:upgradeBaseline) 'Restore did not recover exact old runtime, receipt and user JSON'
                        Save-InstallerSnapshot
                        $script:fixtureChecks.Add('restore confirmation cancel, real restore to old package, exact receipt and raw user JSON preserved')
                        $script:fixtureTimer.Stop();$script:form.Close()
                    }
                }
                return
            }
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
                    Invoke-FixtureClick $script:detailsButton
                    Assert-Fixture (($NoShow -or $script:logBox.Visible) -and $script:detailsExpanded) 'Details did not expand'
                    $SnapshotPath = Join-Path $script:fixtureRoot 'details.png'; $script:snapshotTaken = $false; Save-InstallerSnapshot
                    Invoke-FixtureClick $script:detailsButton
                    Assert-Fixture (-not $script:logBox.Visible) 'Details did not collapse'
                    $script:fixtureChecks.Add('ready target, details expand/collapse using real button handlers')
                    Invoke-FixtureClick $script:installButton
                    Assert-Fixture (-not $script:busy -and -not $script:installed -and [FixtureMessageBox]::Confirmations -eq 1) 'Simulated No did not cancel'
                    Assert-Fixture ([FixtureMessageBox]::DefaultCancel -and [FixtureMessageBox]::LastMessage.Contains($script:fixturePlayer)) 'Real confirmation lost default cancel or complete path'
                    [IO.File]::WriteAllText((Join-Path $script:fixtureTarget 'unknown.txt'), 'preserve unknown fixture')
                    Invoke-FixtureClick $script:recheckButton; $script:fixtureStage++
                }
                2 {
                    Assert-Fixture ($script:resultState -eq 'blocked' -and -not $script:installButton.Enabled -and $script:recheckButton.Enabled) 'Unknown file did not block GUI'
                    Assert-Fixture ($script:detailsExpanded -and $script:playerBox.Text -eq $script:fixturePlayer) 'Blocked state lost details/player'
                    $script:form.Size = $script:form.MinimumSize
                    Save-InstallerSnapshot
                    $script:fixtureChecks.Add('unknown refusal, preserved selection, minimum window, disabled apply')
                    [IO.File]::Move((Join-Path $script:fixtureTarget 'unknown.txt'), (Join-Path $script:fixtureRoot 'preserved-unknown.txt'))
                    Invoke-FixtureClick $script:recheckButton; $script:fixtureStage++
                }
                3 {
                    Assert-Fixture ($script:resultState -eq 'ready') 'Recheck did not recover'
                    $env:MPVNET_HOME = Join-Path $script:fixtureRoot 'other-target'
                    [void][IO.Directory]::CreateDirectory($env:MPVNET_HOME)
                    [FixtureMessageBox]::Answer = [Windows.Forms.DialogResult]::Yes
                    Invoke-FixtureClick $script:installButton; $script:fixtureStage++
                }
                4 {
                    Assert-Fixture ($script:resultState -eq 'blocked' -and $null -eq $script:plan) 'Stale target did not invalidate GUI plan'
                    Assert-Fixture (@([IO.Directory]::EnumerateFileSystemEntries($script:fixtureTarget)).Count -eq 0 -and @([IO.Directory]::EnumerateFileSystemEntries($env:MPVNET_HOME)).Count -eq 0) 'Stale GUI target wrote files'
                    Save-InstallerSnapshot
                    $script:fixtureChecks.Add('changed environment refused through install handler; both targets untouched')
                    $env:MPVNET_HOME = $script:fixtureTarget
                    Invoke-FixtureClick $script:recheckButton; $script:fixtureStage++
                }
                5 {
                    Assert-Fixture ($script:resultState -eq 'ready') 'Final recheck not ready'
                    Invoke-FixtureClick $script:installButton; $script:fixtureStage++
                }
                6 {
                    Assert-Fixture ($script:installed -and -not $script:installButton.Enabled -and $script:recheckButton.Enabled -and $script:playerBrowse.Enabled -and $script:restoreButton.Enabled) 'Completion controls invalid'
                    Assert-Fixture ($script:plan.action -eq 'current' -and $script:plan.canRestore) 'Completion did not refresh restore state'
                    Save-InstallerSnapshot
                    $script:fixtureChecks.Add('confirmed install handler, actual isolated install, completed controls')
                    Invoke-FixtureClick $script:restoreButton; $script:fixtureStage++
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
            $script:fixtureUiError = $script:logBox.Text
            if (-not $script:busy) { $script:fixtureTimer.Stop(); $script:form.Close() }
        }
    })
    $script:fixtureTimer.Start()
'@
$needle = '    try { [void]$script:form.ShowDialog() }'
if (-not $source.Contains($needle)) { throw 'Installer test hook missing; review harness against source.' }
$source = $source.Replace($needle, $hook + "`n" + $needle)
if($NoShow) {
    $hiddenRun = @'
    try {
        [void]$script:form.Handle
        $script:fixtureContext = New-Object Windows.Forms.ApplicationContext
        $script:form.Add_FormClosed({ $script:fixtureContext.ExitThread() })
        [Windows.Forms.Application]::Run($script:fixtureContext)
    }
'@
    $source=$source.Replace($needle,$hiddenRun)
}
# Supply source directory because ScriptBlock.Create has no file-backed PSScriptRoot.
$source = $source.Replace('$PSScriptRoot', ("'" + (Join-Path $SourceRoot 'tools').Replace("'", "''") + "'"))
& ([scriptblock]::Create($source)) -PackageRoot $PackageRoot -BackupRoot (Join-Path $FixtureRoot 'backups')
if ($script:fixtureTimer) { $script:fixtureTimer.Dispose() }
if ($script:fixtureContext) { $script:fixtureContext.Dispose() }
$report = [ordered]@{ checks = $script:fixtureChecks.ToArray(); error = $script:fixtureError; uiError=$script:fixtureUiError; noShow=[bool]$NoShow; confirmation = 'real custom confirmation controls with simulated button events'; input = 'in-process control events; no physical input'; source = (Join-Path $SourceRoot 'tools/installer.ps1') }
[IO.File]::WriteAllText((Join-Path $FixtureRoot 'result.json'), ($report | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
if ($script:fixtureError) { throw $script:fixtureError }
Write-Output ($report | ConvertTo-Json -Depth 8)
