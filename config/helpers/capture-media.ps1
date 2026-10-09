param(
    [string]$PayloadPath = '',
    [switch]$ValidateOnly,
    [switch]$NoClipboard,
    [string]$TestOutputRoot = '',
    [ValidateSet('', 'clipboard', 'commit')][string]$TestFailPhase = ''
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$outputWriter = New-Object IO.StreamWriter([Console]::OpenStandardOutput(), $utf8)
$outputWriter.AutoFlush = $true
$inputReader = $null
$ownedPayload = $null
$captureRoot = $null
$ffmpeg = $null
$phase = 'input'
$stage = $null
$owned = New-Object 'System.Collections.Generic.List[string]'
$parentProcess = $null
$tempPng = $null
$cancelPath = $null

function Write-Result($data) {
    $outputWriter.WriteLine(($data | ConvertTo-Json -Compress -Depth 8))
}

function Check-Cancelled {
    if (($cancelPath -and [IO.File]::Exists($cancelPath)) -or
        ($parentProcess -and $parentProcess.HasExited)) { throw 'cancelled' }
}

function Safe-Title([string]$value, [switch]$WithoutMediaExtension) {
    # URI titles often carry signed query strings. Never put them in filenames.
    if ($value -match '^\w[\w+.-]*://') {
        $value = ($value -split '[?#]', 2)[0]
        $value = ($value.TrimEnd('/') -split '/')[-1]
    }
    if ($WithoutMediaExtension) {
        # Remove only one recognized source suffix; keep episode numbers and title dots.
        $value = [regex]::Replace($value, '(?i)\.(mkv|mp4|webm|avi|mov|m4v|ts|m2ts|mts|flv|wmv|mpg|mpeg|ogv|vob|asf|3gp|3g2|mxf|f4v|rm|rmvb|divx|mp3|m4a|aac|flac|wav|ogg|opus|wma|aiff|alac|ape|png|jpg|jpeg|webp|gif|bmp|tif|tiff|avif)$', '')
    }
    $value = [regex]::Replace($value, '[<>:"/\\|?*\x00-\x1f]', '_').Trim().TrimEnd('.')
    if ($value.Length -gt 80) {
        $value = $value.Substring(0, 80)
        if ([char]::IsHighSurrogate($value[$value.Length - 1])) { $value = $value.Substring(0, $value.Length - 1) }
    }
    $value = $value.Trim().TrimEnd('.')
    if (-not $value -or $value -eq '.' -or $value -eq '..') { $value = 'Media' }
    if ($value -match '^(?i:CON|PRN|AUX|NUL|COM[1-9\u00b9\u00b2\u00b3]|LPT[1-9\u00b9\u00b2\u00b3])(?:\.|$)') { $value = '_' + $value }
    return $value
}

function New-OutputPlan([string]$title, [string[]]$extensions) {
    $name = Safe-Title $title
    $directory = Join-Path $captureRoot (Safe-Title $title -WithoutMediaExtension)
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $stem = $name + '-' + $stamp
    $files = @{}
    foreach ($extension in $extensions) { $files[$extension] = Join-Path $directory ($stem + '.' + $extension) }
    if (@($files.Values | Where-Object { [IO.File]::Exists($_) }).Count -gt 0) {
        $stem += '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
        foreach ($extension in $extensions) { $files[$extension] = Join-Path $directory ($stem + '.' + $extension) }
    }
    return @{directory = $directory; files = $files}
}

function Copy-Image([string]$path) {
    if ($TestFailPhase -eq 'clipboard') { throw 'test' }
    if ($NoClipboard) { return }
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $bitmap = New-Object System.Drawing.Bitmap($path)
    try {
        $data = New-Object System.Windows.Forms.DataObject
        $data.SetData([System.Windows.Forms.DataFormats]::Bitmap, $true, $bitmap)
        # copy=true flushes data to Windows before disposing the image/worker.
        [System.Windows.Forms.Clipboard]::SetDataObject($data, $true, 5, 100)
    } finally { $bitmap.Dispose() }
}

function Copy-File([string]$path) {
    if (-not [IO.File]::Exists($path)) { throw 'missing' }
    if ($TestFailPhase -eq 'clipboard') { throw 'test' }
    if ($NoClipboard) { return }
    Add-Type -AssemblyName System.Windows.Forms
    $paths = New-Object System.Collections.Specialized.StringCollection
    [void]$paths.Add($path)
    $data = New-Object System.Windows.Forms.DataObject
    $data.SetFileDropList($paths)
    $effect = New-Object System.IO.MemoryStream(,[byte[]](1, 0, 0, 0))
    try {
        $data.SetData('Preferred DropEffect', $effect)
        [System.Windows.Forms.Clipboard]::SetDataObject($data, $true, 5, 100)
    } finally { $effect.Dispose() }
}

# ProcessStartInfo.Arguments uses the Windows native argv convention. Quoting
# every argument handles spaces, Unicode, quotes, trailing slashes and CRLF.
function Quote-Argument([string]$value) {
    '"' + [regex]::Replace([regex]::Replace($value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}

function Initialize-JobType {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CaptureJob {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] static extern IntPtr CreateJobObject(IntPtr a, string n);
    [DllImport("kernel32.dll")] static extern bool SetInformationJobObject(IntPtr j, int c, IntPtr p, uint l);
    [DllImport("kernel32.dll")] public static extern bool AssignProcessToJobObject(IntPtr j, IntPtr p);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
    [StructLayout(LayoutKind.Sequential)] struct Basic {
        public long PerProcess, PerJob; public uint Flags; public UIntPtr Min, Max;
        public uint Active; public UIntPtr Affinity; public uint Priority, Scheduling;
    }
    [StructLayout(LayoutKind.Sequential)] struct IO {
        public ulong ReadOp, WriteOp, OtherOp, ReadBytes, WriteBytes, OtherBytes;
    }
    [StructLayout(LayoutKind.Sequential)] struct Extended {
        public Basic Basic; public IO IO; public UIntPtr ProcessMemory, JobMemory, PeakProcess, PeakJob;
    }
    public static IntPtr Create() {
        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        Extended info = new Extended(); info.Basic.Flags = 0x2000;
        int size = Marshal.SizeOf(info); IntPtr p = Marshal.AllocHGlobal(size);
        try {
            Marshal.StructureToPtr(info, p, false);
            if (job == IntPtr.Zero || !SetInformationJobObject(job, 9, p, (uint)size)) {
                if (job != IntPtr.Zero) CloseHandle(job);
                throw new Exception("job");
            }
            return job;
        } finally { Marshal.FreeHGlobal(p); }
    }
}
'@
}

function Run-FFmpeg([string[]]$arguments) {
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $ffmpeg
    $info.Arguments = (@('-hide_banner', '-loglevel', 'error', '-nostdin', '-n') + $arguments |
        ForEach-Object { Quote-Argument $_ }) -join ' '
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    $job = [CaptureJob]::Create()
    try {
        [void]$process.Start()
        if (-not [CaptureJob]::AssignProcessToJobObject($job, $process.Handle)) { $process.Kill(); throw 'job' }
        # Consume output to avoid pipe blocking, but never publish signed URLs.
        $errors = $process.StandardError.ReadToEndAsync()
        while (-not $process.WaitForExit(150)) {
            Check-Cancelled
        }
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw 'encode' }
    } finally {
        [void][CaptureJob]::CloseHandle($job)
        $process.Dispose()
    }
}

function Input-Arguments($source, [double]$seek, $payload) {
    if (-not $source.path -or $source.index -isnot [ValueType] -or
        [int]$source.index -lt 0 -or [double]$source.index -ne [int]$source.index) { throw 'track' }
    $arguments = @('-ss', $seek.ToString('0.#########', [Globalization.CultureInfo]::InvariantCulture))
    if ([string]$source.path -match '^https?://') {
        if ($payload.user_agent) { $arguments += @('-user_agent', [string]$payload.user_agent) }
        if ($payload.referrer) { $arguments += @('-referer', [string]$payload.referrer) }
        if ($payload.headers) {
            $headers = @($payload.headers | ForEach-Object { [string]$_ })
            foreach ($header in $headers) { if ($header -match '[\r\n]') { throw 'header' } }
            $arguments += @('-headers', ($headers -join "`r`n") + "`r`n")
        }
    }
    $arguments += @('-i', [string]$source.path)
    return $arguments
}

try {
    if ($PayloadPath) {
        if (-not [IO.Path]::IsPathRooted($PayloadPath)) { throw 'payload' }
        $fullPayload = [IO.Path]::GetFullPath($PayloadPath)
        if ([IO.Path]::GetDirectoryName($fullPayload).TrimEnd('\') -ine [IO.Path]::GetTempPath().TrimEnd('\') -or
            [IO.Path]::GetFileName($fullPayload) -notmatch '^mpvnet-capture-payload-[\d-]+\.json$') { throw 'payload' }
        $ownedPayload = $fullPayload
        $payload = [IO.File]::ReadAllText($ownedPayload, $utf8) | ConvertFrom-Json
    } else {
        # Retain stdin for direct callers; the player uses -PayloadPath on Win32.
        $inputReader = New-Object IO.StreamReader([Console]::OpenStandardInput(), $utf8)
        $payload = $inputReader.ReadToEnd() | ConvertFrom-Json
    }
    # Only path data is configurable. Never accept a command line or script.
    foreach ($name in @('capture_root', 'ffmpeg_path')) {
        if ($payload.PSObject.Properties[$name]) {
            $value = $payload.$name
            if ($value -isnot [string] -or $value.IndexOf([char]0) -ge 0 -or
                $value -notmatch '^(?:[A-Za-z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+)') { throw 'path-setting' }
        }
    }
    if ($payload.action -notin @('copy', 'cancel')) {
        $pictures = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyPictures)
        $captureRoot = if ($payload.capture_root) { $payload.capture_root }
            elseif ($pictures) { Join-Path $pictures 'Capture' } else { throw 'pictures-folder' }
    }
    if ($TestFailPhase -and -not $NoClipboard) { throw 'test-mode' }
    if ($TestOutputRoot) {
        if (-not $NoClipboard -and -not $ValidateOnly) { throw 'test-mode' }
        $captureRoot = $TestOutputRoot
    }
    if ($payload.action -notin @('screenshot', 'clip', 'copy', 'cancel', 'open-directory')) { throw 'action' }
    $clipboardFormat = 'webp'
    if ($payload.action -eq 'clip' -and $payload.PSObject.Properties['clipboard_format']) {
        if ($payload.clipboard_format -isnot [string] -or
            $payload.clipboard_format -cnotin @('webp', 'gif', 'mp4')) { throw 'clipboard-format' }
        $clipboardFormat = $payload.clipboard_format
    }
    if ($payload.job_id -and [string]$payload.job_id -notmatch '^[\d-]+$') { throw 'job-id' }
    if ($payload.action -eq 'cancel') {
        if (-not $payload.job_id) { throw 'job-id' }
        $cancelStage = Join-Path ([IO.Path]::GetTempPath()) ('mpvnet-capture-job-' + $payload.job_id)
        [void][IO.Directory]::CreateDirectory($cancelStage)
        [IO.File]::WriteAllText((Join-Path $cancelStage 'cancel'), '')
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        while ([IO.Directory]::Exists($cancelStage) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
        # The worker may have completed before cancellation was dispatched.
        # Remove a marker-only directory; never recursively delete a live job.
        if ([IO.Directory]::Exists($cancelStage)) {
            $entries = @([IO.Directory]::EnumerateFileSystemEntries($cancelStage))
            if ($entries.Count -eq 1 -and [IO.Path]::GetFileName($entries[0]) -eq 'cancel') {
                [IO.File]::Delete($entries[0])
                [IO.Directory]::Delete($cancelStage)
            }
        }
        Write-Result @{ok = $true}
        exit 0
    }
    if ($payload.action -eq 'open-directory') {
        $phase = 'directory'
        if (-not $ValidateOnly) {
            [void][IO.Directory]::CreateDirectory($captureRoot)
            $directoryStart = New-Object Diagnostics.ProcessStartInfo
            $directoryStart.FileName = $captureRoot
            $directoryStart.UseShellExecute = $true
            [void][Diagnostics.Process]::Start($directoryStart)
        }
        Write-Result @{ok = $true; directory = $captureRoot}
        exit 0
    }
    if ($payload.parent_pid) {
        $parentProcess = [Diagnostics.Process]::GetProcessById([int]$payload.parent_pid)
        if ($parentProcess.HasExited) { throw 'cancelled' }
    }
    if ($payload.action -eq 'copy') {
        $phase = 'clipboard'
        if (-not $ValidateOnly) { Copy-File ([string]$payload.file) }
        Write-Result @{ok = $true}
        exit 0
    }
    $extensions = if ($payload.action -eq 'screenshot') { @('png') } else { @('mp4', 'webp', 'gif') }
    $plan = New-OutputPlan ([string]$payload.title) $extensions
    if ($ValidateOnly) {
        $result = @{ok = $true; files = $plan.files}
        if ($payload.action -eq 'clip') { $result.clipboard_format = $clipboardFormat }
        Write-Result $result
        exit 0
    }
    if ($payload.action -eq 'clip') {
        # PNG and directory actions do not require FFmpeg. Check before making staging.
        $phase = 'ffmpeg'
        if ($payload.ffmpeg_path) {
            if (-not [IO.File]::Exists($payload.ffmpeg_path)) { throw 'ffmpeg-missing' }
            $ffmpeg = $payload.ffmpeg_path
        } else {
            $command = Get-Command ffmpeg.exe -CommandType Application -ErrorAction SilentlyContinue
            if (-not $command) { throw 'ffmpeg-missing' }
            $ffmpeg = $command.Source
        }
    }
    if (-not $payload.job_id) { $payload | Add-Member -NotePropertyName job_id -NotePropertyValue ([DateTime]::UtcNow.Ticks.ToString()) }
    $stage = Join-Path ([IO.Path]::GetTempPath()) ('mpvnet-capture-job-' + $payload.job_id)
    [void][IO.Directory]::CreateDirectory($stage)
    $cancelPath = Join-Path $stage 'cancel'
    Check-Cancelled
    $staged = @{}
    foreach ($extension in $extensions) { $staged[$extension] = Join-Path $stage ('capture.' + $extension) }
    if ($payload.action -eq 'screenshot') {
        $phase = 'screenshot'
        $candidatePng = [string]$payload.temp_png
        # Only remove the specifically allocated capture temporary file.
        if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($candidatePng)).TrimEnd('\') -ine
            [IO.Path]::GetTempPath().TrimEnd('\') -or
            [IO.Path]::GetFileName($candidatePng) -notmatch '^mpvnet-capture-[\d-]+\.png$') { throw 'temp' }
        $tempPng = $candidatePng
        [IO.File]::Move($tempPng, $staged.png)
    } else {
        $phase = 'clip-input'
        $start = [double]$payload.start
        $duration = [double]$payload.finish - $start
        if ([double]::IsNaN($start) -or [double]::IsInfinity($start) -or $start -lt 0 -or
            [double]::IsNaN($duration) -or [double]::IsInfinity($duration) -or $duration -le 0) { throw 'range' }
        Initialize-JobType
        $arguments = @(Input-Arguments $payload.video $start $payload)
        if ($payload.audio) {
            $audioSeek = [Math]::Max(0, $start - [double]$payload.audio_delay)
            $arguments += @(Input-Arguments $payload.audio $audioSeek $payload)
        }
        $arguments += @('-t', $duration.ToString('0.#########', [Globalization.CultureInfo]::InvariantCulture),
            '-map', ('0:' + [int]$payload.video.index), '-sn', '-dn',
            '-vf', 'pad=ceil(iw/2)*2:ceil(ih/2)*2', '-c:v', 'libx264', '-crf', '18',
            '-preset', 'fast', '-pix_fmt', 'yuv420p')
        if ($payload.audio) {
            $arguments += @('-map', ('1:' + [int]$payload.audio.index), '-c:a', 'aac', '-b:a', '192k')
            $initialDelay = [Math]::Max(0, [double]$payload.audio_delay - $start)
            if ($initialDelay -gt 0) {
                $arguments += @('-af', ('adelay=' + [int][Math]::Round($initialDelay * 1000) + ':all=1'))
            }
        } else { $arguments += '-an' }
        $arguments += @('-map_metadata', '-1', '-movflags', '+faststart', $staged.mp4)
        $phase = 'mp4'
        Run-FFmpeg $arguments
        # First-version cost defaults: no upscaling and no raised source FPS.
        $webpFilter = "fps=fps='min(source_fps,20)',scale=w='min(960,iw)':h='min(960,ih)':force_original_aspect_ratio=decrease"
        $phase = 'webp'
        Run-FFmpeg @('-i', $staged.mp4, '-an', '-vf', $webpFilter, '-c:v', 'libwebp_anim',
            '-quality', '75', '-compression_level', '4', '-loop', '0', $staged.webp)
        $gifFilter = "fps=fps='min(source_fps,12)',scale=w='min(640,iw)':h='min(640,ih)':force_original_aspect_ratio=decrease,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle"
        $phase = 'gif'
        Run-FFmpeg @('-i', $staged.mp4, '-an', '-filter_complex', $gifFilter, '-loop', '0', $staged.gif)
    }
    $phase = 'commit'
    Check-Cancelled
    foreach ($extension in $extensions) {
        if (-not [IO.File]::Exists($staged[$extension]) -or (Get-Item -LiteralPath $staged[$extension]).Length -eq 0) { throw 'empty' }
    }
    [void][IO.Directory]::CreateDirectory($plan.directory)
    foreach ($extension in $extensions) {
        Check-Cancelled
        [IO.File]::Move($staged[$extension], $plan.files[$extension])
        $owned.Add($plan.files[$extension])
        if ($TestFailPhase -eq 'commit') { throw 'test' }
    }
    $phase = 'clipboard'
    Check-Cancelled
    if ($payload.action -eq 'screenshot') { Copy-Image $plan.files.png }
    else { Copy-File $plan.files[$clipboardFormat] }
    $result = @{ok = $true; files = $plan.files}
    if ($payload.action -eq 'clip') { $result.clipboard_format = $clipboardFormat }
    Write-Result $result
} catch {
    # Delete only final outputs moved by this invocation. Never clear Clipboard.
    foreach ($path in $owned) { if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) } }
    Write-Result @{ok = $false; phase = $phase; error_class = $_.Exception.GetType().Name}
    exit 1
} finally {
    if ($tempPng -and [IO.File]::Exists($tempPng)) { [IO.File]::Delete($tempPng) }
    if ($stage -and [IO.Directory]::Exists($stage)) { [IO.Directory]::Delete($stage, $true) }
    if ($parentProcess) { $parentProcess.Dispose() }
    if ($ownedPayload -and [IO.File]::Exists($ownedPayload)) { [IO.File]::Delete($ownedPayload) }
    if ($inputReader) { $inputReader.Dispose() }
    $outputWriter.Dispose()
}
