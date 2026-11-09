param([Parameter(Mandatory=$true)][string]$Runtime,[Parameter(Mandatory=$true)][string]$FixtureAssembly,[string]$Case,[string]$Directory,[switch]$Build)
$ErrorActionPreference='Stop'
$writer=New-Object IO.StreamWriter([Console]::OpenStandardOutput(),(New-Object Text.UTF8Encoding($false)))
$writer.AutoFlush=$true
try {
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Web.Extensions
    [void][Reflection.Assembly]::LoadFrom($Runtime)
    if($Build) {
        # Windows PowerShell Add-Type resolves .exe references as assembly names.
        # A byte-identical temporary .dll gives its compiler a file reference.
        $runtimeReference=Join-Path (Split-Path -Parent $FixtureAssembly) 'KitUpdate.dll'
        [IO.File]::Copy($Runtime,$runtimeReference)
        Add-Type -Path (Join-Path $PSScriptRoot 'update_check_cases.cs') -OutputAssembly $FixtureAssembly -ReferencedAssemblies @(
            $runtimeReference,'System.Core','System.Xaml','System.Web.Extensions', [Windows.Window].Assembly.Location,
            [Windows.Media.Brushes].Assembly.Location,[Windows.Threading.Dispatcher].Assembly.Location)
        $writer.WriteLine('{"ok":true}')
    } else {
        [void][Reflection.Assembly]::LoadFrom($FixtureAssembly)
        $writer.WriteLine([UpdateData]::Json().Serialize([UpdateCases]::Run($Case,$Directory)))
    }
} catch {
    $writer.WriteLine($_.Exception.ToString())
    exit 1
}
