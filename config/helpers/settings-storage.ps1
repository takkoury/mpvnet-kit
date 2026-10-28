param(
    [Parameter(Mandatory = $true)][ValidateSet('Save', 'SaveLocal')][string]$Operation,
    [Parameter(Mandatory = $true)][string]$RequestPath
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false)
$outputWriter = New-Object IO.StreamWriter([Console]::OpenStandardOutput(), $utf8)
$outputWriter.AutoFlush = $true
$exitCode = 0
try {
    Add-Type -AssemblyName System.Web.Extensions
    $source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'user-preferences-storage.cs'), $utf8)
    Add-Type -ReferencedAssemblies System.Web.Extensions -TypeDefinition $source
    $request = [UserPreferencesStorage]::Request($RequestPath)
    if ($Operation -eq 'SaveLocal') { $result = [UserPreferencesStorage]::SaveLocal($request) }
    else { $result = [UserPreferencesStorage]::Save($request) }
    $outputWriter.WriteLine([UserPreferencesStorage]::Json().Serialize($result))
    if (-not $result.ok) { $exitCode = 1 }
} catch {
    $message = $_.Exception.Message
    if ($_.Exception.InnerException) { $message = $_.Exception.InnerException.Message }
    $outputWriter.WriteLine((@{ok = $false; error = $message; conflict = $false} | ConvertTo-Json -Compress))
    $exitCode = 1
} finally {
    $outputWriter.Dispose()
}
exit $exitCode
