param([Parameter(Mandatory=$true)][Uri]$Destination)

# GetProxy returns the destination itself for a direct connection or bypass.
# Only hand back an HTTP proxy authority suitable for both mpv and yt-dlp.
$ErrorActionPreference = 'Stop'
try {
    $proxy = [Net.WebRequest]::GetSystemWebProxy().GetProxy($Destination)
    if ($proxy -and $proxy -ne $Destination -and $proxy.Scheme -eq 'http' -and
        !$proxy.UserInfo -and $proxy.AbsolutePath -eq '/' -and !$proxy.Query -and !$proxy.Fragment) {
        [Console]::Write($proxy.GetLeftPart([UriPartial]::Authority))
    }
} catch {
    exit 1
}
