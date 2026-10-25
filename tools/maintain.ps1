param(
    [Parameter(Mandatory=$true)][string]$PlayerPath,
    [string]$ConfigDirectory = '',
    [string]$BackupRoot = '',
    [string]$PackageRoot = '',
    [ValidateSet('Inspect', 'Apply', 'Restore', 'Recover')][string]$Operation = 'Inspect',
    [string]$ExpectedPlanToken = '',
    [ValidateSet('Json', 'Text')][string]$OutputFormat = 'Json',
    [switch]$Details
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'maintenance.psm1')
try {
    if (-not $PackageRoot) { $PackageRoot = Split-Path -Parent $PSScriptRoot }
    if ($Operation -eq 'Inspect') {
        $result = Get-KitMaintenancePlan -PlayerPath $PlayerPath -ConfigDirectory $ConfigDirectory -BackupRoot $BackupRoot -PackageRoot $PackageRoot
    } else {
        $result = Invoke-KitMaintenance -PlayerPath $PlayerPath -ConfigDirectory $ConfigDirectory -BackupRoot $BackupRoot -PackageRoot $PackageRoot -Operation $Operation -ExpectedPlanToken $ExpectedPlanToken
    }
    Write-KitMaintenanceResult $result -OutputFormat $OutputFormat -Details:$Details
} catch {
    Write-KitMaintenanceResult ([ordered]@{ status = 'refused-or-failed'; error = $_.Exception.Message }) -OutputFormat $OutputFormat -Details:$Details
    exit 1
}
