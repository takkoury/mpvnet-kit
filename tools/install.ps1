param(
    [Parameter(Mandatory=$true)][string]$PlayerPath,
    [string]$ConfigDirectory = '',
    [string]$BackupRoot = '',
    [string]$PackageRoot = '',
    [switch]$Apply
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'common.psm1') -Force
try {
    if (-not $PackageRoot) { $PackageRoot = Split-Path -Parent $PSScriptRoot }
    Write-KitResult (Invoke-KitInstall -PlayerPath $PlayerPath -ConfigDirectory $ConfigDirectory -BackupRoot $BackupRoot -PackageRoot $PackageRoot -Apply:$Apply)
} catch {
    Write-KitResult ([ordered]@{ status = 'refused-or-failed'; error = $_.Exception.Message })
    exit 1
}
