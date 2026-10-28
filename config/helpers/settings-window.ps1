param(
    [Parameter(Mandatory = $true)][string]$RequestPath,
    [switch]$ValidateOnly,
    [switch]$NoShow
)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false)
$outputWriter = New-Object IO.StreamWriter([Console]::OpenStandardOutput(), $utf8)
$outputWriter.AutoFlush = $true
$editor = $null
try {
    Add-Type -AssemblyName System.Web.Extensions, PresentationFramework, PresentationCore, WindowsBase
    $references = @('System.Web.Extensions', 'System.Core', 'System.Xaml',
        [Windows.Window].Assembly.Location, [Windows.Media.Brushes].Assembly.Location,
        [Windows.Threading.Dispatcher].Assembly.Location)
    Add-Type -ReferencedAssemblies $references -Path @(
        (Join-Path $PSScriptRoot 'user-preferences-storage.cs'),
        (Join-Path $PSScriptRoot 'settings-window.cs'))
    $request = [UserPreferencesStorage]::Request($RequestPath)
    $editor = New-Object SettingsEditor($request, [bool]$ValidateOnly, [bool]$NoShow)
    if ($ValidateOnly) {
        $outputWriter.WriteLine([UserPreferencesStorage]::Json().Serialize($editor.Validate($request)))
    } else { $editor.Run() }
} catch {
    $outputWriter.WriteLine([UserPreferencesStorage]::Json().Serialize(@{ok=$false; error=$_.Exception.Message}))
    exit 1
} finally { if ($null -ne $editor) { $editor.Finish() } }
