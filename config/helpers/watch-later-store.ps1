param(
    [Parameter(Mandatory=$true)][string]$Path
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$maxFiles = 2048
$maxFileBytes = 64KB
$maxBytes = 2MB
$utf8 = New-Object Text.UTF8Encoding($false, $true)
$epoch = [DateTime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)

function Read-WatchLaterStore {
    $entries = New-Object 'System.Collections.Generic.List[IO.FileInfo]'
    $enumerator = $null
    try {
        # Enumerate one level of the literal directory and bound the work even
        # when the configured path has many unrelated files.
        $enumerator = [IO.DirectoryInfo]::new($Path).EnumerateFiles().GetEnumerator()
        while ($enumerator.MoveNext()) {
            if ($entries.Count -ge $maxFiles) { return @{ok=$false; code='too_many'} }
            $entries.Add($enumerator.Current)
        }
    } catch {
        if ($_.Exception.GetBaseException() -is [IO.DirectoryNotFoundException]) {
            return @{ok=$true; missing=$true}
        }
        return @{ok=$false; code='io'}
    } finally {
        if ($null -ne $enumerator) { $enumerator.Dispose() }
    }

    $files = New-Object 'System.Collections.Generic.List[object]'
    $skipped = @{io=0; encoding=0; too_large=0}
    $bytesRead = 0
    # If the total byte limit is reached, prefer newer records.
    foreach ($entry in ($entries | Sort-Object @{Expression='LastWriteTimeUtc'; Descending=$true}, Name)) {
        $stream = $null
        try {
            if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                $skipped.io++
                continue
            }
            $stream = [IO.File]::Open($entry.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            $length = $stream.Length
            if ($length -gt $maxFileBytes -or $bytesRead + $length -gt $maxBytes) {
                $skipped.too_large++
                continue
            }
            $bytesRead += $length
            $mtime = ([IO.File]::GetLastWriteTimeUtc($entry.FullName) - $epoch).TotalSeconds
            $bytes = New-Object byte[] ([int]$length)
            $offset = 0
            while ($offset -lt $bytes.Length) {
                $count = $stream.Read($bytes, $offset, $bytes.Length - $offset)
                if ($count -eq 0) { throw [IO.IOException]::new('Incomplete read') }
                $offset += $count
            }
            $content = $utf8.GetString($bytes)
            # mpv's JSON interface transports C strings.
            if ($content.IndexOf([char]0) -ge 0) {
                $skipped.encoding++
                continue
            }
            $files.Add(@{name=$entry.Name; content=$content; mtime=$mtime})
        } catch {
            if ($_.Exception.GetBaseException() -is [Text.DecoderFallbackException]) {
                $skipped.encoding++
            } else {
                $skipped.io++
            }
        } finally {
            if ($null -ne $stream) { $stream.Dispose() }
        }
    }
    return @{ok=$true; files=$files.ToArray(); skipped=$skipped}
}

try { $reply = Read-WatchLaterStore } catch { $reply = @{ok=$false; code='io'} }
[Console]::WriteLine(($reply | ConvertTo-Json -Depth 4 -Compress))
