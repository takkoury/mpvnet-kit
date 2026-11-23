param(
    [Parameter(Mandatory=$true,ParameterSetName='Existing')][string]$PlayerPath,
    [Parameter(Mandatory=$true,ParameterSetName='NewPlayer')][string]$InstallDirectory,
    [Parameter(ParameterSetName='Existing')][string]$ConfigDirectory = '',
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
    if ($InstallDirectory) {
        Import-Module (Join-Path $PSScriptRoot 'portable-install.psm1')
        $portable = @{ InstallDirectory = $InstallDirectory; PackageRoot = $PackageRoot; BackupRoot = $BackupRoot }
        if ($Operation -eq 'Inspect') { $result = Get-KitPortablePlan @portable }
        elseif ($Operation -eq 'Apply') { $result = Invoke-KitPortableInstall @portable -ExpectedPlanToken $ExpectedPlanToken }
        else { throw '还原或恢复配置时，请通过 PlayerPath 选择已安装的 mpvnet.exe。' }
    } elseif ($Operation -eq 'Inspect') {
        $result = Get-KitMaintenancePlan -PlayerPath $PlayerPath -ConfigDirectory $ConfigDirectory -BackupRoot $BackupRoot -PackageRoot $PackageRoot
    } else {
        $result = Invoke-KitMaintenance -PlayerPath $PlayerPath -ConfigDirectory $ConfigDirectory -BackupRoot $BackupRoot -PackageRoot $PackageRoot -Operation $Operation -ExpectedPlanToken $ExpectedPlanToken
    }
    Write-KitMaintenanceResult $result -OutputFormat $OutputFormat -Details:$Details
} catch {
    Write-KitMaintenanceResult ([ordered]@{ status = 'refused-or-failed'; error = $_.Exception.Message }) -OutputFormat $OutputFormat -Details:$Details
    exit 1
}
