param(
    [Parameter(Mandatory=$true)][ValidateSet('Read','Clear')][string]$Operation,
    [Parameter(Mandatory=$true)][string]$Path,
    [string]$ExpectedHash
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$maxBytes = 2MB

function Invoke-HistoryStore {
    $clear = $Operation -eq 'Clear'
    if ($clear -and $ExpectedHash -notmatch '\A[0-9a-fA-F]{64}\z') {
        return @{ok=$false; code='conflict'}
    }
    $stream = $null
    $sha = $null
    $mutationStarted = $false
    try {
        # Open existing literal paths only. Denying writers during the snapshot
        # makes the bytes and their hash agree. Clear denies all sharing until
        # its compare and truncate have both completed on the same handle.
        $access = if ($clear) { [IO.FileAccess]::ReadWrite } else { [IO.FileAccess]::Read }
        $sharing = if ($clear) { [IO.FileShare]::None } else { [IO.FileShare]::Read }
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, $access, $sharing)
        if ($stream.Length -gt $maxBytes) { return @{ok=$false; code='too_large'} }
        $sha = [Security.Cryptography.SHA256]::Create()
        if ($clear) {
            $hash = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '')
            if ($hash -ine $ExpectedHash) { return @{ok=$false; code='conflict'} }
            $mutationStarted = $true
            $stream.SetLength(0)
            $stream.Flush()
            if ($stream.Length -ne 0) { return @{ok=$false; code='uncertain'} }
            return @{ok=$true}
        }

        $bytes = New-Object byte[] ([int]$stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $count = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($count -eq 0) { return @{ok=$false; code='io'} }
            $offset += $count
        }
        $stream.Dispose()
        $stream = $null
        $utf8 = New-Object Text.UTF8Encoding($false, $true)
        $content = $utf8.GetString($bytes)
        # mpv's JSON reader transports C strings. Reject literal NUL bytes
        # instead of returning a snapshot silently cut at the first one.
        if ($content.IndexOf([char]0) -ge 0) { return @{ok=$false; code='encoding'} }
        $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '')
        return @{ok=$true; content=$content; hash=$hash}
    } catch {
        if ($mutationStarted) { return @{ok=$false; code='uncertain'} }
        $cause = $_.Exception.GetBaseException()
        if ($cause -is [IO.FileNotFoundException] -or $cause -is [IO.DirectoryNotFoundException]) {
            if ($clear) { return @{ok=$false; code='conflict'} }
            return @{ok=$true; missing=$true}
        }
        if ($cause -is [Text.DecoderFallbackException]) { return @{ok=$false; code='encoding'} }
        return @{ok=$false; code='io'}
    } finally {
        if ($null -ne $sha) { $sha.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

try { $reply = Invoke-HistoryStore } catch {
    # A cleanup error must not print a path or claim the bytes were retained.
    $code = if ($Operation -eq 'Clear') { 'uncertain' } else { 'io' }
    $reply = @{ok=$false; code=$code}
}
[Console]::WriteLine(($reply | ConvertTo-Json -Compress))
