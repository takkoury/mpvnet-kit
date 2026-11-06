param(
    [Parameter(Mandatory=$true)][string]$SourcePath,
    [Parameter(Mandatory=$true)][string]$RequestPath,
    [Parameter(Mandatory=$true)][string]$EditorType
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
