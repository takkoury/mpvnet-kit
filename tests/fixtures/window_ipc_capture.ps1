param(
    [Parameter(Mandatory=$true)][string]$SourcePath,
    [Parameter(Mandatory=$true)][string]$RequestPath,
    [Parameter(Mandatory=$true)][string]$EditorType,
    [string]$BeforeRunSignal
)
$ErrorActionPreference = 'Stop'
$probe = @{ Checked = $false }

# Observe the real editor after its startup sends, before entering the hidden dispatcher.
function New-Object {
    param([string]$TypeName, [object[]]$ArgumentList)
    $value = Microsoft.PowerShell.Utility\New-Object @PSBoundParameters
    if ($TypeName -eq $EditorType) {
        try {
            $capture = $value.GetType().GetField('validationCommands', [Reflection.BindingFlags]'NonPublic,Instance')
            if ($null -ne $capture.GetValue($value)) { throw 'Normal IPC allocated validation capture.' }
            if ($BeforeRunSignal) {
                $fields = [Reflection.BindingFlags]'NonPublic,Instance'
                $value.GetType().GetField('timer', $fields).GetValue($value).Stop()
                $deadline = [DateTime]::UtcNow.AddSeconds(5)
                while (-not [IO.File]::Exists($BeforeRunSignal)) {
                    if ([DateTime]::UtcNow -ge $deadline) { throw 'before-run-signal-timeout' }
                    Start-Sleep -Milliseconds 10
                }
                $pending = $value.GetType().GetField('read', $fields).GetValue($value)
                if (-not $pending.Wait(5000)) { throw 'before-run-read-timeout' }
            }
            $probe.Checked = $true
        } catch {
            $value.Finish()
            throw
        }
    }
    $value
}

& $SourcePath -RequestPath $RequestPath -NoShow
if (-not $? -or -not $probe.Checked) { exit 1 }
