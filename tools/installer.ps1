param(
    [string]$PlayerPath = '', [string]$PackageRoot = '',
    [string]$BackupRoot = '', [string]$SnapshotPath = '', [switch]$CloseAfterSnapshot, [switch]$CheckOnStart
)
$ErrorActionPreference = 'Stop'
$previousDpiContext = [IntPtr]::Zero
try {
    # Set only this UI thread before creating any controls; never change powershell.exe.config.
    # System-aware mode matches .NET Framework's startup scaling. Mixed-monitor DPI is not promised.
    if (-not ('MpvnetInstallerDpi' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class MpvnetInstallerDpi {
    [DllImport("user32.dll", SetLastError=true)]
    public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")]
    public static extern IntPtr GetWindowDpiAwarenessContext(IntPtr window);
    [DllImport("user32.dll")]
    public static extern int GetAwarenessFromDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")]
    public static extern uint GetDpiForWindow(IntPtr window);
}
'@
    }
    $previousDpiContext = [MpvnetInstallerDpi]::SetThreadDpiAwarenessContext([IntPtr](-2))
    if ($previousDpiContext -eq [IntPtr]::Zero) { throw '无法启用安装窗口的清晰 DPI 渲染，请使用 Windows 10 1607 或更新系统。' }
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    if (-not ('KitInstallerForm' -as [type])) {
        Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -Path (Join-Path $PSScriptRoot 'installer-ui.cs')
    }
    [Windows.Forms.Application]::EnableVisualStyles()
    $dpiGraphics = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    try { $script:uiScale = $dpiGraphics.DpiX / 96.0 } finally { $dpiGraphics.Dispose() }
    function ConvertTo-InstallerPixels([double]$Value) { return [int][Math]::Round($Value * $script:uiScale) }
    function New-InstallerSize([int]$Width, [int]$Height) {
        return New-Object Drawing.Size((ConvertTo-InstallerPixels $Width), (ConvertTo-InstallerPixels $Height))
    }
    function New-InstallerPadding([int]$Left, [int]$Top = $Left, [int]$Right = $Left, [int]$Bottom = $Top) {
        return New-Object Windows.Forms.Padding((ConvertTo-InstallerPixels $Left), (ConvertTo-InstallerPixels $Top), (ConvertTo-InstallerPixels $Right), (ConvertTo-InstallerPixels $Bottom))
    }
    if (-not $PackageRoot) { $PackageRoot = Split-Path -Parent $PSScriptRoot }
    $script:modulePath = Join-Path $PSScriptRoot 'maintenance.psm1'
    if (-not [IO.File]::Exists($script:modulePath)) { throw '安装器文件不完整，请重新解压完整配置包。' }
    Import-Module $script:modulePath
    $script:portableModulePath = Join-Path $PSScriptRoot 'portable-install.psm1'
    $script:portablePackage = $false
    if ([IO.File]::Exists($script:portableModulePath)) {
        Import-Module $script:portableModulePath
        $script:portablePackage = Test-KitPortablePackage -PackageRoot $PackageRoot
    }
    $script:backupRoot = $BackupRoot; $script:packageRoot = $PackageRoot; $script:plan = $null; $script:worker = $null; $script:runspace = $null
    $script:playerPath = ''; $script:installDirectory = ''; $script:launcherPath = ''
    $script:busy = $false; $script:confirming = $false; $script:installed = $false; $script:snapshotTaken = $false; $script:detailsExpanded = $false
    $script:lastResult = $null; $script:lastOperation = ''; $script:restoreLabel = '还原上次操作'; $script:preserveResult = $false
    $script:target = ''; $script:targetSource = ''; $script:targetExists = $null; $script:dependencies = @(); $script:resultState = 'idle'
    $script:form = New-Object KitInstallerForm([single]$script:uiScale)
    $script:form.SuspendLayout()
    $script:form.Text = if ($script:portablePackage) { 'mpv.net · 安装与更新' } else { 'mpv.net 配置包 · 安装与更新' }
    $script:form.StartPosition = 'CenterScreen'
    $script:form.ClientSize = New-InstallerSize 690 460
    $script:form.MinimumSize = New-InstallerSize 520 440
    $script:form.BackColor = [Drawing.Color]::FromArgb(21, 21, 21)
    $script:form.ForeColor = [Drawing.Color]::FromArgb(242, 242, 242)
    # Fonts use points; scale layout metrics once, avoiding legacy WinForms partial/double autoscaling.
    $script:form.AutoScaleMode = 'None'; $script:form.KeyPreview = $true
    $script:mutedColor = [Drawing.Color]::FromArgb(171, 171, 171)
    function New-Layout([Windows.Forms.Control]$Parent, [int]$Rows) {
        $panel = New-Object Windows.Forms.TableLayoutPanel
        $panel.Dock = 'Fill'; $panel.ColumnCount = 1; $panel.RowCount = $Rows
        $panel.Margin = New-InstallerPadding 0; $panel.TabStop = $false
        [void]$panel.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
        $Parent.Controls.Add($panel); return $panel
    }
    function Add-Row([Windows.Forms.TableLayoutPanel]$Panel, [string]$Type, [single]$Height) {
        if ($Type -eq 'Absolute') { $Height = ConvertTo-InstallerPixels $Height }
        [void]$Panel.RowStyles.Add((New-Object Windows.Forms.RowStyle($Type, $Height)))
    }
    function New-Label([string]$Text) {
        $label = New-Object Windows.Forms.Label
        $label.Text = $Text; $label.Dock = 'Fill'; $label.Margin = New-InstallerPadding 0
        $label.TextAlign = 'MiddleLeft'; $label.TabStop = $false; return $label
    }
    function New-Button([string]$Text, [int]$Width) {
        $button = New-Object KitInstallerButton
        $button.Text = $Text; $button.Size = New-InstallerSize $Width 36
        $button.FlatStyle = 'Flat'; $button.BackColor = [Drawing.Color]::FromArgb(36, 36, 36)
        $button.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(85, 85, 85)
        $button.ForeColor = $script:form.ForeColor; $button.UseVisualStyleBackColor = $false; return $button
    }
    function New-ReadOnlyBox {
        $box = New-Object KitInstallerTextBox
        $box.Dock = 'Fill'; $box.ReadOnly = $true; $box.BorderStyle = 'None'
        $box.BackColor = $script:form.BackColor; $box.ForeColor = $script:form.ForeColor
        $box.Margin = New-InstallerPadding 0; return $box
    }
    # Target, one status and one primary action. Details stay out of the normal path.
    $frame = New-Layout $script:form.ContentHost 2; Add-Row $frame 'Percent' 100; Add-Row $frame 'Absolute' 70
    $scrollHost = New-Object Windows.Forms.Panel
    $scrollHost.Dock = 'Fill'; $scrollHost.Margin = New-InstallerPadding 0
    $frame.Controls.Add($scrollHost, 0, 0)
    $root = New-Layout $scrollHost 7
    $root.Padding = New-InstallerPadding 28 20 28 16
    foreach($height in @(64,64,1,20,106,30)){Add-Row $root 'Absolute' $height}
    Add-Row $root 'Percent' 100
    $playerHost = New-Object Windows.Forms.Panel
    $root.Controls.Add($playerHost, 0, 0); $playerHost.Dock = 'Fill'; $playerHost.Margin = New-InstallerPadding 0 0 0 8
    $playerLayout = New-Layout $playerHost 1; Add-Row $playerLayout 'Percent' 100
    $playerLayout.ColumnCount = 3; $playerLayout.ColumnStyles.Clear()
    [void]$playerLayout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute', (ConvertTo-InstallerPixels 76))))
    [void]$playerLayout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
    [void]$playerLayout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute', (ConvertTo-InstallerPixels 100))))
    $script:playerCaption = New-Label '播放器'; $script:playerCaption.ForeColor=$script:mutedColor; $script:playerCaption.Font=New-Object Drawing.Font('Microsoft YaHei UI',9)
    $script:playerCaption.TextAlign='MiddleLeft'
    $playerLayout.Controls.Add($script:playerCaption, 0, 0)
    function New-PathSurface($Layout,[int]$Column) {
        $surface=New-Object Windows.Forms.Panel
        $surface.Dock='Fill';$surface.Margin=New-InstallerPadding 0;$surface.Padding=New-InstallerPadding 10 8
        $surface.BackColor=[Drawing.Color]::FromArgb(27,27,27);$Layout.Controls.Add($surface,$Column,0)
        return $surface
    }
    function Set-PathBoxBounds($Surface) {
        if(-not $Surface -or $Surface.Tag -eq 'arranging' -or -not $Surface.Controls.Count){return}
        $Surface.Tag='arranging'
        try {
            $box=$Surface.Controls[0]
            $box.Width=[Math]::Max(1,$Surface.ClientSize.Width-$Surface.Padding.Horizontal)
            [void]$box.Handle
            $lineHeight=[Windows.Forms.TextRenderer]::MeasureText('Ag',$box.Font).Height
            if($box.TotalLines -gt 1){
                $first=$box.GetPositionFromCharIndex($box.GetFirstCharIndexFromLine(0)).Y
                $next=$box.GetPositionFromCharIndex($box.GetFirstCharIndexFromLine(1)).Y
                if($next -gt $first){$lineHeight=$next-$first}
            }
            $available=[Math]::Max(1,$Surface.ClientSize.Height-$Surface.Padding.Vertical)
            $rows=[Math]::Max(1,[Math]::Floor($available/$lineHeight))
            $height=[Math]::Min($available,[Math]::Min($box.TotalLines,$rows)*$lineHeight)
            $box.SetBounds($Surface.Padding.Left,[int][Math]::Floor(($Surface.ClientSize.Height-$height)/2),$box.Width,[int]$height)
        } finally {$Surface.Tag=$null}
    }
    function Add-PathBox($Surface,$Box) {
        $Box.Dock='None';$Surface.Controls.Add($Box)
        $Surface.Add_Layout({param($sender,$eventArgs) Set-PathBoxBounds $sender})
        $Box.Add_TextChanged({param($sender,$eventArgs) Set-PathBoxBounds $sender.Parent})
        Set-PathBoxBounds $Surface
    }
    $playerSurface=New-PathSurface $playerLayout 1
    $script:playerBox = New-ReadOnlyBox; $script:playerBox.Multiline = $true; $script:playerBox.WordWrap = $true; $script:playerBox.ScrollBars='Vertical'
    $script:playerBox.Font=New-Object Drawing.Font('Microsoft YaHei UI',9); $script:playerBox.ForeColor=[Drawing.Color]::FromArgb(208,208,208);$script:playerBox.BackColor=$playerSurface.BackColor
    $script:playerBox.AccessibleName = '播放器程序路径'; $script:playerBox.TabIndex = 0; Add-PathBox $playerSurface $script:playerBox
    $script:playerBrowse = New-Button '选择…(&B)' 86; $script:playerBrowse.Anchor = 'Right'; $script:playerBrowse.TabIndex = 1
    $script:playerBrowse.Margin = New-InstallerPadding 12 0 0 0; $playerLayout.Controls.Add($script:playerBrowse, 2, 0)
    $targetHost = New-Object Windows.Forms.Panel
    $root.Controls.Add($targetHost, 0, 1); $targetHost.Dock = 'Fill'; $targetHost.Margin = New-InstallerPadding 0 0 0 8
    $targetHost.BackColor = $script:form.BackColor
    $targetLayout = New-Layout $targetHost 1; Add-Row $targetLayout 'Percent' 100
    $targetLayout.ColumnCount=3; $targetLayout.ColumnStyles.Clear()
    [void]$targetLayout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',(ConvertTo-InstallerPixels 76))))
    [void]$targetLayout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',100)))
    [void]$targetLayout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',(ConvertTo-InstallerPixels 100))))
    $script:targetCaption = New-Label '配置目录'; $script:targetCaption.Font = New-Object Drawing.Font('Microsoft YaHei UI',9); $script:targetCaption.ForeColor=$script:mutedColor
    $script:targetCaption.TextAlign='MiddleLeft'
    $targetLayout.Controls.Add($script:targetCaption, 0, 0)
    $targetSurface=New-PathSurface $targetLayout 1
    $script:targetBox = New-ReadOnlyBox; $script:targetBox.Multiline = $true; $script:targetBox.WordWrap = $true; $script:targetBox.ScrollBars = 'Vertical'
    $script:targetBox.Font=New-Object Drawing.Font('Microsoft YaHei UI',9)
    $script:targetBox.ForeColor = [Drawing.Color]::FromArgb(208,208,208); $script:targetBox.BackColor=$targetSurface.BackColor; $script:targetBox.Text = ''
    $script:targetBox.AccessibleName = '配置目录，可选择完整路径'; $script:targetBox.TabIndex = 0; Add-PathBox $targetSurface $script:targetBox
    $script:directoryBrowse = New-Button '新装…(&N)' 94; $script:directoryBrowse.Anchor = 'Right'; $script:directoryBrowse.TabIndex = 1
    $script:directoryBrowse.Margin = New-InstallerPadding 6 0 0 0
    $targetLayout.Controls.Add($script:directoryBrowse, 2, 0)
    # Retain full diagnostics for the details text and snapshots, not extra rows.
    $script:sourceLabel = New-Label ''; $script:nextLabel = New-Label ''; $script:dependencyLabel = New-Label ''
    $separator=New-Object Windows.Forms.Panel; $separator.Dock='Fill';$separator.Margin=New-InstallerPadding 0
    $separator.BackColor=[Drawing.Color]::FromArgb(48,48,48);$root.Controls.Add($separator,0,2)
    $resultHost = New-Object Windows.Forms.Panel
    $root.Controls.Add($resultHost, 0, 4); $resultHost.Dock = 'Fill'; $resultHost.Margin = New-InstallerPadding 0
    $script:resultLayout = New-Layout $resultHost 3
    Add-Row $script:resultLayout 'Absolute' 34; Add-Row $script:resultLayout 'Absolute' 26; Add-Row $script:resultLayout 'Percent' 100
    $idleTitle = if ($script:portablePackage) { '选择安装方式' } else { '先选择播放器' }
    $idleReason = if ($script:portablePackage) { '请选择新装目录，或选择已有的 mpvnet.exe。' } else { '选择你正在使用的 mpvnet.exe。' }
    $script:statusLabel = New-Label $idleTitle; $script:statusLabel.Font = New-Object Drawing.Font('Microsoft YaHei UI',16,[Drawing.FontStyle]::Bold)
    $script:resultLayout.Controls.Add($script:statusLabel, 0, 0)
    $script:summaryLabel = New-Label ''; $script:summaryLabel.ForeColor = $script:mutedColor
    $script:summaryLabel.Font=New-Object Drawing.Font('Microsoft YaHei UI',9.75);$script:resultLayout.Controls.Add($script:summaryLabel,0,1)
    $script:reasonLabel = New-Label $idleReason
    $script:reasonLabel.ForeColor=$script:mutedColor;$script:reasonLabel.Font=New-Object Drawing.Font('Microsoft YaHei UI',9.75)
    $script:reasonLabel.AutoEllipsis = $false; $script:resultLayout.Controls.Add($script:reasonLabel, 0, 2)
    $script:detailsButton = New-Button '查看详情' 92; $script:detailsButton.Subtle=$true; $script:detailsButton.Disclosure=$true
    $script:detailsButton.Font=New-Object Drawing.Font('Microsoft YaHei UI',9)
    $script:detailsButton.Anchor = 'Left'; $script:detailsButton.Height = ConvertTo-InstallerPixels 28
    $script:detailsButton.Margin = New-InstallerPadding 0 2 0 2; $script:detailsButton.TabIndex = 0
    $root.Controls.Add($script:detailsButton, 0, 5)
    $script:logBox = New-ReadOnlyBox; $script:logBox.Multiline = $true; $script:logBox.WordWrap = $true; $script:logBox.ScrollBars = 'Vertical'
    $script:logBox.BackColor = [Drawing.Color]::FromArgb(27, 27, 27); $script:logBox.AccessibleName = '完整检查详情'; $script:logBox.TabIndex = 1; $script:logBox.Visible = $false
    $script:logBox.Text = '选择播放器后显示文件变更、备份位置及无法继续的具体原因。'
    $root.Controls.Add($script:logBox, 0, 6)
    $footer = New-Object Windows.Forms.Panel
    $footer.Dock = 'Fill';$footer.Margin = New-InstallerPadding 0;$frame.Controls.Add($footer,0,1)
    $script:installButton = New-Button '选择播放器(&I)' 116; $script:installButton.TabIndex = 2; $script:installButton.Primary = $true
    $script:recheckButton = New-Button '重新检查(&R)' 110; $script:recheckButton.TabIndex = 1;$script:recheckButton.Subtle=$true
    $script:restoreButton = New-Button '还原上次操作(&U)' 156; $script:restoreButton.TabIndex = 0;$script:restoreButton.Subtle=$true
    $footer.Controls.Add($script:installButton); $footer.Controls.Add($script:restoreButton); $footer.Controls.Add($script:recheckButton)
    $footer.Add_Layout({
        $right=$footer.ClientSize.Width-(ConvertTo-InstallerPixels 28)
        $script:installButton.Location=New-Object Drawing.Point(($right-$script:installButton.Width),(ConvertTo-InstallerPixels 16))
        $script:recheckButton.Location=New-Object Drawing.Point(($script:installButton.Left-(ConvertTo-InstallerPixels 8)-$script:recheckButton.Width),(ConvertTo-InstallerPixels 16))
        $script:restoreButton.Location=New-Object Drawing.Point((ConvertTo-InstallerPixels 28),(ConvertTo-InstallerPixels 16))
    })
    $playerHost.TabIndex=0;$targetHost.TabIndex=1;$resultHost.TabIndex=2;$footer.TabIndex=3
    $script:detailsOriginalHeight=0;$script:detailsExpandedHeight=0
    function Set-DetailsExpanded([bool]$Expanded) {
        $previousHeight=$script:form.Height
        $script:detailsExpanded = $Expanded; $script:logBox.Visible = $Expanded
        $available=[Windows.Forms.Screen]::FromControl($script:form).WorkingArea.Height-(ConvertTo-InstallerPixels 16)
        $minimumHeight=[Math]::Min((ConvertTo-InstallerPixels $(if($Expanded){512}else{440})),$available)
        $script:form.MinimumSize=New-Object Drawing.Size($script:form.MinimumSize.Width,$minimumHeight)
        if($Expanded -and $script:form.WindowState -eq 'Normal') {
            $needed=ConvertTo-InstallerPixels 636
            $wanted=[Math]::Min($needed,$available)
            if($previousHeight -lt $wanted){$script:detailsOriginalHeight=$previousHeight;$script:form.Height=$wanted;$script:detailsExpandedHeight=$script:form.Height}
            $area=[Windows.Forms.Screen]::FromControl($script:form).WorkingArea
            $script:form.Top=[Math]::Max($area.Top,[Math]::Min($script:form.Top,$area.Bottom-$script:form.Height))
        } elseif(-not $Expanded -and $script:detailsOriginalHeight -gt 0) {
            if($script:form.WindowState -eq 'Normal' -and $script:form.Height -eq $script:detailsExpandedHeight){$script:form.Height=$script:detailsOriginalHeight}
            $script:detailsOriginalHeight=0
        }
        $script:detailsButton.Expanded = $Expanded
        $script:detailsButton.AccessibleName = if($Expanded){'收起详情'}else{'查看详情'}
    }
    function Set-InstallSelection([string]$Player, [string]$Directory = '', [string]$Launcher = '') {
        $script:playerPath = $Player; $script:installDirectory = $Directory; $script:launcherPath = $Launcher
        if ($Directory) {
            $script:playerCaption.Text = '安装目录'; $script:playerBox.AccessibleName = '播放器安装目录'
            $script:playerBox.Text = $Directory
        } elseif ($Launcher) {
            $script:playerCaption.Text = '启动入口'; $script:playerBox.AccessibleName = '启动入口完整路径'
            $script:playerBox.Text = $Launcher
        } else {
            $script:playerCaption.Text = '播放器'; $script:playerBox.AccessibleName = '播放器程序路径'
            $script:playerBox.Text = $Player
        }
    }
    function Set-InstallerIdle {
        $script:resultState = 'idle'; $script:statusLabel.Text = $idleTitle
        $script:reasonLabel.Text = $idleReason; $script:nextLabel.Text = ''
    }
    function Update-Enabled {
        $available = -not $script:busy -and -not $script:confirming
        $hasSelection = [bool]($script:playerPath -or $script:installDirectory)
        $canApply=$script:plan -and [bool]$script:plan.eligible -and $script:plan.action -in @('install','install-player','update','recover')
        $script:primaryMode=if(-not $hasSelection){if($script:portablePackage){'directory'}else{'browse'}}elseif($script:resultState -in @('current','completed','completed-check-failed')){'finish'}elseif(-not $script:plan -and $script:resultState -eq 'blocked'){'check'}elseif($canApply){'apply'}else{'none'}
        $script:playerBrowse.Enabled = $available
        $script:playerBrowse.Text=if($script:portablePackage){'已有…(&B)'}elseif($hasSelection){'更换(&B)'}else{'选择…(&B)'}
        $script:directoryBrowse.Enabled = $available -and $script:portablePackage
        $script:directoryBrowse.Visible = $script:portablePackage
        $script:directoryBrowse.Text = if ($script:installDirectory) { '换目录(&N)' } else { '新装…(&N)' }
        $targetHost.Visible=$hasSelection -or $script:portablePackage
        $root.RowStyles[1].Height=ConvertTo-InstallerPixels $(if($hasSelection -or $script:portablePackage){64}else{0})
        $script:recheckButton.Enabled = $available -and $hasSelection
        $script:recheckButton.Visible=$hasSelection -and ($script:primaryMode -notin @('check','finish') -or $script:resultState -eq 'completed-check-failed')
        $script:installButton.Enabled = $available -and $script:primaryMode -ne 'none'
        $script:installButton.Text=if($script:busy){'处理中'}else{switch($script:primaryMode){'browse'{'选择播放器(&I)'}'directory'{'新装播放器(&I)'}'finish'{'完成(&I)'}'check'{'重新检查(&I)'}'apply'{switch($script:plan.action){'install'{'安装(&I)'}'install-player'{'安装播放器(&I)'}'update'{'更新(&I)'}'recover'{'恢复配置(&I)'}}}default{'无法继续'}}}
        $script:restoreButton.Enabled = $available -and $null -ne $script:plan -and [bool]$script:plan.canRestore -and [bool]$script:plan.restorePlanToken
        $script:restoreButton.Visible = -not $script:busy -and $script:plan -and [bool]$script:plan.canRestore
        $script:detailsButton.Visible=$hasSelection -and -not $script:busy
        $script:detailsButton.Enabled = $available; $script:form.UseWaitCursor = $script:busy
        $script:resultLayout.RowStyles[1].Height=ConvertTo-InstallerPixels $(if($script:summaryLabel.Text){26}else{0})
        $footer.PerformLayout()
    }
    function Set-Failure([string]$Title, [string]$Detail) {
        $reason = Get-KitMaintenanceReason $Detail
        $displayDetail = if ($reason -ceq $Detail) { $reason } else { $reason + "`r`n`r`n技术详情：`r`n" + $Detail }
        $script:plan = $null; $script:resultState = 'blocked'; $script:statusLabel.Text = $Title
        if (-not $script:target) {
            $script:targetBox.Text = '未能确定配置目录。'; $script:sourceLabel.Text = '来源：未确定  ·  目录状态：未确定'
        }
        $brief=$reason.Replace("`r`n",' ').Replace("`n",' ').Trim()
        $script:reasonLabel.Text = if($brief.Length -le 64){$brief}else{'请查看详情，处理后重新检查。'}
        $script:summaryLabel.Text=''
        $script:nextLabel.Text = '请查看具体原因，处理后重新检查。播放器路径和已有备份将保留。'
        $script:logBox.Text = $displayDetail
        if ($script:preserveResult -and $script:lastResult) {
            $script:resultState = 'completed-check-failed'; $script:statusLabel.Text = $script:lastResult.title
            $script:reasonLabel.Text = $script:lastResult.description + ' 最新检查未完成，请查看详情并重新检查。'
            $script:nextLabel.Text = $script:lastResult.backupText
            $script:summaryLabel.Text = "本次操作：已处理 $($script:lastResult.changedFiles) 个文件。`r`n最新检查：$($plan.reason)"
            $script:logBox.Text = $script:lastResult.description + "`r`n" + $script:lastResult.backupText + "`r`n`r`n最新检查失败：`r`n" + $displayDetail
        }
        if($script:preserveResult -and $script:lastResult){$script:reasonLabel.Text='操作已完成，但重新检查未完成。';$script:summaryLabel.Text=''}
        Set-DetailsExpanded $false
    }
    function Show-Plan($Result) {
        $script:plan = $Result.plan; $script:dependencies = @($Result.tools)
        $plan = $script:plan
        $newPlayer = $plan -and $plan.action -eq 'install-player'
        if ($plan) {
            $script:target = $plan.target; $script:targetSource = $plan.targetSource; $script:targetExists = [bool]$plan.targetExists
            if ($newPlayer -and $plan.launcherPath) {
                $script:targetCaption.Text = '启动入口'; $script:targetBox.AccessibleName = '启动入口完整路径'
                $script:targetBox.Text = $plan.launcherPath
            } else { $script:targetBox.Text = $script:target }
            $existence = if ($script:targetExists) { '目录已存在' } else { '安装时创建目录' }
            $script:sourceLabel.Text = '来源：' + $plan.targetSourceLabel + '  ·  ' + $existence
        } elseif ($Result.resolution) {
            $script:target = $Result.resolution.target; $script:targetSource = $Result.resolution.source; $script:targetExists = [bool]$Result.resolution.targetExists
            $script:targetBox.Text = $script:target; $script:sourceLabel.Text = '来源：' + $Result.resolution.sourceLabel
        }
        $dependencyLines = @(); $missing = @()
        foreach ($tool in $script:dependencies) {
            $state = if ($tool.found) { "PATH 中发现：$($tool.path)（未运行）" } else { '当前 PATH 未发现，相关功能需另行准备' }
            if (-not $tool.found) { $missing += $tool.name }
            $dependencyLines += "$($tool.name)：$state"
        }
        $script:dependencyLabel.Text = if (-not $script:dependencies.Count) { '可选依赖：未取得检查结果，不阻断配置安装。' }
            elseif ($missing.Count) { '可选依赖缺失：' + ($missing -join ' / ') + '；相关功能需另行准备，不阻断配置安装。' }
            else { '可选依赖：PATH 已发现 FFmpeg / Python（仅检查路径，未运行）。' }
        if ($Result.error) { Set-Failure '检查未完成，请查看详情' $Result.error; return }
        if (-not $plan) { Set-Failure '检查未完成，请查看详情' '后台检查未返回有效结果。'; return }
        $version = if ($plan.installedVersion) { $plan.installedVersion } elseif ($plan.action -in @('install','install-player')) { '尚未安装' } else { '未能识别' }
        $script:restoreLabel = switch ($plan.restoreKind) { 'remove-install' { '撤销本次安装' } 'restore-version' { '还原更新前配置' } default { '还原上次操作' } }
        $script:restoreButton.Text = $script:restoreLabel + '(&U)'
        $blocked = $plan.action -eq 'blocked' -or ($newPlayer -and -not $plan.eligible)
        $script:resultState = if ($blocked) { 'blocked' } elseif ($plan.action -eq 'current') { 'current' } else { 'ready' }
        $script:nextLabel.Text = if ($newPlayer -and -not $blocked) { "安装后双击 Play.cmd 启动。`r`n配置安装记录：$($plan.backupRoot)" }
            elseif ($plan.action -eq 'install') { "当前没有旧配置需要备份；安装时将创建可撤销记录。`r`n记录位置：$($plan.backupRoot)" }
            elseif ($plan.action -eq 'recover') { "将恢复到本次操作前，请先退出 mpv.net。`r`n备份位置：$($plan.backupRoot)" }
            elseif ($blocked) { '请查看详情并保留已有文件，处理后重新检查。不会自动合并或覆盖冲突。' }
            else { "更新前自动备份旧配置；快捷键设置、独立路径配置及其他个人文件将保留。`r`n备份位置：$($plan.backupRoot)" }
        $programPath = if ($newPlayer) { $plan.playerPath } else { $script:playerPath }
        $launchPath = if ($newPlayer) { $plan.launcherPath } else { $script:launcherPath }
        $lines = @("播放器：$programPath")
        if ($launchPath) { $lines += "启动入口：$launchPath" }
        $lines += @("配置目录：$($plan.target)", "来源：$($plan.targetSourceLabel)", "当前配置版本：$version", "安装包版本：$($plan.packageVersion)", "备份位置：$($plan.backupRoot)", '', $plan.reason)
        if ($plan.runningProcesses.Count) { $lines += ''; $lines += '请退出以下播放器实例后重新检查（安装器不会自动关闭）：'; foreach ($process in $plan.runningProcesses) { $lines += "  $($process.name)  PID $($process.pid)" } }
        if ($plan.files.Count) { $lines += ''; $lines += '文件变更：' }
        foreach ($file in $plan.files) {
            $change = switch ($file.change) { 'added' { '新增' } 'modified' { '修改' } 'unchanged' { '保持' } default { '需检查' } }
            $lines += "  $change  $($file.path)"
        }
        if ($plan.warnings.Count) { $lines += ''; $lines += @($plan.warnings) }
        if ($plan.canRestore) {
            $lines += ''; $lines += "最新一次可还原记录：$($plan.restoreManifest)"
            if($plan.restorePreviousVersion){$lines += "还原后的配置版本：$($plan.restorePreviousVersion)"}
            $lines += "还原文件变更：$($plan.restoreChangedFiles) 个"
            foreach ($file in $plan.restoreFiles) { $change = switch ($file.change) { 'restore' { '还原' } 'remove' { '移除' } default { '保持' } }; $lines += "  $change  $($file.path)" }
        }
        $lines += ''; $lines += $dependencyLines
        $script:logBox.Text = $lines -join "`r`n"
        if ($script:preserveResult -and $script:lastResult) {
            $script:resultState = $script:lastResult.state; $script:statusLabel.Text = $script:lastResult.title
            $script:reasonLabel.Text = $script:lastResult.description
            $script:nextLabel.Text = $script:lastResult.backupText
            $script:summaryLabel.Text = "本次操作：已处理 $($script:lastResult.changedFiles) 个文件。`r`n最新检查：$($plan.reason)"
            $script:logBox.Text = $script:lastResult.description + "`r`n" + $script:lastResult.backupText + "`r`n`r`n最新检查：`r`n" + $script:logBox.Text
        }
        # Compact presentation; the complete plan and dependency report above
        # remain in the selectable details area.
        $script:summaryLabel.Text=if($plan.action -eq 'update' -and $version -ne $plan.packageVersion){"$version  →  $($plan.packageVersion)"}elseif($plan.packageVersion){"版本 $($plan.packageVersion)"}else{''}
        $script:statusLabel.Text=if($blocked){'暂时不能继续'}else{switch($plan.action){'install'{'可以安装'}'install-player'{'可以新装播放器'}'update'{'可以更新'}'current'{'无需更新'}'recover'{'上次操作未完成'}}}
        $script:reasonLabel.Text=switch($plan.action){'install'{'个人设置会保留，安装后可撤销。'}'install-player'{'将离线安装播放器和配置。安装后双击 Play.cmd 启动。'}'update'{'更新前自动备份，个人设置保留。'}'current'{'当前配置包已是这个版本。'}'recover'{'先恢复到操作前，再继续安装。'}}
        if ($blocked) {
            $brief = ([string]$plan.reason -replace '\r?\n', ' ').Trim()
            $script:reasonLabel.Text = if ($brief -and $brief.Length -le 64) { $brief } elseif ($script:installDirectory) { '请查看详情，或更换安装目录后继续。' } else { '存在文件或目录问题，请查看详情后重新检查。' }
        }
        if($plan.runningProcesses.Count){$script:statusLabel.Text='请先关闭播放器';$script:reasonLabel.Text='关闭所有 mpv.net 窗口后，重新检查。'}
        if($script:preserveResult -and $script:lastResult){
            $script:statusLabel.Text=$script:lastResult.title
            $script:reasonLabel.Text=if($script:lastResult.operation -eq 'InstallPlayer'){'在资源管理器中双击 Play.cmd 启动播放器。'}elseif($script:lastResult.operation -in @('Restore','Recover')){'已回到操作前的配置。'}else{'重新打开播放器后生效。'}
        }
    }
    function Get-ControlSnapshot([Windows.Forms.Control]$Parent) {
        foreach ($control in $Parent.Controls) {
            [ordered]@{ type = $control.GetType().Name; name = $control.AccessibleName; text = $control.Text
                visible = $control.Visible; enabled = $control.Enabled; tabIndex = $control.TabIndex; tabStop = $control.TabStop
                bounds = [ordered]@{ x = $control.Left; y = $control.Top; width = $control.Width; height = $control.Height }
                children = @(Get-ControlSnapshot $control) }
        }
    }
    function Save-InstallerSnapshot {
        if (-not $SnapshotPath -or $script:snapshotTaken) { return }
        $script:form.PerformLayout(); $bitmap = New-Object Drawing.Bitmap($script:form.Width, $script:form.Height)
        try { $script:form.DrawToBitmap($bitmap, (New-Object Drawing.Rectangle(0, 0, $script:form.Width, $script:form.Height))); $bitmap.Save($SnapshotPath, [Drawing.Imaging.ImageFormat]::Png) }
        finally { $bitmap.Dispose() }
        $snapshot = [ordered]@{ ownPID = $PID; statusLabel = $script:statusLabel.Text; planReady = ($null -ne $script:plan -and [bool]$script:plan.eligible)
            windowDpi = [MpvnetInstallerDpi]::GetDpiForWindow($script:form.Handle)
            dpiAwareness = [MpvnetInstallerDpi]::GetAwarenessFromDpiAwarenessContext([MpvnetInstallerDpi]::GetWindowDpiAwarenessContext($script:form.Handle))
            planAction = $(if ($script:plan) { $script:plan.action } else { $null }); canRestore = [bool]($script:plan -and $script:plan.canRestore)
            state = $script:resultState; busy = $script:busy; installed = $script:installed; detailsExpanded = $script:detailsExpanded
            reason = $script:reasonLabel.Text; nextStep = $script:nextLabel.Text; dependencySummary = $script:dependencyLabel.Text
            buttonsEnabled = [ordered]@{ browse = $script:playerBrowse.Enabled; newPlayer = $script:directoryBrowse.Enabled; recheck = $script:recheckButton.Enabled; install = $script:installButton.Enabled; restore = $script:restoreButton.Enabled; details = $script:detailsButton.Enabled }
            target = $script:target; targetSource = $script:targetSource; targetExists = $script:targetExists; sourceText = $script:sourceLabel.Text; player = $script:playerPath
            installDirectory = $script:installDirectory; launcher = $script:launcherPath
            dependencies = $script:dependencies; onlySelector = 'mpvnet.exe'; logText = $script:logBox.Text; controlsBounds = @(Get-ControlSnapshot $script:form)
            clientSize = [ordered]@{ width = $script:form.ClientSize.Width; height = $script:form.ClientSize.Height } }
        [IO.File]::WriteAllText(($SnapshotPath + '.json'), ($snapshot | ConvertTo-Json -Depth 30), (New-Object Text.UTF8Encoding($false)))
        $script:snapshotTaken = $true
        if ($CloseAfterSnapshot) { $script:form.Close() }
    }
    function Dispose-Worker {
        if ($script:worker) { $script:worker.Dispose(); $script:worker = $null }
        if ($script:runspace) { $script:runspace.Dispose(); $script:runspace = $null }
    }
    function Start-Work([string]$Operation) {
        if ($script:busy) { return }
        $token = if ($Operation -eq 'Restore') { $script:plan.restorePlanToken } elseif ($script:plan) { $script:plan.planToken } else { '' }
        if ($Operation -notin @('check','discover')) { $script:preserveResult = $false }
        $script:busy = $true; $script:operation = $Operation; Update-Enabled
        $script:resultState = if ($Operation -in @('check','discover')) { 'checking' } else { 'working' }
        $script:statusLabel.Text = switch ($Operation) {
            'discover' { '正在查找已有播放器…' }
            'check' { if ($script:installDirectory) { '正在检查安装目录…' } else { '正在检查配置…' } }
            'InstallPlayer' { '正在安装播放器…' }
            'Restore' { '正在还原配置…' }
            'Recover' { '正在恢复操作前配置…' }
            default { if ($script:plan.action -eq 'install') { '正在安装配置…' } else { '正在备份并更新配置…' } }
        }
        $script:reasonLabel.Text = if ($Operation -in @('check','discover')) { '' } else { '完成前请保持窗口打开。' }
        $script:nextLabel.Text = '请等待处理完成。当前不能重复操作或关闭窗口。'
        $script:runspace = [RunspaceFactory]::CreateRunspace(); $script:runspace.Open()
        $script:worker = [PowerShell]::Create(); $script:worker.Runspace = $script:runspace
        $null = $script:worker.AddScript({
            param($Module, $PortableModule, $Operation, $Player, $Directory, $Package, $Backup, $Token)
            $ErrorActionPreference = 'Stop'
            Import-Module (Join-Path ([IO.Path]::GetDirectoryName($Module)) 'common.psm1') -Force
            if ($Operation -eq 'discover') {
                $candidates = @(Get-Command mpvnet.exe -CommandType Application -All -ErrorAction SilentlyContinue | ForEach-Object Path)
                $appPath = 'SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\mpvnet.exe'
                foreach ($hive in @('HKEY_CURRENT_USER','HKEY_LOCAL_MACHINE')) {
                    try { $candidates += [Microsoft.Win32.Registry]::GetValue("$hive\$appPath", '', '') } catch { }
                }
                $packagePrefix = (Get-KitRoot $Package).TrimEnd('\') + '\'
                $players = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
                foreach ($candidate in $candidates) {
                    if ($candidate -isnot [string]) { continue }
                    $path = $candidate.Trim().Trim('"')
                    if ($path -notmatch '^[a-z]:[\\/]') { continue }
                    try {
                        $path = Get-KitPlayer $path
                        if ([IO.Path]::GetFileName($path) -ieq 'mpvnet.exe' -and
                            -not $path.StartsWith($packagePrefix, [StringComparison]::OrdinalIgnoreCase)) { [void]$players.Add($path) }
                    } catch { } # Stale and inaccessible registered paths do not block manual selection.
                }
                # Avoid guessing between independent installations.
                return [pscustomobject]@{ playerPath = $(if ($players.Count -eq 1) { $players | Select-Object -First 1 }) }
            }
            Import-Module $Module -Force
            $arguments = @{ PackageRoot = $Package }
            if ($Backup) { $arguments.BackupRoot = $Backup }
            if ($Directory) {
                Import-Module $PortableModule
                $arguments.InstallDirectory = $Directory
            } else { $arguments.PlayerPath = $Player }
            if ($Operation -eq 'check') {
                $resolved = $null; $plan = $null; $failure = ''
                try {
                    if ($Directory) { $plan = Get-KitPortablePlan @arguments }
                    else {
                        $validatedPlayer = Get-KitPlayer $Player
                        if ([IO.Path]::GetFileName($validatedPlayer) -ine 'mpvnet.exe') { throw '请选择名为 mpvnet.exe 的 mpv.net 播放器程序。' }
                        $resolved = Get-KitTargetContext -PlayerPath $validatedPlayer
                        $plan = Get-KitMaintenancePlan @arguments
                    }
                } catch { $failure = $_.Exception.Message }
                $tools = @()
                try {
                    $cleanPath = Join-Path ([IO.Path]::GetDirectoryName($Module)) 'clean-install.psm1'
                    Import-Module $cleanPath
                    $tools = @(& (Get-Module 'clean-install') { @((Get-CleanOptionalTool 'ffmpeg.exe' 'FFmpeg'), (Get-CleanOptionalTool 'python.exe' 'Python')) })
                } catch { } # Optional PATH discovery never blocks the maintenance plan.
                [pscustomobject]@{ resolution = $resolved; plan = $plan; tools = @($tools); error = $failure }
            } elseif ($Operation -eq 'InstallPlayer') { Invoke-KitPortableInstall @arguments -ExpectedPlanToken $Token }
            else { Invoke-KitMaintenance @arguments -Operation $Operation -ExpectedPlanToken $Token }
        }).AddArgument($script:modulePath).AddArgument($script:portableModulePath).AddArgument($Operation).AddArgument($script:playerPath).
            AddArgument($script:installDirectory).AddArgument($script:packageRoot).AddArgument($script:backupRoot).AddArgument($token)
        $script:async = $script:worker.BeginInvoke(); $script:timer.Start()
    }
    function Start-AutomaticCheck([bool]$KeepResult = $false) {
        if ($script:busy -or $script:confirming -or -not ($script:playerPath -or $script:installDirectory)) { return }
        $script:preserveResult = $KeepResult; $script:plan = $null
        $script:targetCaption.Text = '配置目录'; $script:targetBox.AccessibleName = '配置目录，可选择完整路径'
        if (-not $KeepResult) {
            $script:lastResult = $null; $script:target = ''; $script:targetSource = ''; $script:targetExists = $null; $script:dependencies = @()
            $script:targetBox.Text = '正在判断…'; $script:sourceLabel.Text = '正在识别来源与目录状态…'
            $script:dependencyLabel.Text = '可选依赖：正在检查当前 PATH…'; Set-DetailsExpanded $false
        }
        try { Start-Work 'check' }
        catch { Dispose-Worker; $script:busy = $false; Set-Failure '检查未启动' $_.Exception.Message; Update-Enabled; if ($SnapshotPath) { Save-InstallerSnapshot } }
    }
    $script:timer = New-Object Windows.Forms.Timer; $script:timer.Interval = 100
    $script:timer.Add_Tick({
        if (-not $script:async.IsCompleted) { return }
        $script:timer.Stop(); $refresh = $false
        $discovery = $script:operation -eq 'discover'
        try {
            $output = $script:worker.EndInvoke($script:async)
            if ($script:worker.Streams.Error.Count -gt 0) { throw ($script:worker.Streams.Error | Out-String) }
            if (-not $output.Count) { throw '后台操作未返回结果。请重新检查后再试。' }
            $result = $output[$output.Count - 1]
            if ($discovery) {
                if ($result.playerPath) { Set-InstallSelection $result.playerPath }
            } elseif ($script:operation -eq 'check') { Show-Plan $result }
            else {
                if ($script:operation -eq 'InstallPlayer' -and ($result.mode -ne 'applied' -or -not $result.playerPath -or -not $result.launcherPath)) {
                    throw '未能确认完整安装结果，请重新检查安装目录。'
                }
                $changedFiles = if ($null -ne $result.changedFiles) { $result.changedFiles } else { $script:plan.changedFiles }
                $script:installed = $true; $script:plan = $null; $script:resultState = 'completed'
                if ($script:operation -eq 'InstallPlayer') { Set-InstallSelection -Player $result.playerPath -Launcher $result.launcherPath }
                $title = if ($script:operation -eq 'InstallPlayer') { '播放器安装完成' } elseif ($script:operation -eq 'Restore') { '上次操作已还原' } elseif ($script:operation -eq 'Recover') { '已恢复到本次操作前' } elseif ($script:lastOperation -eq 'install') { '配置安装完成' } else { '配置更新完成' }
                $description = if ($script:operation -eq 'InstallPlayer') { "双击 Play.cmd 启动播放器：`r`n$($result.launcherPath)" }
                    elseif ($script:operation -eq 'Restore' -and $script:restoreLabel -eq '撤销本次安装') { '本次安装已撤销，其他个人文件保持不变。' }
                    elseif ($script:operation -eq 'Recover') { '未完成的操作已恢复到操作前状态。请重新检查后继续。' }
                    else { "已处理 $changedFiles 个配置文件，个人文件保持不变。请重新启动 mpv.net。" }
                $backupText = if ($result.backupManifest) { '备份或安装记录：' + $result.backupManifest } else { '已有备份仍保留，可重新检查配置状态。' }
                $script:lastResult = [pscustomobject]@{ state = 'completed'; operation=$script:operation; title = $title; description = $description; backupText = $backupText; changedFiles = $changedFiles }
                $script:statusLabel.Text = $title; $script:reasonLabel.Text = $description; $script:nextLabel.Text = $backupText
                $refresh = $true
            }
        } catch {
            if (-not $discovery) {
                $failureTitle = if ($script:operation -eq 'check') { '检查未完成，请查看详情' } else { '操作未完成，请查看详情' }
                Set-Failure $failureTitle $_.Exception.Message
            }
        } finally { Dispose-Worker; $script:busy = $false; Update-Enabled }
        if ($refresh) { Start-AutomaticCheck $true }
        elseif ($discovery -and $script:playerPath) { Start-AutomaticCheck }
        elseif ($discovery) { Set-InstallerIdle; if ($SnapshotPath) { Save-InstallerSnapshot } }
        elseif ($SnapshotPath) { Save-InstallerSnapshot }
    })
    $script:detailsButton.Add_Click({ Set-DetailsExpanded (-not $script:detailsExpanded) })
    $script:recheckButton.Add_Click({ Start-AutomaticCheck })
    $selectPlayer={
        if ($script:busy -or $script:confirming) { return }
        $dialog = New-Object Windows.Forms.OpenFileDialog
        try {
            $dialog.Title = '选择 mpvnet.exe'; $dialog.Filter = 'mpv.net 播放器 (mpvnet.exe)|mpvnet.exe'; $dialog.CheckFileExists = $true
            if ($script:playerPath -and [IO.File]::Exists($script:playerPath)) { $dialog.FileName = $script:playerPath }
            if ($dialog.ShowDialog($script:form) -eq 'OK') { Set-InstallSelection $dialog.FileName; Start-AutomaticCheck }
        } finally { $dialog.Dispose() }
    }
    $selectDirectory = {
        if ($script:busy -or $script:confirming -or -not $script:portablePackage) { return }
        $folder = New-Object Windows.Forms.FolderBrowserDialog
        try {
            $folder.Description = '请选择或新建一个空目录，用于安装 mpv.net 播放器。'
            $folder.ShowNewFolderButton = $true
            if ($script:installDirectory -and [IO.Directory]::Exists($script:installDirectory)) { $folder.SelectedPath = $script:installDirectory }
            if ($folder.ShowDialog($script:form) -eq 'OK') { Set-InstallSelection -Directory $folder.SelectedPath; Start-AutomaticCheck }
        } finally { $folder.Dispose() }
    }
    $script:playerBrowse.Add_Click($selectPlayer)
    $script:directoryBrowse.Add_Click($selectDirectory)
    function Confirm-Maintenance([string]$Operation) {
        if (-not $script:plan -or $script:busy -or $script:confirming) { return }
        if ($Operation -eq 'Restore') {
            if (-not $script:plan.canRestore -or -not $script:plan.restorePlanToken) { return }
            $removeInstall=$script:plan.restoreKind -eq 'remove-install'
            $caption=if($removeInstall){'撤销这次安装？'}else{'还原上次更新？'}
            $actionLabel=if($removeInstall){'撤销安装'}else{'还原'}
            $description=if($removeInstall){'将移除本次安装的配置包文件，个人文件保留。'}else{'将回到更新前的配置，并移除那次更新新增的文件。个人文件保留。'}
            $detailsTitle='还原说明'
        } else {
            if (-not $script:plan.eligible -or $script:plan.action -notin @('install', 'install-player', 'update', 'recover')) { return }
            $script:lastOperation = $script:plan.action
            if ($script:plan.action -eq 'recover') { $Operation='Recover';$caption='恢复操作前配置？';$actionLabel='恢复';$description='将撤销未完成的更改，使用已有备份恢复。';$detailsTitle='恢复说明' }
            elseif ($script:plan.action -eq 'install-player') {
                $Operation = 'InstallPlayer'; $caption = '安装 mpv.net 播放器？'; $actionLabel = '安装播放器'; $detailsTitle = '安装详情'
                $description = '即将安装播放器和配置。日后撤销安装只移除套件配置，播放器文件会保留。'
            }
            elseif ($script:plan.action -eq 'install') { $caption='安装配置包？';$actionLabel='安装';$description='个人设置会保留，安装后可撤销。';$detailsTitle="文件变更 · $($script:plan.changedFiles) 项" }
            else { $caption='更新配置包？';$actionLabel='更新';$description='更新前自动备份，个人设置会保留。';$detailsTitle="文件变更 · $($script:plan.changedFiles) 项" }
        }
        # The maintenance view is an ordered dictionary: its keys are not
        # PSObject.Properties, although normal member lookup exposes them.
        if ($Operation -eq 'Apply' -and $script:plan.action -eq 'update' -and $script:plan.releaseNotice) {
            $description += "`r`n`r`n" + $script:plan.releaseNotice
        }
        $message = if ($Operation -eq 'InstallPlayer') { $description + "`r`n`r`n启动入口`r`n$($script:plan.launcherPath)" }
            else { $description + "`r`n`r`n配置目录`r`n$($script:plan.target)" }
        $details=$script:logBox.Text
        if($Operation -in @('Restore','Recover')){$details="如果相关文件后来又被修改，会停止恢复，不覆盖后续修改。`r`n`r`n"+$details}
        elseif($script:plan.releaseNotice){$details += "`r`n`r`n更新说明`r`n"+$script:plan.releaseNotice}
        $confirmation = $null
        try {
            $script:confirming = $true; Update-Enabled
            $confirmation = New-Object KitInstallerConfirmation([single]$script:uiScale, $message, $caption, $actionLabel, $detailsTitle, $details)
            if ($confirmation.ShowDialog($script:form) -eq 'OK') { Start-Work $Operation }
        } catch { Dispose-Worker; $script:busy = $false; Set-Failure '操作未启动' $_.Exception.Message }
        finally { if ($confirmation) { $confirmation.Dispose() }; $script:confirming = $false; Update-Enabled }
    }
    $script:installButton.Add_Click({
        if($script:busy -or $script:confirming){return}
        switch($script:primaryMode){'browse'{& $selectPlayer}'directory'{& $selectDirectory}'finish'{$script:form.Close()}'check'{Start-AutomaticCheck}'apply'{Confirm-Maintenance 'Apply'}}
    })
    $script:restoreButton.Add_Click({ Confirm-Maintenance 'Restore' })
    $script:form.Add_KeyDown({ param($sender, $eventArgs)
        if ($eventArgs.Alt -and $eventArgs.KeyCode -eq [Windows.Forms.Keys]::D -and $script:detailsButton.Enabled) {
            $eventArgs.Handled=$true; $eventArgs.SuppressKeyPress=$true
            if(($script:playerPath -or $script:installDirectory) -and -not $script:busy -and -not $script:confirming){Set-DetailsExpanded (-not $script:detailsExpanded)}
        }
        if ($eventArgs.KeyCode -eq [Windows.Forms.Keys]::Escape) {
            $eventArgs.Handled = $true; $eventArgs.SuppressKeyPress = $true
            if (-not $script:busy) { $script:form.Close() }
        }
    })
    $script:form.Add_FormClosing({ param($sender, $eventArgs)
        if ($script:busy -or $script:confirming) {
            $eventArgs.Cancel = $true
            if ($script:busy) { $script:nextLabel.Text = '正在处理，请等待完成后关闭窗口。' }
        }
    })
    if ($PlayerPath) { Set-InstallSelection $PlayerPath }
    $workingArea = [Windows.Forms.Screen]::FromControl($script:form).WorkingArea
    $availableHeight = [Math]::Max(1, $workingArea.Height - (ConvertTo-InstallerPixels 16))
    $script:form.MinimumSize = New-Object Drawing.Size([Math]::Min($script:form.MinimumSize.Width, $workingArea.Width), [Math]::Min($script:form.MinimumSize.Height, $availableHeight))
    $script:form.Height = [Math]::Min($script:form.Height, $availableHeight)
    $script:form.ResumeLayout($true)
    Update-Enabled
    $script:form.Add_Shown({
        if ($script:playerPath) { Start-AutomaticCheck }
        elseif ($script:portablePackage) {
            try { Start-Work 'discover' }
            catch { Dispose-Worker; $script:busy = $false; Set-InstallerIdle; Update-Enabled; if ($SnapshotPath) { Save-InstallerSnapshot } }
        }
        elseif ($SnapshotPath) { Save-InstallerSnapshot }
    })
    try { [void]$script:form.ShowDialog() } finally { $script:timer.Dispose(); Dispose-Worker; $script:form.Dispose() }
} catch {
    try { [void][Windows.Forms.MessageBox]::Show($_.Exception.Message, 'mpv.net 配置包安装器', 'OK', 'Error') } catch { [Console]::Error.WriteLine($_.Exception.Message) }
    exit 1
} finally {
    if ($previousDpiContext -ne [IntPtr]::Zero) { [void][MpvnetInstallerDpi]::SetThreadDpiAwarenessContext($previousDpiContext) }
}
