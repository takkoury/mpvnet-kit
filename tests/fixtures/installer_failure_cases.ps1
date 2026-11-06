param([Parameter(Mandatory=$true)][string]$SourceRoot)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
$source = [IO.File]::ReadAllText((Join-Path $SourceRoot 'tools/installer.ps1'))
$needle = '    try { [void]$script:form.ShowDialog() }'
if (-not $source.Contains($needle)) { throw 'Installer fixture hook missing.' }
$probe = @'
    try {
        $results = @()
        foreach ($message in @('Package checksum mismatch: config/字幕.lua',
                'Backup checksum mismatch: files/字幕.lua', 'Package checksum mismatch: config/test.lua',
                'Package checksum mismatch: config/script-modules/mpvnet-paths.lua',
                'Package checksum mismatch: config/backup.lua', 'Invalid path: C:/package/配置',
                'Access denied', '配置目录不可访问：D:/backup/配置')) {
            Set-Failure '检查未完成，请查看详情' $message
            $reason = Get-KitMaintenanceReason $message
            $results += @{ input=$message; reason=$reason; summary=$script:reasonLabel.Text;
                details=$script:logBox.Text; shown=$script:form.Visible; state=$script:resultState }
        }
        $raw = @{status='refused-or-failed';error='Package checksum mismatch: config/字幕.lua'}
        $outputs = @{}
        foreach ($mode in @('Text','Details','Json')) {
            $original = [Console]::Out
            $capture = New-Object IO.StringWriter
            try {
                [Console]::SetOut($capture)
                if ($mode -eq 'Json') { Write-KitMaintenanceResult $raw }
                else { Write-KitMaintenanceResult $raw -OutputFormat Text -Details:($mode -eq 'Details') }
                $outputs[$mode] = $capture.ToString()
            } finally { [Console]::SetOut($original); $capture.Dispose() }
        }
        $script:probeResult = @{cases=$results; output=$outputs}
    }
'@
$source = $source.Replace($needle, $probe)
$source = $source.Replace('$PSScriptRoot', ("'" + (Join-Path $SourceRoot 'tools').Replace("'", "''") + "'"))
# Failures in this fixture must never open a modal error window.
$source = $source.Replace("try { [void][Windows.Forms.MessageBox]::Show(`$_.Exception.Message, 'mpv.net 配置包安装器', 'OK', 'Error') } catch { [Console]::Error.WriteLine(`$_.Exception.Message) }", 'throw')
& ([scriptblock]::Create($source)) -PackageRoot $SourceRoot
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$script:probeResult | ConvertTo-Json -Depth 6 -Compress
