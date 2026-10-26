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
@{cases=$cases.Count;fallback=$true} | ConvertTo-Json -Compress
