param([Parameter(Mandatory=$true)][string]$RequestPath,[switch]$ValidateOnly,[switch]$NoShow)
$ErrorActionPreference='Stop'
$utf8=New-Object Text.UTF8Encoding($false)
$writer=New-Object IO.StreamWriter([Console]::OpenStandardOutput(),$utf8)
$writer.AutoFlush=$true
$window=$null;$parentProcess=$null
Add-Type -AssemblyName System.Web.Extensions
$json=New-Object Web.Script.Serialization.JavaScriptSerializer
try {
    if(-not [IO.Path]::IsPathRooted($RequestPath)){throw '关于窗口请求路径无效。'}
    $file=Get-Item -LiteralPath $RequestPath
    if($file.Length -gt 65536){throw '关于窗口请求过大。'}
    $data=$json.DeserializeObject([IO.File]::ReadAllText($file.FullName,$utf8))
    if($data.schema -ne 1 -or -not ($data.token -is [string]) -or $data.token.Length -gt 128 -or -not $data.token){throw '关于窗口请求无效。'}
    if($data.activation_path -cne ($RequestPath+'.activate')){throw '关于窗口会话路径不匹配。'}
    foreach($field in @('host_version','mpv_version','ffmpeg_version')){
        if(-not ($data[$field] -is [string]) -or $data[$field].Length -gt 2048){throw '关于窗口版本字段无效。'}
    }
    $parentProcess=[Diagnostics.Process]::GetProcessById([int]$data.parent_pid)
    if($parentProcess.HasExited){throw '播放器已退出。'}
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
    $references=@('System.Core','System.Xaml', [Windows.Window].Assembly.Location,
        [Windows.Media.Brushes].Assembly.Location,[Windows.Threading.Dispatcher].Assembly.Location)
    Add-Type -ReferencedAssemblies $references -Path (Join-Path $PSScriptRoot 'about-window.cs')
    $window=New-Object AboutWindow($data,$parentProcess,[bool]($ValidateOnly -or $NoShow))
    if($ValidateOnly -or $NoShow){$writer.WriteLine($json.Serialize($window.Snapshot()))}
    else {
        $window.Run()
        $writer.WriteLine($json.Serialize(@{ok=$true;last_seen_serial=$window.LastSeenSerial}))
    }
} catch {
    $writer.WriteLine($json.Serialize(@{ok=$false;error=$_.Exception.Message}))
    exit 1
} finally {
    if($window){$window.Dispose()}
    if($parentProcess){$parentProcess.Dispose()}
}
