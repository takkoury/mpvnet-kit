param(
    [int]$ParentPid,
    [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$payload = [Console]::In.ReadToEnd() | ConvertFrom-Json
$allowedLabels = @('TITLE', 'DURATION', 'VIDEO FORMAT', 'RESOLUTION', 'FRAME RATE', 'AUDIO CODEC', 'SAMPLE RATE', 'CHANNELS')
$lines = foreach ($field in $payload.fields) {
    if ($allowedLabels -notcontains [string]$field.label) { throw 'Unknown media information field.' }
    '{0}: {1}' -f $field.label, [string]$field.value
}
$text = $lines -join [Environment]::NewLine

if ($ValidateOnly) {
    [Console]::Out.WriteLine($text)
    exit 0
}

# Retain the original Process object so PID reuse cannot attach this window to a new process.
try { $parentProcess = [System.Diagnostics.Process]::GetProcessById($ParentPid) }
catch { exit 0 }
if ($parentProcess.HasExited) { $parentProcess.Dispose(); exit 0 }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Media Information'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(640, 420)
$form.MinimumSize = New-Object System.Drawing.Size(360, 240)

$content = New-Object System.Windows.Forms.TextBox
$content.Multiline = $true
$content.ReadOnly = $true
$content.WordWrap = $false
$content.ScrollBars = 'Both'
$content.Dock = 'Fill'
$content.Font = New-Object System.Drawing.Font('Consolas', 11)
$content.Text = $text
$form.Controls.Add($content)

$footer = New-Object System.Windows.Forms.FlowLayoutPanel
$footer.Dock = 'Bottom'
$footer.Height = 48
$footer.FlowDirection = 'RightToLeft'
$footer.Padding = New-Object System.Windows.Forms.Padding(9)
$close = New-Object System.Windows.Forms.Button
$close.Text = 'Close'
$close.Size = New-Object System.Drawing.Size(90, 30)
$close.Add_Click({ $form.Close() })
$footer.Controls.Add($close)
$form.Controls.Add($footer)
$form.CancelButton = $close

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500
$timer.Add_Tick({
    try { if ($parentProcess.HasExited) { $form.Close() } }
    catch { $form.Close() }
})
try {
    $timer.Start()
    [void]$form.ShowDialog()
}
finally {
    $timer.Stop()
    $timer.Dispose()
    $form.Dispose()
    $parentProcess.Dispose()
}
