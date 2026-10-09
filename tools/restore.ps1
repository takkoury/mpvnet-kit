param(
    [Parameter(Mandatory=$true)][string]$BackupManifest,
    [switch]$Apply
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'common.psm1') -Force
try { Write-KitResult (Invoke-KitRestore -BackupManifest $BackupManifest -Apply:$Apply) }
catch {
    Write-KitResult ([ordered]@{ status = 'refused-or-failed'; error = $_.Exception.Message })
    exit 1
}
