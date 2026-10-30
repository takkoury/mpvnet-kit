param([Parameter(Mandatory=$true)][string]$RequestPath,[switch]$ValidateOnly,[switch]$NoShow)
$ErrorActionPreference='Stop'
$utf8=New-Object Text.UTF8Encoding($false)
$writer=New-Object IO.StreamWriter([Console]::OpenStandardOutput(),$utf8)
$writer.AutoFlush=$true
$window=$null;$parentProcess=$null
Add-Type -AssemblyName System.Web.Extensions
$json=New-Object Web.Script.Serialization.JavaScriptSerializer
try {
    if(-not [IO.Path]::IsPathRooted($RequestPath)){throw '媒体信息窗口请求路径无效。'}
    $file=Get-Item -LiteralPath $RequestPath
    if($file.Length -gt 262144){throw '媒体信息窗口请求过大。'}
    $data=$json.DeserializeObject([IO.File]::ReadAllText($file.FullName,$utf8))
    if($data.schema -ne 1 -or -not ($data.token -is [string]) -or $data.token.Length -gt 128 -or -not $data.token){throw '媒体信息窗口请求无效。'}
    if($data.activation_path -cne ($RequestPath+'.activate')){throw '媒体信息窗口会话路径不匹配。'}
    if(-not ($data.has_media -is [bool]) -or -not ($data.local_path -is [string]) -or -not ($data.title -is [string]) -or -not ($data.properties -is [Collections.IDictionary])){throw '媒体信息字段无效。'}
    if($data.local_path -and -not [IO.Path]::IsPathRooted($data.local_path)){throw '媒体路径必须为绝对路径。'}
    $parentProcess=[Diagnostics.Process]::GetProcessById([int]$data.parent_pid)
    if($parentProcess.HasExited){throw '播放器已退出。'}
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
    $references=@('System.Core','System.Xaml', [Windows.Window].Assembly.Location,
        [Windows.Media.Brushes].Assembly.Location,[Windows.Threading.Dispatcher].Assembly.Location)
    Add-Type -ReferencedAssemblies $references -Path @((Join-Path $PSScriptRoot 'media-info-data.cs'),(Join-Path $PSScriptRoot 'media-info-view.cs'))
    $media=[MediaInfoData]::Read($data,$parentProcess)
    $window=New-Object MediaInfoView($data,$media,$parentProcess,[bool]($ValidateOnly -or $NoShow))
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
