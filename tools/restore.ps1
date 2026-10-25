param(
    [Parameter(Mandatory=$true)][string]$BackupManifest,
    [switch]$Apply,
    [ValidateSet('Json', 'Text')][string]$OutputFormat = 'Json',
    [switch]$Details
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'common.psm1') -Force
try { Write-KitResult (Invoke-KitRestore -BackupManifest $BackupManifest -Apply:$Apply) -OutputFormat $OutputFormat -Details:$Details }
catch {
    Write-KitResult ([ordered]@{ status = 'refused-or-failed'; error = $_.Exception.Message }) -OutputFormat $OutputFormat -Details:$Details
    exit 1
}
