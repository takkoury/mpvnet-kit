param([Parameter(Mandatory=$true)][string]$SourcePath, [ValidateSet('ClientClose','ParentExit')][string]$Mode = 'ClientClose')
$ErrorActionPreference = 'Stop'
$encoding = New-Object Text.UTF8Encoding($false)
$output = New-Object IO.StreamWriter([Console]::OpenStandardOutput(), $encoding)
$output.AutoFlush = $true
$ownedFolder = Join-Path ([IO.Path]::GetTempPath()) ('mpvnet-shortcuts-ipc-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($ownedFolder)
$server = $null
$helperProcess = $null
$ownedParent = $null
try {
    $pipeName = 'mpvnet-shortcuts-fixture-' + [Guid]::NewGuid().ToString('N')
    $server = New-Object IO.Pipes.NamedPipeServerStream($pipeName, [IO.Pipes.PipeDirection]::InOut, 1,
        [IO.Pipes.PipeTransmissionMode]::Byte, [IO.Pipes.PipeOptions]::Asynchronous)
    $connect = $server.WaitForConnectionAsync()
    $parentId = $PID
    if ($Mode -eq 'ParentExit') {
        $parentStart = New-Object Diagnostics.ProcessStartInfo
        $parentStart.FileName = 'powershell.exe'
        $parentStart.Arguments = '-NoProfile -Command "[Console]::ReadLine() | Out-Null"'
        $parentStart.UseShellExecute = $false
        $parentStart.CreateNoWindow = $true
        $parentStart.RedirectStandardInput = $true
        $ownedParent = [Diagnostics.Process]::Start($parentStart)
        $parentId = $ownedParent.Id
    }
    $token = 'fixture-token-123'
    $request = Join-Path $ownedFolder 'editor-request.json'
    [IO.File]::WriteAllText($request, (@{schema=1;pipe=$pipeName;parent_pid=$parentId;script='user_shortcuts';token=$token;
        settings_path=(Join-Path $ownedFolder 'mpvnet-user.json')} | ConvertTo-Json -Compress), $encoding)
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = 'powershell.exe'
    $start.Arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "' + $SourcePath + '" -Operation Editor -RequestPath "' + $request + '" -NoShow'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = $encoding
    $start.StandardErrorEncoding = $encoding
    $helperProcess = [Diagnostics.Process]::Start($start)
    $helperOut = $helperProcess.StandardOutput.ReadToEndAsync()
    $helperErr = $helperProcess.StandardError.ReadToEndAsync()
    if (-not $connect.Wait(10000)) { throw 'helper-connect-timeout' }
    $reader = New-Object IO.StreamReader($server, $encoding)
    $writer = New-Object IO.StreamWriter($server, $encoding)
    $writer.AutoFlush = $true
    $messages = New-Object 'Collections.Generic.List[object]'
    for ($count=0; $count -lt 3; $count++) {
        $read = $reader.ReadLineAsync()
        if (-not $read.Wait(5000)) { throw 'ready-timeout' }
        $messages.Add(($read.Result | ConvertFrom-Json))
    }
    $ready = @($messages | Where-Object { $_.command[2] -eq 'editor-ready' })
    if ($ready.Count -ne 1 -or $ready[0].command[3] -ne $token) { throw 'ready-protocol' }
    $wrong = @{event='client-message';args=@('mpvnet-shortcuts-close','different-token')} | ConvertTo-Json -Compress
    $writer.WriteLine($wrong)
    Start-Sleep -Milliseconds 250
    $wrongTokenIgnored = -not $helperProcess.HasExited
    if (-not $wrongTokenIgnored) { throw 'wrong-token-closed-helper' }
    if ($Mode -eq 'ClientClose') {
        $writer.WriteLine((@{event='client-message';args=@('mpvnet-shortcuts-show',$token)} | ConvertTo-Json -Compress))
        $writer.WriteLine((@{event='client-message';args=@('mpvnet-shortcuts-close',$token)} | ConvertTo-Json -Compress))
    } else {
        $ownedParent.StandardInput.WriteLine('exit')
        if (-not $ownedParent.WaitForExit(5000)) { throw 'owned-parent-exit-timeout' }
    }
    $read = $reader.ReadLineAsync()
    if (-not $helperProcess.WaitForExit(5000)) { throw ('helper-exit-timeout; notification=' + $read.IsCompleted) }
    if (-not $read.Wait(5000)) { throw 'close-notification-timeout' }
    $close = $read.Result | ConvertFrom-Json
    $reply = $helperOut.Result | ConvertFrom-Json
    if ($helperProcess.ExitCode -ne 0 -or -not $reply.ok -or $helperErr.Result) { throw ('helper-failed: ' + $helperOut.Result + ' ' + $helperErr.Result) }
    $output.WriteLine((@{ok=$true;wrong_token_ignored=$wrongTokenIgnored;ready=$ready[0].command;close=$close.command;
        helper_exit=$helperProcess.ExitCode;mode=$Mode;settings_untouched=(-not [IO.File]::Exists((Join-Path $ownedFolder 'mpvnet-user.json')))} | ConvertTo-Json -Compress -Depth 6))
} catch {
    $output.WriteLine((@{ok=$false;error=$_.Exception.Message} | ConvertTo-Json -Compress))
    exit 1
} finally {
    if ($helperProcess) { if (-not $helperProcess.HasExited) { $helperProcess.Kill(); $helperProcess.WaitForExit() }; $helperProcess.Dispose() }
    if ($ownedParent) { if (-not $ownedParent.HasExited) { $ownedParent.StandardInput.WriteLine('exit'); [void]$ownedParent.WaitForExit(5000) }; $ownedParent.Dispose() }
    if ($server) { $server.Dispose() }
    $ownedRequest = Join-Path $ownedFolder 'editor-request.json'
    if ([IO.File]::Exists($ownedRequest)) { [IO.File]::Delete($ownedRequest) }
    [IO.Directory]::Delete($ownedFolder)
    $output.Dispose()
}
