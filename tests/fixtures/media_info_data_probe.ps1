param([Parameter(Mandatory=$true)][string]$SourcePath,
      [Parameter(Mandatory=$true)][string]$RequestPath,
      [Parameter(Mandatory=$true)][int]$ParentPid,
      [string]$MediaInfoDll='', [switch]$SkipBaseline)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Web.Extensions
Add-Type -Path $SourcePath -ReferencedAssemblies System.Core
$json=New-Object Web.Script.Serialization.JavaScriptSerializer
$json.MaxJsonLength=16MB
$request=$json.DeserializeObject([IO.File]::ReadAllText($RequestPath,[Text.Encoding]::UTF8))
$parent=[Diagnostics.Process]::GetProcessById($ParentPid)
$stub=$null
try {
    if($MediaInfoDll) {
        # An owned non-GUI process makes the DLL directory exactly the fixture.
        $root=Split-Path -Parent $RequestPath
        $hostPath=Join-Path $root 'media-info-fixture-host.exe'
        Copy-Item -LiteralPath $MediaInfoDll -Destination (Join-Path $root 'MediaInfo.dll')
        Add-Type -TypeDefinition 'public static class FixtureHost { public static void Main() { System.Threading.Thread.Sleep(60000); } }' -OutputAssembly $hostPath -OutputType ConsoleApplication
        $start=New-Object Diagnostics.ProcessStartInfo
        $start.FileName=$hostPath;$start.UseShellExecute=$false;$start.CreateNoWindow=$true
        $stub=[Diagnostics.Process]::Start($start)
        $parent.Dispose();$parent=$stub
        $request['parent_pid']=[int]$parent.Id
    }
    $result=[MediaInfoData]::Read($request,$parent)
    $flags=[Reflection.BindingFlags]'Static,NonPublic'
    $local=[MediaInfoData].GetMethod('LocalFile',$flags)
    $result['probe_local_file_accepted']=$local.Invoke($null,@([string]$request.local_path))
    $pathKind=[MediaInfoData].GetMethod('FileSystemPath',$flags)
    $result['probe_paths']=@{}
    foreach($path in @('https://example.invalid/media','\\.\pipe\fixture','\\?\pipe\fixture','\\fixture-server\share\media.mkv','Z:\mapped-media.mkv')) {
        $result['probe_paths'][$path]=$pathKind.Invoke($null,@($path))
    }
    if($MediaInfoDll -and -not $SkipBaseline) {
        # Independent direct call checks default report fidelity, including lines
        # which the original host presentation would remove (such as Unique ID).
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class OriginalMediaInfoProbe {
 [DllImport("MediaInfo.dll")] static extern IntPtr MediaInfo_New();
 [DllImport("MediaInfo.dll",CharSet=CharSet.Unicode)] static extern UIntPtr MediaInfo_Open(IntPtr handle,string path);
 [DllImport("MediaInfo.dll",CharSet=CharSet.Unicode)] static extern IntPtr MediaInfo_Option(IntPtr handle,string name,string value);
 [DllImport("MediaInfo.dll")] static extern IntPtr MediaInfo_Inform(IntPtr handle,UIntPtr reserved);
 [DllImport("MediaInfo.dll")] static extern void MediaInfo_Close(IntPtr handle);
 [DllImport("MediaInfo.dll")] static extern void MediaInfo_Delete(IntPtr handle);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] static extern IntPtr LoadLibraryEx(string path,IntPtr file,uint flags);
 [DllImport("kernel32.dll")] static extern bool FreeLibrary(IntPtr handle);
 public static string[] Read(string library,string path) {
  IntPtr dll=LoadLibraryEx(library,IntPtr.Zero,0x100|0x800),handle=IntPtr.Zero;
  if(dll==IntPtr.Zero) throw new Exception("fixture DLL load failed");
  try { handle=MediaInfo_New();MediaInfo_Open(handle,path);MediaInfo_Option(handle,"Language","");MediaInfo_Option(handle,"Complete","0");
   string normal=Marshal.PtrToStringUni(MediaInfo_Inform(handle,UIntPtr.Zero));MediaInfo_Option(handle,"Complete","1");
   return new[]{normal,Marshal.PtrToStringUni(MediaInfo_Inform(handle,UIntPtr.Zero))};
  } finally { if(handle!=IntPtr.Zero){MediaInfo_Close(handle);MediaInfo_Delete(handle);}FreeLibrary(dll); }
 }
}
'@
        $baseline=[OriginalMediaInfoProbe]::Read((Join-Path (Split-Path -Parent $RequestPath) 'MediaInfo.dll'),$request.local_path)
        $result['probe_default_report']=$baseline[0]
        $result['probe_complete_report_length']=$baseline[1].Length
    }
    $result['probe_parent_retained']=(-not $parent.HasExited)
    [Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
    [Console]::Out.WriteLine($json.Serialize($result))
} finally {
    if($stub -and -not $stub.HasExited){$stub.Kill();$stub.WaitForExit()}
    $parent.Dispose()
}
