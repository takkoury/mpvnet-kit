param([Parameter(Mandatory=$true)][string]$RequestPath, [switch]$ValidateOnly)
$ErrorActionPreference = 'Stop'
$ownedRequest = $null
try {
    if (-not [IO.Path]::IsPathRooted($RequestPath)) { throw 'Expected an absolute request path.' }
    $fullRequest = [IO.Path]::GetFullPath($RequestPath)
    $tempRoots = @($env:TEMP, $env:TMP) | Where-Object { $_ -and $_ -match '^(?:[A-Za-z]:[\\/]|\\\\)' } |
        ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd([char[]]'\/') }
    $directory = [IO.Path]::GetDirectoryName($fullRequest).TrimEnd([char[]]'\/')
    if ($directory -notin $tempRoots -or [IO.Path]::GetFileName($fullRequest) -notlike 'mpvnet-path-*.json') {
        throw 'Expected an owned temporary request.'
    }
    $ownedRequest = $fullRequest
    $json = [IO.File]::ReadAllText($ownedRequest, [Text.Encoding]::UTF8)
    Remove-Item -LiteralPath $ownedRequest
    $request = $json | ConvertFrom-Json
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.UseShellExecute = $true
    switch ([string]$request.operation) {
        'reveal' {
            $item = Get-Item -LiteralPath ([string]$request.address)
            if ($item.PSIsContainer) { throw 'Expected a file.' }
            $start.FileName = 'explorer.exe'
            $start.Arguments = '/select,"' + $item.FullName + '"'
        }
        'url' {
            $uri = $null
            if (-not [Uri]::TryCreate([string]$request.address, [UriKind]::Absolute, [ref]$uri) -or
                $uri.Scheme -notin @('http', 'https') -or $uri.UserInfo -or
                [string]$request.address -match '[\s\x00-\x1F]') { throw 'Unsupported URL.' }
            $start.FileName = [string]$request.address
        }
        default { throw 'Unsupported operation.' }
    }
    if ($ValidateOnly) { Write-Output 'MEDIA PATH ACTION VALID'; exit 0 }
    [void][System.Diagnostics.Process]::Start($start)
    exit 0
}
catch { [Console]::Error.WriteLine('MEDIA PATH ACTION FAILED'); exit 1 }
finally { if ($ownedRequest) { Remove-Item -LiteralPath $ownedRequest -ErrorAction SilentlyContinue } }
