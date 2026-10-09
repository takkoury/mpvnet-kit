param(
    [Parameter(Mandatory=$true)][string]$PlayerPath,
    [string]$ConfigDirectory = '',
    [string]$PackageRoot = ''
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'common.psm1') -Force
function Read-PathOptions([string]$Root, [string]$Relative, [string[]]$Allowed) {
    $path = Get-KitPath $Root $Relative
    $values = @{}; $unknown = @()
    if ([IO.File]::Exists($path)) {
        foreach ($line in [IO.File]::ReadAllLines($path, [Text.Encoding]::UTF8)) {
            $text = $line.Trim()
            if (-not $text -or $text.StartsWith('#')) { continue }
            if ($text -notmatch '^([a-z_]+)=(.*)$') { throw "Invalid path option syntax in $Relative" }
            $name = $Matches[1]; $value = $Matches[2].Trim()
            if ($name -notin $Allowed) { $unknown += $name; continue }
            if ($values.ContainsKey($name)) { throw "Duplicate path option: $name" }
            if ($value.IndexOf([char]0) -ge 0) { throw 'NUL in path option.' }
            $values[$name] = $value
        }
    }
    return [pscustomobject]@{ values = $values; ignoredKeys = $unknown }
}
function Get-ToolPresence([string]$Value, [string]$Source, [switch]$AbsoluteOnly) {
    if ($AbsoluteOnly -and $Value -notmatch '^(?:[A-Za-z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+)') {
        return [ordered]@{ present = $false; path = $Value; source = $Source; version = $null; note = 'Local settings require an absolute path, not arguments.' }
    }
    $path = $null
    if ($Value -match '^(?:[A-Za-z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+)') {
        $candidate = Get-KitRoot $Value
        if ([IO.File]::Exists($candidate)) { $path = $candidate }
    } else {
        $command = Get-Command -Name $Value -CommandType Application -ErrorAction SilentlyContinue
        if ($command) { $path = $command.Source }
    }
    $version = if ($path) { ([Diagnostics.FileVersionInfo]::GetVersionInfo($path)).FileVersion } else { $null }
    return [ordered]@{ present = [bool]$path; path = $(if ($path) { $path } else { $Value }); source = $Source; version = $version;
        note = 'Presence and static metadata only; the executable was not launched.' }
}
try {
    if (-not $PackageRoot) { $PackageRoot = Split-Path -Parent $PSScriptRoot }
    $package = Get-KitPackage $PackageRoot
    $player = Get-KitPlayer $PlayerPath
    if (-not $ConfigDirectory) { $ConfigDirectory = Join-Path ([IO.Path]::GetDirectoryName($player)) 'portable_config' }
    $target = Get-KitRoot $ConfigDirectory
    $local = Read-PathOptions $target 'script-opts/mpvnet-local.conf' @('capture_root', 'ffmpeg_path', 'python_path', 'mpv_path')
    $bili = Read-PathOptions $target 'script-opts/bilibiliAssert.conf' @('python_path')
    $thumb = Read-PathOptions $target 'script-opts/thumbfast.conf' @('mpv_path')
    $ffmpeg = if ($local.values.ContainsKey('ffmpeg_path') -and $local.values['ffmpeg_path']) {
        Get-ToolPresence $local.values['ffmpeg_path'] 'local.ffmpeg_path' -AbsoluteOnly
    } else { Get-ToolPresence 'ffmpeg.exe' 'PATH' }
    $python = if ($local.values.ContainsKey('python_path') -and $local.values['python_path']) {
        Get-ToolPresence $local.values['python_path'] 'local.python_path' -AbsoluteOnly
    } elseif ($bili.values.ContainsKey('python_path') -and $bili.values['python_path']) {
        Get-ToolPresence $bili.values['python_path'] 'bilibiliAssert.conf'
    } else { Get-ToolPresence 'python' 'PATH' }
    $worker = if ($local.values.ContainsKey('mpv_path') -and $local.values['mpv_path']) {
        Get-ToolPresence $local.values['mpv_path'] 'local.mpv_path' -AbsoluteOnly
    } elseif ($thumb.values.ContainsKey('mpv_path') -and $thumb.values['mpv_path'] -and $thumb.values['mpv_path'] -ne 'mpv') {
        Get-ToolPresence $thumb.values['mpv_path'] 'thumbfast.conf'
    } else { Get-ToolPresence $player 'PlayerPath' -AbsoluteOnly }
    $windows = $env:SystemRoot
    if (-not $windows) { $windows = $env:WINDIR }
    $powershell = if ($windows) { Get-ToolPresence (Join-Path $windows 'System32/WindowsPowerShell/v1.0/powershell.exe') 'SystemRoot' -AbsoluteOnly } else { Get-ToolPresence 'powershell.exe' 'PATH' }
    $forms = $true
    try { Add-Type -AssemblyName System.Windows.Forms } catch { $forms = $false }
    $playerVersion = ([Diagnostics.FileVersionInfo]::GetVersionInfo($player)).FileVersion
    $dll = Join-Path ([IO.Path]::GetDirectoryName($player)) 'libmpv-2.dll'
    $mpvVersion = if ([IO.File]::Exists($dll)) { ([Diagnostics.FileVersionInfo]::GetVersionInfo($dll)).FileVersion } else { $null }
    $family = $playerVersion -and $playerVersion.StartsWith('7.1.2') -and $mpvVersion -and $mpvVersion -match '^v?0\.41\.'
    $capture = if ($local.values.ContainsKey('capture_root') -and $local.values['capture_root']) {
        Get-KitRoot $local.values['capture_root']
    } else { Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::MyPictures)) 'Capture' }
    Write-KitResult ([ordered]@{ mode = 'read-only'; verifiedPackageFiles = $package.verifiedFileCount; configDirectory = $target;
        player = [ordered]@{ path = $player; fileVersion = $playerVersion; libmpvFileVersion = $mpvVersion; recordedBaselineFamily = 'mpv.net 7.1.2 / libmpv 0.41'; baselineFamilyMatch = [bool]$family };
        powershell = $powershell; winFormsAssemblyAvailable = $forms; thumbnailWorker = $worker; ffmpeg = $ffmpeg; python = $python; captureRoot = $capture;
        effects = [ordered]@{ ffmpegMissing = 'Clip export unavailable; core UI, PNG and folder opening do not require FFmpeg.'; pythonMissing = 'Danmaku conversion unavailable; core UI does not require Python.' };
        ignoredLocalKeys = $local.ignoredKeys; limitation = 'Static checks only. Unknown versions are unvalidated, and metadata does not prove playback or codec capability.' })
} catch {
    Write-KitResult ([ordered]@{ status = 'refused-or-failed'; error = $_.Exception.Message })
    exit 1
}
