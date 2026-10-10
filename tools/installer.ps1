param(
    [string]$PlayerPath = '', [string]$PackageRoot = '',
    [string]$SnapshotPath = '', [switch]$CloseAfterSnapshot, [switch]$CheckOnStart
)
$ErrorActionPreference = 'Stop'
try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    if (-not $PackageRoot) { $PackageRoot = Split-Path -Parent $PSScriptRoot }
    $script:modulePath = Join-Path $PSScriptRoot 'clean-install.psm1'
    if (-not [IO.File]::Exists($script:modulePath)) { throw '安装器文件不完整，请重新解压完整配置包。' }
    $script:packageRoot = $PackageRoot; $script:plan = $null; $script:worker = $null
    $script:busy = $false; $script:installed = $false; $script:snapshotTaken = $false
    $script:target = ''; $script:targetSource = ''; $script:dependencies = @()
    $script:form = New-Object Windows.Forms.Form
    $script:form.Text = 'mpv.net 配置包 · 安装'
    $script:form.StartPosition = 'CenterScreen'
    $script:form.ClientSize = New-Object Drawing.Size(760, 500)
    $script:form.MinimumSize = New-Object Drawing.Size(776, 539)
    $script:form.BackColor = [Drawing.Color]::FromArgb(27, 31, 39)
    $script:form.ForeColor = [Drawing.Color]::FromArgb(233, 237, 243)
    $script:form.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)
    $script:form.AutoScaleMode = 'Dpi'
    function New-Label([string]$Text, [int]$Y, [int]$Height) {
        $label = New-Object Windows.Forms.Label
        $label.Text = $Text; $label.SetBounds(24, $Y, 712, $Height)
        $label.Anchor = 'Top, Left, Right'; $script:form.Controls.Add($label); return $label
    }
    function New-Button([string]$Text, [int]$X, [int]$Y, [int]$Width) {
        $button = New-Object Windows.Forms.Button
        $button.Text = $Text; $button.SetBounds($X, $Y, $Width, 32)
        $button.FlatStyle = 'Flat'; $button.BackColor = [Drawing.Color]::FromArgb(49, 62, 81)
        $button.ForeColor = $script:form.ForeColor; $script:form.Controls.Add($button); return $button
    }
    $title = New-Label '选择 mpv.net，自动确定安装位置' 18 32
    $title.Font = New-Object Drawing.Font('Microsoft YaHei UI', 15, [Drawing.FontStyle]::Bold)
    $null = New-Label '安装模式和便携模式均可。已有配置不会被覆盖；播放器状态和缓存会保留。' 55 27
    $null = New-Label 'mpv.net 播放器程序' 90 22
    $script:playerBox = New-Object Windows.Forms.TextBox
    $script:playerBox.SetBounds(24, 115, 605, 29); $script:playerBox.Anchor = 'Top, Left, Right'
    $script:playerBox.ReadOnly = $true; $script:playerBox.BackColor = [Drawing.Color]::FromArgb(40, 46, 57)
    $script:playerBox.ForeColor = $script:form.ForeColor; $script:playerBox.BorderStyle = 'FixedSingle'
    $script:form.Controls.Add($script:playerBox)
    $script:playerBrowse = New-Button '浏览…' 641 113 95; $script:playerBrowse.Anchor = 'Top, Right'
    $null = New-Label '实际配置安装目录' 165 22
    $script:targetLabel = New-Label '选择播放器后自动判断。' 191 48
    $script:targetLabel.ForeColor = [Drawing.Color]::FromArgb(104, 193, 237)
    $script:sourceLabel = New-Label '' 243 22
    $script:statusLabel = New-Label '请选择 mpvnet.exe，选择后会自动检查。' 275 24
    $script:logBox = New-Object Windows.Forms.TextBox
    $script:logBox.SetBounds(24, 308, 712, 119); $script:logBox.Anchor = 'Top, Bottom, Left, Right'
    $script:logBox.Multiline = $true; $script:logBox.ReadOnly = $true; $script:logBox.ScrollBars = 'Vertical'
    $script:logBox.BackColor = [Drawing.Color]::FromArgb(20, 24, 31); $script:logBox.ForeColor = $script:form.ForeColor
    $script:logBox.Text = "仅安装配置文件，不下载播放器或依赖，不修改系统设置。`r`nFFmpeg 和 Python 仅从当前 PATH 检查，不运行程序。`r`n本安装器不备份旧配置，也不创建更新或恢复记录。"
    $script:form.Controls.Add($script:logBox)
    $script:installButton = New-Button '确认安装' 596 449 140
    $script:installButton.Anchor = 'Bottom, Right'; $script:installButton.Enabled = $false
    $script:installButton.BackColor = [Drawing.Color]::FromArgb(22, 111, 161)
    function Update-Enabled {
        $script:playerBrowse.Enabled = -not ($script:busy -or $script:installed)
        $script:installButton.Enabled = -not ($script:busy -or $script:installed) -and $null -ne $script:plan
        $script:form.UseWaitCursor = $script:busy
    }
    function Save-InstallerSnapshot {
        if (-not $SnapshotPath -or $script:snapshotTaken) { return }
        $script:form.PerformLayout()
        $bitmap = New-Object Drawing.Bitmap($script:form.Width, $script:form.Height)
        try { $script:form.DrawToBitmap($bitmap, (New-Object Drawing.Rectangle(0, 0, $script:form.Width, $script:form.Height))); $bitmap.Save($SnapshotPath, [Drawing.Imaging.ImageFormat]::Png) }
        finally { $bitmap.Dispose() }
        $controls = @()
        foreach ($control in $script:form.Controls) {
            $controls += [ordered]@{ type = $control.GetType().Name; text = $control.Text; visible = $control.Visible
                enabled = $control.Enabled; bounds = [ordered]@{ x = $control.Left; y = $control.Top; width = $control.Width; height = $control.Height } }
        }
        $snapshot = [ordered]@{ ownPID = $PID; statusLabel = $script:statusLabel.Text; planReady = ($null -ne $script:plan)
            buttonsEnabled = [ordered]@{ browse = $script:playerBrowse.Enabled; install = $script:installButton.Enabled }
            target = $script:target; targetSource = $script:targetSource; player = $script:playerBox.Text
            dependencies = $script:dependencies; onlySelector = 'mpvnet.exe'; logText = $script:logBox.Text; controlsBounds = $controls
            clientSize = [ordered]@{ width = $script:form.ClientSize.Width; height = $script:form.ClientSize.Height } }
        [IO.File]::WriteAllText(($SnapshotPath + '.json'), ($snapshot | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
        $script:snapshotTaken = $true
        if ($CloseAfterSnapshot) { $script:form.Close() }
    }
    function Dispose-Worker {
        if ($script:worker) { $script:worker.Dispose(); $script:worker = $null }
        if ($script:runspace) { $script:runspace.Dispose(); $script:runspace = $null }
    }
    function Start-Work([string]$Operation) {
        $script:busy = $true; $script:operation = $Operation; Update-Enabled
        $script:statusLabel.Text = if ($Operation -eq 'check') { '正在自动判断配置目录并检查…' } else { '正在安装，请等待完成后关闭窗口…' }
        $script:runspace = [RunspaceFactory]::CreateRunspace(); $script:runspace.Open()
        $script:worker = [PowerShell]::Create(); $script:worker.Runspace = $script:runspace
        $null = $script:worker.AddScript({
            param($Module, $Operation, $Player, $Package, $Plan)
            $ErrorActionPreference = 'Stop'; Import-Module $Module -Force
            if ($Operation -eq 'check') {
                # Return resolution separately so an existing configuration refusal still shows the active target.
                $resolved = & (Get-Module 'clean-install') { param($Player) Resolve-CleanTarget (Get-CleanPlayer $Player) } $Player
                try {
                    $plan = Get-CleanInstallPlan -PlayerPath $Player -PackageRoot $Package
                    $resolved.target = $plan.target; $resolved.source = $plan.targetSource; $resolved.sourceLabel = $plan.targetSourceLabel
                    [pscustomobject]@{ resolution = $resolved; plan = $plan; tools = $plan.tools; error = '' }
                }
                catch {
                    $failure = $_.Exception.Message
                    $tools = & (Get-Module 'clean-install') { @((Get-CleanOptionalTool 'ffmpeg.exe' 'FFmpeg'), (Get-CleanOptionalTool 'python.exe' 'Python')) }
                    [pscustomobject]@{ resolution = $resolved; plan = $null; tools = @($tools); error = $failure }
                }
            } else { Invoke-CleanInstall -Plan $Plan }
        }).AddArgument($script:modulePath).AddArgument($Operation).AddArgument($script:playerBox.Text).AddArgument($script:packageRoot).AddArgument($script:plan)
        $script:async = $script:worker.BeginInvoke(); $script:timer.Start()
    }
    function Start-AutomaticCheck {
        if ($script:busy -or $script:installed -or -not $script:playerBox.Text) { return }
        $script:plan = $null; $script:target = ''; $script:targetSource = ''; $script:dependencies = @()
        $script:targetLabel.Text = '正在判断…'; $script:sourceLabel.Text = ''
        try { Start-Work 'check' }
        catch {
            Dispose-Worker; $script:busy = $false; Update-Enabled
            $script:statusLabel.Text = '检查未启动。'; $script:logBox.Text = $_.Exception.Message
            if ($SnapshotPath) { Save-InstallerSnapshot }
        }
    }
    $script:timer = New-Object Windows.Forms.Timer; $script:timer.Interval = 100
    $script:timer.Add_Tick({
        if (-not $script:async.IsCompleted) { return }
        $script:timer.Stop()
        try {
            $output = $script:worker.EndInvoke($script:async)
            # A caught preflight refusal is returned as structured data; HadErrors includes handled errors.
            if ($script:worker.Streams.Error.Count -gt 0) { throw ($script:worker.Streams.Error | Out-String) }
            $result = $output[$output.Count - 1]
            if ($script:operation -eq 'check') {
                $script:target = $result.resolution.target; $script:targetSource = $result.resolution.source
                $script:targetLabel.Text = $script:target; $script:sourceLabel.Text = '来源：' + $result.resolution.sourceLabel
                $script:plan = $result.plan; $script:dependencies = $result.tools
                $dependencyLines = @()
                foreach ($tool in $script:dependencies) {
                    $state = if ($tool.found) { "PATH 中发现：$($tool.path)（未运行）" } else { '当前 PATH 未发现，相关功能需另行准备；不影响基本安装' }
                    $dependencyLines += "$($tool.name)：$state"
                }
                if ($result.error) {
                    $script:statusLabel.Text = '发现已有配置或路径问题，无法安装。'
                    $script:logBox.Text = (@($result.error, '') + $dependencyLines) -join "`r`n"
                } else {
                    $lines = @("包版本：$($script:plan.packageVersion)；已校验 $($script:plan.verifiedPackageFiles) 个包文件。",
                        "将创建 $($script:plan.files.Count) 个配置文件；保留 $($script:plan.baseline.retainedFiles) 个状态文件。")
                    $lines += $dependencyLines
                    if ($script:plan.warnings.Count) { $lines += $script:plan.warnings }
                    $script:logBox.Text = $lines -join "`r`n"; $script:statusLabel.Text = '检查通过，请确认实际配置目录后安装。'
                }
            } else {
                $script:installed = $true; $script:statusLabel.Text = '安装完成。'
                $script:logBox.Text += "`r`n`r`n安装完成：创建 $($result.files) 个配置文件。`r`n配置目录：$($result.target)`r`n原有状态和缓存保留。请由您重新启动 mpv.net。"
                [void][Windows.Forms.MessageBox]::Show($script:form, "配置安装完成。`r`n$($result.target)", '安装完成', 'OK', 'Information')
            }
        } catch {
            $script:plan = $null; $script:statusLabel.Text = '检查或安装未完成。'; $script:logBox.Text = $_.Exception.Message
            if ($script:operation -eq 'install') { [void][Windows.Forms.MessageBox]::Show($script:form, $_.Exception.Message, '无法完成安装', 'OK', 'Error') }
        } finally { Dispose-Worker; $script:busy = $false; Update-Enabled }
        if ($SnapshotPath) { Save-InstallerSnapshot }
    })
    $script:playerBrowse.Add_Click({
        $dialog = New-Object Windows.Forms.OpenFileDialog
        try {
            $dialog.Title = '选择 mpvnet.exe'; $dialog.Filter = 'mpv.net 播放器 (mpvnet.exe)|mpvnet.exe'
            $dialog.CheckFileExists = $true
            if ($script:playerBox.Text -and [IO.File]::Exists($script:playerBox.Text)) { $dialog.FileName = $script:playerBox.Text }
            if ($dialog.ShowDialog($script:form) -eq 'OK') { $script:playerBox.Text = $dialog.FileName; Start-AutomaticCheck }
        } finally { $dialog.Dispose() }
    })
    $script:installButton.Add_Click({
        if (-not $script:plan -or $script:busy -or $script:installed) { return }
        $message = "将创建 $($script:plan.files.Count) 个配置文件。`r`n`r`n播放器：$($script:plan.player)`r`n配置目录：$($script:plan.target)`r`n来源：$($script:plan.targetSourceLabel)`r`n`r`n原有播放器状态和缓存保留，已有配置不会覆盖或合并。`r`n确认安装到这个目录？"
        if ([Windows.Forms.MessageBox]::Show($script:form, $message, '确认安装目录', 'YesNo', 'Question', 'Button2') -eq 'Yes') {
            try { Start-Work 'install' } catch { Dispose-Worker; $script:busy = $false; Update-Enabled; [void][Windows.Forms.MessageBox]::Show($script:form, $_.Exception.Message, '安装未启动', 'OK', 'Error') }
        }
    })
    $script:form.Add_FormClosing({ param($sender, $eventArgs)
        if ($script:busy) { $eventArgs.Cancel = $true; $script:statusLabel.Text = '正在处理，请等待完成后关闭窗口。' }
    })
    if ($PlayerPath) { $script:playerBox.Text = $PlayerPath }
    $script:form.Add_Shown({
        if ($script:playerBox.Text) { Start-AutomaticCheck }
        elseif ($SnapshotPath) { Save-InstallerSnapshot }
    })
    try { [void]$script:form.ShowDialog() } finally { $script:timer.Dispose(); $script:form.Dispose() }
} catch {
    try { [void][Windows.Forms.MessageBox]::Show($_.Exception.Message, 'mpv.net 配置包安装器', 'OK', 'Error') } catch { [Console]::Error.WriteLine($_.Exception.Message) }
    exit 1
}
