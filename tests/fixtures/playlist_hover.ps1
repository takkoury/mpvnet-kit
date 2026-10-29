param([Parameter(Mandatory=$true)][string]$SourcePath)
$ErrorActionPreference='Stop'
$source=[IO.File]::ReadAllText($SourcePath)
$code=[regex]::Match($source,"(?s)Add-Type -TypeDefinition \(?@'\r?\n(.*?)\r?\n'@").Groups[1].Value
$code += "`n" + [IO.File]::ReadAllText((Join-Path (Split-Path -Parent $SourcePath) 'shortcut-key-names.cs'))
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
Add-Type -TypeDefinition $code -ReferencedAssemblies System.Windows.Forms,System.Drawing
$hover=New-Object PlaylistHover
$p=New-Object Drawing.Point(120,300)
if(-not $hover.Move('item-1',$p,0,4) -or $hover.Advance(549) -ne 1){throw 'tip appeared without dwell'}
if($hover.Move('item-1',(New-Object Drawing.Point(122,302)),300,4)){throw 'small jitter restarted dwell'}
if($hover.Advance(550) -ne 2){throw 'stationary hover did not appear'}
if($hover.Advance(5550) -ne 3){throw 'tip did not expire'}
if($hover.Move('item-1',$p,6000,4) -or $hover.Advance(10000) -ne 3){throw 'stationary tip reappeared after expiry'}
if(-not $hover.Move('item-1',(New-Object Drawing.Point(180,300)),11000,4) -or $hover.Advance(11549) -ne 1){throw 'pointer movement did not start a new dwell'}
if(-not $hover.Move('item-2',(New-Object Drawing.Point(180,300)),11200,4) -or $hover.Advance(11749) -ne 1){throw 'item change did not restart dwell'}
$hover.Cancel()
if($hover.Advance(20000) -ne 0){throw 'cancelled tip appeared later'}
$list=New-Object PlaylistList
try {
    $script:viewportInputs=0
    $list.add_ViewportInput({$script:viewportInputs++})
    [void][PlaylistNative]::SendMessage($list.Handle,0x20A,[IntPtr]0x780000,[IntPtr]::Zero)
    if($script:viewportInputs -lt 1){throw 'native wheel bypassed hover cancellation'}
} finally {$list.Dispose()}
$area=New-Object Drawing.Rectangle(-1920,0,1920,1080)
$size=New-Object Drawing.Size(200,60)
$a=[PlaylistTip]::Place((New-Object Drawing.Point(-1600,1000)),$size,$area,144,$true)
$b=[PlaylistTip]::Place((New-Object Drawing.Point(-1400,1000)),$size,$area,144,$true)
if($a.X -eq $b.X -or $a.Y -ge 1000 -or $b.Y -ge 1000){throw 'counter tooltip is not positioned near the pointer above the footer'}
foreach($point in @((New-Object Drawing.Point(-1919,2)),(New-Object Drawing.Point(-2,1078)))) {
    foreach($above in @($true,$false)) {
        $position=[PlaylistTip]::Place($point,$size,$area,144,$above)
        if(-not $area.Contains((New-Object Drawing.Rectangle($position,$size)))){throw 'tip escaped monitor work area'}
    }
}
'{"dwell":true,"expiry":true,"movement":true,"cancel":true,"native_wheel":true,"pointer_placement":true,"edge_clamping":true}'
