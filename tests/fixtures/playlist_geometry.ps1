param([Parameter(Mandatory=$true)][string]$SourcePath)
$ErrorActionPreference='Stop'
$source=[IO.File]::ReadAllText($SourcePath)
$tokens=$null;$parseErrors=$null
$null=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$parseErrors)
if ($parseErrors.Count) {throw 'PowerShell parser rejected helper'}
$code=[regex]::Match($source,"(?s)Add-Type -TypeDefinition \(?@'\r?\n(.*?)\r?\n'@").Groups[1].Value
if (-not $code) {throw 'missing production C#'}
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
$code += "`n" + [IO.File]::ReadAllText((Join-Path (Split-Path -Parent $SourcePath) 'shortcut-key-names.cs'))
$code += @'
public sealed class PlaylistFrameProbe : PlaylistForm {
    public int DefaultFramePaints;
    protected override void DefWndProc(ref System.Windows.Forms.Message m) {
        if(m.Msg==0x85 || m.Msg==0x86)DefaultFramePaints++;
        base.DefWndProc(ref m);
    }
}
'@
Add-Type -TypeDefinition $code -ReferencedAssemblies System.Windows.Forms,System.Drawing
function Rect([int[]]$coordinates) {
    $r=New-Object PlaylistNative+Rect
    $r.Left=$coordinates[0];$r.Top=$coordinates[1];$r.Right=$coordinates[2];$r.Bottom=$coordinates[3];return $r
}
function Coordinates($r) {return @($r.Left,$r.Top,$r.Right,$r.Bottom) -join ','}
# parent/area/side outer/side visible/remembered outer width/overlay/expected outer
$cases=@(
    @(@(107,100,793,593),@(0,0,1920,1040),@(0,0,340,500),@(7,0,333,493),340,$false,@(786,100,1126,600)),
    @(@(159,130,791,571),@(0,0,2560,1368),@(800,130,1310,580),@(809,130,1301,571),510,$false,@(782,130,1292,580)),
    @(@(100,80,850,600),@(0,0,1000,800),@(0,0,340,500),@(7,0,333,493),340,$false,@(667,80,1007,607)),
    @(@(0,0,2560,1368),@(0,0,2560,1368),@(0,0,510,600),@(9,0,501,591),510,$true,@(2059,0,2569,1377)),
    @(@(0,0,2560,1440),@(0,0,2560,1440),@(0,0,510,600),@(9,0,501,591),510,$true,@(2059,0,2569,1449)),
    @(@(-1200,50,-600,650),@(-1920,0,0,1040),@(0,0,340,500),@(7,0,333,493),340,$false,@(-607,50,-267,657)),
    @(@(100,-180,700,900),@(0,0,1920,1040),@(0,0,340,500),@(0,0,340,500),340,$false,@(700,-180,1040,900)),
    @(@(-8,-8,1928,1048),@(0,0,1920,1040),@(0,0,340,500),@(0,0,340,500),340,$true,@(1580,-8,1920,1048)),
    @(@(100,80,850,600),@(0,0,1000,800),@(0,0,1200,500),@(7,0,1193,493),1200,$false,@(-7,80,1007,607)),
    @(@(100,80,700,600),@(0,0,1920,1040),@(0,0,340,500),@(8,6,330,491),340,$false,@(692,74,1032,609))
)
foreach ($c in $cases) {
    $result=[PlaylistFollower]::FrameLayout((Rect $c[0]),(Rect $c[1]),(Rect $c[2]),(Rect $c[3]),$c[4],$c[5])
    if ((Coordinates $result) -ne ($c[6] -join ',')) { throw ('geometry expected '+($c[6] -join ',')+' got '+(Coordinates $result)) }
}
$outer=Rect @(10,20,350,520);$empty=Rect @(0,0,0,0);$frame=Rect @(17,20,343,513)
if ((Coordinates ([PlaylistNative]::VisibleBounds($outer,$frame,$false))) -ne (Coordinates $outer)) {throw 'DWM failure fallback'}
if ((Coordinates ([PlaylistNative]::VisibleBounds($outer,$empty,$true))) -ne (Coordinates $outer)) {throw 'DWM invalid fallback'}
if ((Coordinates ([PlaylistNative]::VisibleBounds($outer,$frame,$true))) -ne (Coordinates $frame)) {throw 'DWM success'}
# Native hit testing on a hidden handle: verify the real sizing frame, not
# just a style bit. This does not show or activate a desktop window.
$window=New-Object PlaylistFrameProbe
try {
    $window.FormBorderStyle='Sizable';$window.MinimizeBox=$false;$window.MaximizeBox=$false
    $window.StartPosition='Manual';$window.Location=New-Object Drawing.Point(-600,100)
    $window.Size=New-Object Drawing.Size(340,420)
    $rect=New-Object PlaylistNative+Rect
    [void][PlaylistNative]::GetWindowRect($window.Handle,[ref]$rect)
    $cornerValue=0
    $cornerSupported=[PlaylistNative]::ReadDwmInteger($window.Handle,33,[ref]$cornerValue,4) -eq 0
    $cornerValues=@()
    if($cornerSupported) {
        if($cornerValue -ne 2){throw 'normal sidebar did not request standard system rounding'}
        $cornerValues += $cornerValue
        $window.SetSquareCorners($true)
        [void][PlaylistNative]::ReadDwmInteger($window.Handle,33,[ref]$cornerValue,4)
        if($cornerValue -ne 1){throw 'maximized/fullscreen policy did not request square corners'}
        $cornerValues += $cornerValue
        $window.SetSquareCorners($false)
        [void][PlaylistNative]::ReadDwmInteger($window.Handle,33,[ref]$cornerValue,4)
        if($cornerValue -ne 2){throw 'restore did not request standard rounding'}
        $cornerValues += $cornerValue
    }
    $window.DefaultFramePaints=0
    foreach($active in @(1,0,1)) {
        $result=[PlaylistNative]::SendMessage($window.Handle,0x86,[IntPtr]$active,[IntPtr]::Zero)
        if($result.ToInt32() -ne 1){throw 'nonclient activation not acknowledged'}
        [void][PlaylistNative]::SendMessage($window.Handle,0x85,[IntPtr]1,[IntPtr]::Zero)
    }
    if($window.DefaultFramePaints -ne 0){throw 'activation reached system caption painting'}
    $origin=$window.PointToScreen([Drawing.Point]::Empty)
    if ($origin.X -ne $rect.Left -or $origin.Y -ne $rect.Top -or
        $window.ClientSize.Width -ne ($rect.Right-$rect.Left) -or $window.ClientSize.Height -ne ($rect.Bottom-$rect.Top)) {
        throw 'system nonclient strip remains outside the unified client area'
    }
    $hitCases=@(@(($rect.Left+1),($rect.Top+180),10),@(($rect.Right-2),($rect.Top+180),11),@(($rect.Left+100),($rect.Top+1),1))
    foreach($c in $hitCases) {
        $packed=([long]($c[0] -band 0xffff)) -bor (([long]($c[1] -band 0xffff)) -shl 16)
        $hit=[PlaylistNative]::SendMessage($window.Handle,0x84,[IntPtr]::Zero,[IntPtr]$packed).ToInt32()
        if ($hit -ne $c[2]) {throw "sidebar hit expected $($c[2]) got $hit"}
    }
    if ($window.Visible) {throw 'hidden hit test showed a window'}
} finally {$window.Dispose()}
@{cases=$cases.Count;fallback=$true;native_hits=$hitCases.Count;activation_no_system_paint=$true;
    corner_supported=$cornerSupported;corner_values=$cornerValues} | ConvertTo-Json -Compress
