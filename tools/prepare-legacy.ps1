[CmdletBinding(DefaultParameterSetName='Prepare')]
param(
    [Parameter(Mandatory=$true, ParameterSetName='Prepare')][string]$PlayerPath,
    [Parameter(ParameterSetName='Prepare')][string]$ConfigDirectory = '',
    [Parameter(ParameterSetName='Prepare')][string]$BackupRoot = '',
    [Parameter(ParameterSetName='Prepare')][string]$PackageRoot = '',
    [Parameter(ParameterSetName='Prepare')][switch]$Apply,
    [Parameter(ParameterSetName='Prepare')][string]$ExpectedPlanToken = '',
    [Parameter(Mandatory=$true, ParameterSetName='Snapshot')][string]$SnapshotManifest,
    [ValidateSet('Json', 'Text')][string]$OutputFormat = 'Json',
    [switch]$Details
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'legacy-install.psm1')
try {
    if ($PSCmdlet.ParameterSetName -eq 'Snapshot') { $result = Test-KitLegacySnapshot -SnapshotManifest $SnapshotManifest }
    else {
        if (-not $PackageRoot) { $PackageRoot = Split-Path -Parent $PSScriptRoot }
        $result = Invoke-KitLegacyBackup -PlayerPath $PlayerPath -ConfigDirectory $ConfigDirectory -BackupRoot $BackupRoot -PackageRoot $PackageRoot -Apply:$Apply -ExpectedPlanToken $ExpectedPlanToken
    }
    Write-KitLegacyResult $result -OutputFormat $OutputFormat -Details:$Details
} catch {
    Write-KitLegacyResult ([ordered]@{ status = 'refused-or-failed'; error = $_.Exception.Message }) -OutputFormat $OutputFormat -Details:$Details
    exit 1
}
