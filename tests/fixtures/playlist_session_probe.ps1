param(
    [Parameter(Mandatory=$true)][string]$SourcePath,
    [Parameter(Mandatory=$true)][string]$ArtifactDirectory,
    [Parameter(Mandatory=$true)][ValidateSet('EarlyEof','ReadyEof','ClientClose','Shutdown','ParentExit')][string]$Mode
)
$ErrorActionPreference = 'Stop'
$encoding = New-Object Text.UTF8Encoding($false)
$powershell = Join-Path $PSHOME 'powershell.exe'
$pipeName = 'mpvnet-playlist-fixture-' + [Guid]::NewGuid().ToString('N')
$token = "$PID-$([DateTime]::UtcNow.Ticks)"
$request = Join-Path $ArtifactDirectory "mpvnet-playlist-$token.json"
$server = $reader = $writer = $helper = $ownedParent = $null

function Read-PlaylistCommand {
    $read = $reader.ReadLineAsync()
    if (-not $read.Wait(5000) -or $null -eq $read.Result) { throw 'playlist command not received' }
    $read.Result | ConvertFrom-Json
}

try {
    $server = New-Object IO.Pipes.NamedPipeServerStream($pipeName, [IO.Pipes.PipeDirection]::InOut, 1,
        [IO.Pipes.PipeTransmissionMode]::Byte, [IO.Pipes.PipeOptions]::Asynchronous)
    $connect = $server.WaitForConnectionAsync()
    $parentId = $PID
    if ($Mode -eq 'ParentExit') {
        $parentStart = New-Object Diagnostics.ProcessStartInfo
        $parentStart.FileName = $powershell
        $parentStart.Arguments = '-NoProfile -Command "[Console]::ReadLine() | Out-Null"'
        $parentStart.UseShellExecute = $false
        $parentStart.CreateNoWindow = $true
        $parentStart.RedirectStandardInput = $true
        $ownedParent = [Diagnostics.Process]::Start($parentStart)
        $parentId = $ownedParent.Id
    }
    [IO.File]::WriteAllText($request, (@{pipe=$pipeName; parent_pid=$parentId; script='playlist_controls';
        token=$token; visible=$false} | ConvertTo-Json -Compress), $encoding)
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $powershell
    $start.Arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "' + $SourcePath + '" -NoShow -PayloadPath "' + $request + '"'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = $encoding
    $start.StandardErrorEncoding = $encoding
    $start.EnvironmentVariables['TEMP'] = $ArtifactDirectory
    $start.EnvironmentVariables['TMP'] = $ArtifactDirectory
    $helper = [Diagnostics.Process]::Start($start)
    $helperOut = $helper.StandardOutput.ReadToEndAsync()
    $helperErr = $helper.StandardError.ReadToEndAsync()
    if (-not $connect.Wait(15000)) { throw 'playlist helper connection timed out' }
    $reader = New-Object IO.StreamReader($server, $encoding, $false, 1024, $true)
    $writer = New-Object IO.StreamWriter($server, $encoding, 1024, $true)
    $writer.AutoFlush = $true
    for ($id = 1; $id -le 6; $id++) {
        $command = Read-PlaylistCommand
        if ($command.request_id -ne $id) { throw 'unexpected playlist command sequence' }
    }
    $ready = $false
    if ($Mode -ne 'EarlyEof') {
        if ($Mode -eq 'ClientClose') {
            $writer.WriteLine('{"event":"client-message","args":["mpvnet-playlist-close","wrong-token"]}')
        }
        $writer.WriteLine('{"event":"property-change","name":"playlist","data":[]}')
        $command = (Read-PlaylistCommand).command
        if ($command[2] -ne 'helper-ready' -or $command[3] -ne $token) { throw 'playlist helper did not become ready' }
        $ready = $true
    }
    switch ($Mode) {
        'EarlyEof' { $server.Dispose() }
        'ReadyEof' { $server.Dispose() }
        'ClientClose' { $writer.WriteLine((@{event='client-message'; args=@('mpvnet-playlist-close',$token)} | ConvertTo-Json -Compress)) }
        'Shutdown' { $writer.WriteLine('{"event":"shutdown"}') }
        'ParentExit' {
            $ownedParent.StandardInput.WriteLine('exit')
            if (-not $ownedParent.WaitForExit(5000)) { throw 'fixture parent exit timed out' }
        }
    }
    if (-not $helper.WaitForExit(5000)) { throw 'playlist helper exit timed out' }
    @{mode=$Mode; ready=$ready; helper_exit=$helper.ExitCode; helper_reply=($helperOut.Result | ConvertFrom-Json);
        helper_error=$helperErr.Result} | ConvertTo-Json -Compress -Depth 5
} finally {
    if ($helper) { if (-not $helper.HasExited) { $helper.Kill(); $helper.WaitForExit() }; $helper.Dispose() }
    if ($ownedParent) { if (-not $ownedParent.HasExited) { $ownedParent.Kill(); $ownedParent.WaitForExit() }; $ownedParent.Dispose() }
    if ($writer -and $server.IsConnected) { $writer.Dispose() }
    if ($reader) { $reader.Dispose() }
    if ($server) { $server.Dispose() }
    if ([IO.File]::Exists($request)) { [IO.File]::Delete($request) }
}
