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
    $script:backupRoot = $BackupRoot; $script:packageRoot = $PackageRoot; $script:plan = $null; $script:worker = $null; $script:runspace = $null
    $script:busy = $false; $script:installed = $false; $script:snapshotTaken = $false; $script:detailsExpanded = $false
    $script:lastResult = $null; $script:lastOperation = ''; $script:restoreLabel = '还原上次操作'; $script:preserveResult = $false
    $script:target = ''; $script:targetSource = ''; $script:targetExists = $null; $script:dependencies = @(); $script:resultState = 'idle'
    $script:form = New-Object Windows.Forms.Form
    $script:form.SuspendLayout()
    $script:form.Text = 'mpv.net 配置包 · 安装与更新'; $script:form.StartPosition = 'CenterScreen'
    $script:form.ClientSize = New-InstallerSize 800 750
    $script:form.MinimumSize = New-InstallerSize 776 760
    $script:form.BackColor = [Drawing.Color]::FromArgb(27, 31, 39)
    $script:form.ForeColor = [Drawing.Color]::FromArgb(233, 237, 243)
    $script:form.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)
    # Fonts use points; scale layout metrics once, avoiding legacy WinForms partial/double autoscaling.
    $script:form.AutoScaleMode = 'None'; $script:form.KeyPreview = $true
    $script:mutedColor = [Drawing.Color]::FromArgb(180, 190, 204)
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
        $button = New-Object Windows.Forms.Button
        $button.Text = $Text; $button.Size = New-InstallerSize $Width 36
        $button.FlatStyle = 'Flat'; $button.BackColor = [Drawing.Color]::FromArgb(49, 62, 81)
        $button.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(92, 110, 133)
        $button.ForeColor = $script:form.ForeColor; $button.UseVisualStyleBackColor = $false; return $button
    }
    function New-ReadOnlyBox {
        $box = New-Object Windows.Forms.TextBox
        $box.Dock = 'Fill'; $box.ReadOnly = $true; $box.BorderStyle = 'FixedSingle'
        $box.BackColor = [Drawing.Color]::FromArgb(40, 46, 57); $box.ForeColor = $script:form.ForeColor
        $box.Margin = New-InstallerPadding 0; return $box
    }
    # Keep the action bar reachable on shorter screens; the single-page content can scroll.
    $frame = New-Layout $script:form 2; Add-Row $frame 'Percent' 100; Add-Row $frame 'Absolute' 68
    $scrollHost = New-Object Windows.Forms.Panel
    $scrollHost.Dock = 'Fill'; $scrollHost.AutoScroll = $true; $scrollHost.Margin = New-InstallerPadding 0
    $frame.Controls.Add($scrollHost, 0, 0)
    $root = New-Layout $scrollHost 4; $root.Dock = 'Top'; $root.Height = ConvertTo-InstallerPixels 650
    $root.Padding = New-InstallerPadding 24 16 24 16
    Add-Row $root 'Absolute' 70; Add-Row $root 'Absolute' 76; Add-Row $root 'Absolute' 120
    Add-Row $root 'Percent' 100
    $headingHost = New-Object Windows.Forms.Panel
    $root.Controls.Add($headingHost, 0, 0); $headingHost.Dock = 'Fill'; $headingHost.Margin = New-InstallerPadding 0
    $heading = New-Layout $headingHost 2; Add-Row $heading 'Absolute' 34; Add-Row $heading 'Percent' 100
    $title = New-Label '安装或更新配置包'; $title.Font = New-Object Drawing.Font('Microsoft YaHei UI', 16, [Drawing.FontStyle]::Bold)
    $heading.Controls.Add($title, 0, 0)
    $subtitle = New-Label '选择播放器，检查配置目录和文件变更后继续。'
    $subtitle.ForeColor = $script:mutedColor; $heading.Controls.Add($subtitle, 0, 1)
    $playerHost = New-Object Windows.Forms.Panel
    $root.Controls.Add($playerHost, 0, 1); $playerHost.Dock = 'Fill'; $playerHost.Margin = New-InstallerPadding 0
    $playerLayout = New-Layout $playerHost 2; Add-Row $playerLayout 'Absolute' 26; Add-Row $playerLayout 'Absolute' 36
    $playerLayout.ColumnCount = 2; $playerLayout.ColumnStyles.Clear()
    [void]$playerLayout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
    [void]$playerLayout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute', (ConvertTo-InstallerPixels 128))))
    $playerCaption = New-Label '播放器程序 · mpvnet.exe'; $playerLayout.Controls.Add($playerCaption, 0, 0); $playerLayout.SetColumnSpan($playerCaption, 2)
    $script:playerBox = New-ReadOnlyBox; $script:playerBox.Multiline = $true; $script:playerBox.WordWrap = $false
    $script:playerBox.AccessibleName = '播放器程序路径'; $script:playerBox.TabIndex = 0; $playerLayout.Controls.Add($script:playerBox, 0, 1)
    $script:playerBrowse = New-Button '选择播放器(&B)' 116; $script:playerBrowse.Dock = 'Fill'; $script:playerBrowse.TabIndex = 1
    $script:playerBrowse.Margin = New-InstallerPadding 12 0 0 0; $playerLayout.Controls.Add($script:playerBrowse, 1, 1)
    $targetHost = New-Object Windows.Forms.Panel
    $root.Controls.Add($targetHost, 0, 2); $targetHost.Dock = 'Fill'; $targetHost.Margin = New-InstallerPadding 0 2 0 10
    $targetHost.BackColor = [Drawing.Color]::FromArgb(32, 43, 56)
    $targetLayout = New-Layout $targetHost 3; $targetLayout.Padding = New-InstallerPadding 12 8 12 8
    Add-Row $targetLayout 'Absolute' 24; Add-Row $targetLayout 'Percent' 100; Add-Row $targetLayout 'Absolute' 32
    $targetCaption = New-Label '配置目录'; $targetCaption.Font = New-Object Drawing.Font('Microsoft YaHei UI', 10, [Drawing.FontStyle]::Bold)
    $targetLayout.Controls.Add($targetCaption, 0, 0)
    $script:targetBox = New-ReadOnlyBox; $script:targetBox.Multiline = $true; $script:targetBox.WordWrap = $true; $script:targetBox.ScrollBars = 'Vertical'
    $script:targetBox.ForeColor = [Drawing.Color]::FromArgb(104, 193, 237); $script:targetBox.Text = '选择播放器后自动判断。'
    $script:targetBox.AccessibleName = '配置目录，可选择完整路径'; $script:targetBox.TabIndex = 0; $targetLayout.Controls.Add($script:targetBox, 0, 1)
    $script:sourceLabel = New-Label '识别来源与目录状态会显示在这里。'; $script:sourceLabel.ForeColor = $script:mutedColor
    $targetLayout.Controls.Add($script:sourceLabel, 0, 2)
    $resultHost = New-Object Windows.Forms.Panel
    $root.Controls.Add($resultHost, 0, 3); $resultHost.Dock = 'Fill'; $resultHost.Margin = New-InstallerPadding 0
    $script:resultLayout = New-Layout $resultHost 7
    Add-Row $script:resultLayout 'Absolute' 28; Add-Row $script:resultLayout 'Absolute' 60
    Add-Row $script:resultLayout 'Absolute' 52; Add-Row $script:resultLayout 'Absolute' 52
    Add-Row $script:resultLayout 'Absolute' 44; Add-Row $script:resultLayout 'Absolute' 32; Add-Row $script:resultLayout 'Percent' 100
    $script:statusLabel = New-Label '请选择播放器'; $script:statusLabel.Font = New-Object Drawing.Font('Microsoft YaHei UI', 11, [Drawing.FontStyle]::Bold)
    $script:resultLayout.Controls.Add($script:statusLabel, 0, 0)
    $script:reasonLabel = New-Label '选择所用播放器的 mpvnet.exe，随后会自动检查配置目录。'
    $script:reasonLabel.AutoEllipsis = $false; $script:resultLayout.Controls.Add($script:reasonLabel, 0, 1)
    $script:summaryLabel = New-Label '当前配置：待检查　　安装包版本：待检查'; $script:summaryLabel.ForeColor = $script:mutedColor
    $script:resultLayout.Controls.Add($script:summaryLabel, 0, 2)
    $script:nextLabel = New-Label '只安装配置文件，不下载播放器或依赖，不修改系统设置。'
    $script:nextLabel.ForeColor = $script:mutedColor; $script:resultLayout.Controls.Add($script:nextLabel, 0, 3)
    $script:dependencyLabel = New-Label '可选依赖：检查后显示 FFmpeg / Python 的 PATH 发现结果。'
    $script:dependencyLabel.ForeColor = $script:mutedColor; $script:resultLayout.Controls.Add($script:dependencyLabel, 0, 4)
    $script:detailsButton = New-Button '展开检查详情(&D)' 170; $script:detailsButton.Anchor = 'Left'; $script:detailsButton.Height = ConvertTo-InstallerPixels 28
    $script:detailsButton.Margin = New-InstallerPadding 0 2 0 2; $script:detailsButton.TabIndex = 0
    $script:resultLayout.Controls.Add($script:detailsButton, 0, 5)
    $script:logBox = New-ReadOnlyBox; $script:logBox.Multiline = $true; $script:logBox.WordWrap = $true; $script:logBox.ScrollBars = 'Vertical'
    $script:logBox.BackColor = [Drawing.Color]::FromArgb(20, 24, 31); $script:logBox.AccessibleName = '完整检查详情'; $script:logBox.TabIndex = 1; $script:logBox.Visible = $false
    $script:logBox.Text = '选择播放器后显示文件变更、备份位置及无法继续的具体原因。'
    $script:resultLayout.Controls.Add($script:logBox, 0, 6)
    $footer = New-Object Windows.Forms.FlowLayoutPanel
    $footer.Dock = 'Fill'; $footer.FlowDirection = 'RightToLeft'; $footer.WrapContents = $false
    $footer.Padding = New-InstallerPadding 24 12 24 16; $footer.Margin = New-InstallerPadding 0; $frame.Controls.Add($footer, 0, 1)
    $script:installButton = New-Button '开始安装(&I)' 140; $script:installButton.TabIndex = 1
    $script:installButton.Margin = New-InstallerPadding 12 0 0 0; $script:installButton.BackColor = [Drawing.Color]::FromArgb(22, 111, 161)
    $script:recheckButton = New-Button '重新检查(&R)' 120; $script:recheckButton.TabIndex = 0; $script:recheckButton.Margin = New-InstallerPadding 0
    $script:restoreButton = New-Button '还原上次操作(&U)' 164; $script:restoreButton.TabIndex = 2
    $script:restoreButton.Margin = New-InstallerPadding 12 0 0 0
    $footer.Controls.Add($script:installButton); $footer.Controls.Add($script:restoreButton); $footer.Controls.Add($script:recheckButton)
    $headingHost.TabIndex = 0; $playerHost.TabIndex = 1; $targetHost.TabIndex = 2; $resultHost.TabIndex = 3; $footer.TabIndex = 4
    function Set-DetailsExpanded([bool]$Expanded) {
        $script:detailsExpanded = $Expanded; $script:logBox.Visible = $Expanded
        $script:detailsButton.Text = if ($Expanded) { '收起检查详情(&D)' } else { '展开检查详情(&D)' }
    }
    function Update-Enabled {
        $script:playerBrowse.Enabled = -not $script:busy
        $script:recheckButton.Enabled = -not $script:busy -and [bool]$script:playerBox.Text
        $script:installButton.Enabled = -not $script:busy -and $null -ne $script:plan -and [bool]$script:plan.eligible -and $script:plan.action -in @('install', 'update', 'recover')
        $script:restoreButton.Enabled = -not $script:busy -and $null -ne $script:plan -and [bool]$script:plan.canRestore -and [bool]$script:plan.restorePlanToken
        $script:detailsButton.Enabled = -not $script:busy; $script:form.UseWaitCursor = $script:busy
    }
    function Set-Failure([string]$Title, [string]$Detail) {
        $script:plan = $null; $script:resultState = 'blocked'; $script:statusLabel.Text = $Title
        if (-not $script:target) {
            $script:targetBox.Text = '未能确定配置目录。'; $script:sourceLabel.Text = '来源：未确定  ·  目录状态：未确定'
        }
        $script:reasonLabel.Text = $Detail.Replace("`r`n", ' ').Replace("`n", ' ')
        $script:nextLabel.Text = '请查看具体原因，处理后重新检查。播放器路径和已有备份将保留。'
        $script:logBox.Text = $Detail
        if ($script:preserveResult -and $script:lastResult) {
            $script:resultState = 'completed-check-failed'; $script:statusLabel.Text = $script:lastResult.title
            $script:reasonLabel.Text = $script:lastResult.description + ' 最新检查未完成，请查看详情并重新检查。'
            $script:nextLabel.Text = $script:lastResult.backupText
            $script:summaryLabel.Text = "本次操作：已处理 $($script:lastResult.changedFiles) 个文件。`r`n最新检查：$($plan.reason)"
            $script:logBox.Text = $script:lastResult.description + "`r`n" + $script:lastResult.backupText + "`r`n`r`n最新检查失败：`r`n" + $Detail
        }
        Set-DetailsExpanded $true
    }
    function Show-Plan($Result) {
        $script:plan = $Result.plan; $script:dependencies = @($Result.tools)
        $plan = $script:plan
        if ($plan) {
            $script:target = $plan.target; $script:targetSource = $plan.targetSource; $script:targetExists = [bool]$plan.targetExists
            $script:targetBox.Text = $script:target
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
        $version = if ($plan.installedVersion) { $plan.installedVersion } elseif ($plan.action -eq 'install') { '尚未安装' } else { '未能识别' }
        $script:summaryLabel.Text = "当前配置：$version    安装包版本：$($plan.packageVersion)`r`n文件变更：共 $($plan.changedFiles) 个（新增 $($plan.addedFiles) 个）"
        $script:restoreLabel = switch ($plan.restoreKind) { 'remove-install' { '撤销本次安装' } 'restore-version' { '还原更新前配置' } default { '还原上次操作' } }
        $script:restoreButton.Text = $script:restoreLabel + '(&U)'
        $script:installButton.Text = switch ($plan.action) { 'update' { '开始更新(&I)' } 'recover' { '恢复操作前配置(&I)' } 'current' { '无需更新' } 'blocked' { '暂无法继续' } default { '开始安装(&I)' } }
        $script:resultState = if ($plan.action -eq 'blocked') { 'blocked' } elseif ($plan.action -eq 'current') { 'current' } else { 'ready' }
        $script:statusLabel.Text = switch ($plan.action) { 'install' { '检查通过，可以安装' } 'update' { '检查通过，可以更新' } 'current' { '无需更新' } 'recover' { '上次操作未完成，需要恢复' } default { '存在问题，暂无法继续' } }
        $script:reasonLabel.Text = $plan.reason
        $script:nextLabel.Text = if ($plan.action -eq 'install') { "当前没有旧配置需要备份；安装时将创建可撤销记录。`r`n记录位置：$($plan.backupRoot)" }
            elseif ($plan.action -eq 'recover') { "将恢复到本次操作前，请先退出 mpv.net。`r`n备份位置：$($plan.backupRoot)" }
            elseif ($plan.action -eq 'blocked') { '请查看详情并保留已有文件，处理后重新检查。不会自动合并或覆盖冲突。' }
            else { "更新前自动备份旧配置；快捷键设置、独立路径配置及其他个人文件将保留。`r`n备份位置：$($plan.backupRoot)" }
        $lines = @("配置目录：$($plan.target)", "来源：$($plan.targetSourceLabel)", "当前配置版本：$version", "安装包版本：$($plan.packageVersion)", "备份位置：$($plan.backupRoot)", '', $plan.reason)
        if ($plan.runningProcesses.Count) { $lines += ''; $lines += '请退出以下播放器实例后重新检查（安装器不会自动关闭）：'; foreach ($process in $plan.runningProcesses) { $lines += "  $($process.name)  PID $($process.pid)" } }
        $lines += ''; $lines += '文件变更：'
        foreach ($file in $plan.files) {
            $change = switch ($file.change) { 'added' { '新增' } 'modified' { '修改' } 'unchanged' { '保持' } default { '需检查' } }
            $lines += "  $change  $($file.path)"
        }
        if ($plan.warnings.Count) { $lines += ''; $lines += @($plan.warnings) }
        if ($plan.canRestore) {
            $lines += ''; $lines += "最新一次可还原记录：$($plan.restoreManifest)"
            $lines += "还原文件变更：$($plan.restoreChangedFiles) 个"
            foreach ($file in $plan.restoreFiles) { $change = switch ($file.change) { 'restore' { '还原' } 'remove' { '移除' } default { '保持' } }; $lines += "  $change  $($file.path)" }
        }
        $lines += ''; $lines += $dependencyLines
        $script:logBox.Text = $lines -join "`r`n"
        if ($plan.action -eq 'blocked' -or $plan.action -eq 'recover') { Set-DetailsExpanded $true }
        if ($script:preserveResult -and $script:lastResult) {
            $script:resultState = $script:lastResult.state; $script:statusLabel.Text = $script:lastResult.title
            $script:reasonLabel.Text = $script:lastResult.description
            $script:nextLabel.Text = $script:lastResult.backupText
            $script:summaryLabel.Text = "本次操作：已处理 $($script:lastResult.changedFiles) 个文件。`r`n最新检查：$($plan.reason)"
            $script:logBox.Text = $script:lastResult.description + "`r`n" + $script:lastResult.backupText + "`r`n`r`n最新检查：`r`n" + $script:logBox.Text
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
            buttonsEnabled = [ordered]@{ browse = $script:playerBrowse.Enabled; recheck = $script:recheckButton.Enabled; install = $script:installButton.Enabled; restore = $script:restoreButton.Enabled; details = $script:detailsButton.Enabled }
            target = $script:target; targetSource = $script:targetSource; targetExists = $script:targetExists; sourceText = $script:sourceLabel.Text; player = $script:playerBox.Text
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
        if ($Operation -ne 'check') { $script:preserveResult = $false }
        $script:busy = $true; $script:operation = $Operation; Update-Enabled
        $script:resultState = if ($Operation -eq 'check') { 'checking' } else { 'working' }
        $script:statusLabel.Text = switch ($Operation) { 'check' { '正在检查配置…' } 'Restore' { '正在还原配置…' } 'Recover' { '正在恢复操作前配置…' } default { if ($script:plan.action -eq 'install') { '正在安装配置…' } else { '正在备份并更新配置…' } } }
        $script:reasonLabel.Text = if ($Operation -eq 'check') { '正在检查配置目录、文件变更及可还原记录。' } else { '正在核对已确认的计划并处理配置文件，请勿关闭窗口。' }
        $script:nextLabel.Text = '请等待处理完成。当前不能重复操作或关闭窗口。'
        $script:runspace = [RunspaceFactory]::CreateRunspace(); $script:runspace.Open()
        $script:worker = [PowerShell]::Create(); $script:worker.Runspace = $script:runspace
        $null = $script:worker.AddScript({
            param($Module, $Operation, $Player, $Package, $Backup, $Token)
            $ErrorActionPreference = 'Stop'
            Import-Module (Join-Path ([IO.Path]::GetDirectoryName($Module)) 'common.psm1') -Force
            Import-Module $Module -Force
            $arguments = @{ PlayerPath = $Player; PackageRoot = $Package }
            if ($Backup) { $arguments.BackupRoot = $Backup }
            if ($Operation -eq 'check') {
                $resolved = $null; $plan = $null; $failure = ''
                try {
                    $validatedPlayer = Get-KitPlayer $Player
                    if ([IO.Path]::GetFileName($validatedPlayer) -ine 'mpvnet.exe') { throw '请选择名为 mpvnet.exe 的 mpv.net 播放器程序。' }
                    $resolved = Get-KitTargetContext -PlayerPath $validatedPlayer
                    $plan = Get-KitMaintenancePlan @arguments
                } catch { $failure = $_.Exception.Message }
                $tools = @()
                try {
                    $cleanPath = Join-Path ([IO.Path]::GetDirectoryName($Module)) 'clean-install.psm1'
                    Import-Module $cleanPath
                    $tools = @(& (Get-Module 'clean-install') { @((Get-CleanOptionalTool 'ffmpeg.exe' 'FFmpeg'), (Get-CleanOptionalTool 'python.exe' 'Python')) })
                } catch { } # Optional PATH discovery never blocks the maintenance plan.
                [pscustomobject]@{ resolution = $resolved; plan = $plan; tools = @($tools); error = $failure }
            } else { Invoke-KitMaintenance @arguments -Operation $Operation -ExpectedPlanToken $Token }
        }).AddArgument($script:modulePath).AddArgument($Operation).AddArgument($script:playerBox.Text).AddArgument($script:packageRoot).AddArgument($script:backupRoot).AddArgument($token)
        $script:async = $script:worker.BeginInvoke(); $script:timer.Start()
    }
    function Start-AutomaticCheck([bool]$KeepResult = $false) {
        if ($script:busy -or -not $script:playerBox.Text) { return }
        $script:preserveResult = $KeepResult; $script:plan = $null
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
        try {
            $output = $script:worker.EndInvoke($script:async)
            if ($script:worker.Streams.Error.Count -gt 0) { throw ($script:worker.Streams.Error | Out-String) }
            if (-not $output.Count) { throw '后台操作未返回结果。请重新检查后再试。' }
            $result = $output[$output.Count - 1]
            if ($script:operation -eq 'check') { Show-Plan $result }
            else {
                $script:installed = $true; $script:plan = $null; $script:resultState = 'completed'
                $title = if ($script:operation -eq 'Restore') { '上次操作已还原' } elseif ($script:operation -eq 'Recover') { '已恢复到本次操作前' } elseif ($script:lastOperation -eq 'install') { '配置安装完成' } else { '配置更新完成' }
                $description = if ($script:operation -eq 'Restore' -and $script:restoreLabel -eq '撤销本次安装') { '本次安装已撤销，其他个人文件保持不变。' }
                    elseif ($script:operation -eq 'Recover') { '未完成的操作已恢复到操作前状态。请重新检查后继续。' }
                    else { "已处理 $($result.changedFiles) 个配置文件，个人文件保持不变。请重新启动 mpv.net。" }
                $backupText = if ($result.backupManifest) { '备份或安装记录：' + $result.backupManifest } else { '已有备份仍保留，可重新检查配置状态。' }
                $script:lastResult = [pscustomobject]@{ state = 'completed'; title = $title; description = $description; backupText = $backupText; changedFiles = $result.changedFiles }
                $script:statusLabel.Text = $title; $script:reasonLabel.Text = $description; $script:nextLabel.Text = $backupText
                $refresh = $true
            }
        } catch {
            $failureTitle = if ($script:operation -eq 'check') { '检查未完成，请查看详情' } else { '操作未完成，请查看详情' }
            Set-Failure $failureTitle $_.Exception.Message
        } finally { Dispose-Worker; $script:busy = $false; Update-Enabled }
        if ($refresh) { Start-AutomaticCheck $true }
        elseif ($SnapshotPath) { Save-InstallerSnapshot }
    })
    $script:detailsButton.Add_Click({ Set-DetailsExpanded (-not $script:detailsExpanded) })
    $script:recheckButton.Add_Click({ Start-AutomaticCheck })
    $script:playerBrowse.Add_Click({
        if ($script:busy) { return }
        $dialog = New-Object Windows.Forms.OpenFileDialog
        try {
            $dialog.Title = '选择 mpvnet.exe'; $dialog.Filter = 'mpv.net 播放器 (mpvnet.exe)|mpvnet.exe'; $dialog.CheckFileExists = $true
            if ($script:playerBox.Text -and [IO.File]::Exists($script:playerBox.Text)) { $dialog.FileName = $script:playerBox.Text }
            if ($dialog.ShowDialog($script:form) -eq 'OK') { $script:playerBox.Text = $dialog.FileName; Start-AutomaticCheck }
        } finally { $dialog.Dispose() }
    })
    function Confirm-Maintenance([string]$Operation) {
        if (-not $script:plan -or $script:busy) { return }
        if ($Operation -eq 'Restore') {
            if (-not $script:plan.canRestore -or -not $script:plan.restorePlanToken) { return }
            $caption = $script:restoreLabel
            $description = if ($script:plan.restoreKind -eq 'remove-install') { '将移除本次安装的配置包文件，其他个人文件保持不变。' } else { '将还原上次操作前的配置，并移除该次操作新增的配置包文件。个人文件与备份将保留。' }
            $description += "`r`n还原文件变更：$($script:plan.restoreChangedFiles) 个。"
            if ($script:plan.restorePreviousVersion) { $description += "`r`n还原后的配置版本：$($script:plan.restorePreviousVersion)" }
            $restoreChanges = @($script:plan.restoreFiles | Where-Object { $_.change -ne 'unchanged' })
            foreach ($file in @($restoreChanges | Select-Object -First 6)) {
                if ($file.change -eq 'unchanged') { continue }
                $change = if ($file.change -eq 'remove') { '移除' } else { '还原' }; $description += "`r`n$change  $($file.path)"
            }
            if ($restoreChanges.Count -gt 6) { $description += "`r`n另有 $($restoreChanges.Count - 6) 个文件，完整列表见检查详情。" }
            $description += "`r`n若相关文件在上次操作后被修改，还原将停止，不会覆盖后续修改。"
        } else {
            if (-not $script:plan.eligible -or $script:plan.action -notin @('install', 'update', 'recover')) { return }
            $script:lastOperation = $script:plan.action
            if ($script:plan.action -eq 'recover') { $Operation = 'Recover'; $caption = '恢复到本次操作前'; $description = '将使用已验证的备份恢复到本次操作前的配置状态。' }
            elseif ($script:plan.action -eq 'install') { $caption = '开始安装'; $description = '当前没有旧配置需要备份。安装时将创建可撤销记录。' }
            else { $caption = '开始更新'; $description = '更新前将自动备份旧配置，备份验证通过后开始更新。' }
            $description += "`r`n文件变更：$($script:plan.changedFiles) 个（新增 $($script:plan.addedFiles) 个）。"
        }
        $message = $description + "`r`n`r`n播放器：$($script:playerBox.Text)`r`n配置目录：$($script:plan.target)`r`n来源：$($script:plan.targetSourceLabel)`r`n`r`n请确认所有 mpv.net 实例均已退出。"
        if ([Windows.Forms.MessageBox]::Show($script:form, $message, $caption, 'OKCancel', 'Question', 'Button2') -eq 'OK') {
            try { Start-Work $Operation }
            catch { Dispose-Worker; $script:busy = $false; Set-Failure '操作未启动' $_.Exception.Message; Update-Enabled }
        }
    }
    $script:installButton.Add_Click({ Confirm-Maintenance 'Apply' })
    $script:restoreButton.Add_Click({ Confirm-Maintenance 'Restore' })
    $script:form.Add_KeyDown({ param($sender, $eventArgs)
        if ($eventArgs.KeyCode -eq [Windows.Forms.Keys]::Escape) {
            $eventArgs.Handled = $true; $eventArgs.SuppressKeyPress = $true
            if (-not $script:busy) { $script:form.Close() }
        }
    })
    $script:form.Add_FormClosing({ param($sender, $eventArgs)
        if ($script:busy) { $eventArgs.Cancel = $true; $script:nextLabel.Text = '正在处理，请等待完成后关闭窗口。' }
    })
    if ($PlayerPath) { $script:playerBox.Text = $PlayerPath }
    $workingArea = [Windows.Forms.Screen]::FromControl($script:form).WorkingArea
    $availableHeight = [Math]::Max(1, $workingArea.Height - (ConvertTo-InstallerPixels 16))
    $script:form.MinimumSize = New-Object Drawing.Size([Math]::Min($script:form.MinimumSize.Width, $workingArea.Width), [Math]::Min($script:form.MinimumSize.Height, $availableHeight))
    $script:form.Height = [Math]::Min($script:form.Height, $availableHeight)
    $script:form.ResumeLayout($true)
    Update-Enabled
    $script:form.Add_Shown({
        if ($script:playerBox.Text) { Start-AutomaticCheck }
        elseif ($SnapshotPath) { Save-InstallerSnapshot }
    })
    try { [void]$script:form.ShowDialog() } finally { $script:timer.Dispose(); Dispose-Worker; $script:form.Dispose() }
} catch {
    try { [void][Windows.Forms.MessageBox]::Show($_.Exception.Message, 'mpv.net 配置包安装器', 'OK', 'Error') } catch { [Console]::Error.WriteLine($_.Exception.Message) }
    exit 1
} finally {
    if ($previousDpiContext -ne [IntPtr]::Zero) { [void][MpvnetInstallerDpi]::SetThreadDpiAwarenessContext($previousDpiContext) }
}
