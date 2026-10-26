param([Parameter(Mandatory=$true)][string]$SourcePath)
$ErrorActionPreference='Stop'
$source=[IO.File]::ReadAllText($SourcePath)
$code=[regex]::Match($source,"(?s)Add-Type -TypeDefinition \(?@'\r?\n(.*?)\r?\n'@").Groups[1].Value
if (-not $code) {throw 'missing production C#'}
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
$code += "`n" + [IO.File]::ReadAllText((Join-Path (Split-Path -Parent $SourcePath) 'shortcut-key-names.cs'))
Add-Type -TypeDefinition $code -ReferencedAssemblies System.Windows.Forms,System.Drawing
[void][PlaylistNative]::SetThreadDpiAwarenessContext([IntPtr](-4))
[Windows.Forms.Application]::EnableVisualStyles()
$foreground=[PlaylistNative]::GetForegroundWindow()
$parent=New-Object PlaylistForm;$side=New-Object PlaylistForm
$side.ShowInTaskbar=$false
$parent.StartPosition='Manual';$side.StartPosition='Manual'
$side.MinimizeBox=$false;$side.MaximizeBox=$false
$parent.Bounds=New-Object Drawing.Rectangle(150,130,650,450)
$rows=New-Object Collections.Generic.List[object]
$timer=New-Object Windows.Forms.Timer;$timer.Interval=350
$script:stage=0;$script:follower=$null;$script:failure=$null
function Sample([string]$state,[bool]$overlay) {
    $parentOuter=New-Object PlaylistNative+Rect;$sideOuter=New-Object PlaylistNative+Rect
    $p=[PlaylistNative]::GetVisibleBounds($parent.Handle,[ref]$parentOuter)
    $s=[PlaylistNative]::GetVisibleBounds($side.Handle,[ref]$sideOuter)
    $screen=[Windows.Forms.Screen]::FromHandle($parent.Handle)
    $area=if($state -eq 'fullscreen'){$screen.Bounds}else{$screen.WorkingArea}
    $edge=if($overlay){$s.Right-$area.Right}else{$s.Left-$p.Right}
    $rows.Add(@{state=$state;dpi=[PlaylistNative]::GetDpiForWindow($parent.Handle);
        foreground=[PlaylistNative]::GetForegroundWindow().ToInt64();side_handle=$side.Handle.ToInt64();
        follower_parent=$script:follower.Parent.ToInt64();expected_parent=$parent.Handle.ToInt64();parent_visible_flag=[PlaylistNative]::IsWindowVisible($parent.Handle);side_shown=$side.Visible;
        parent_outer=$parentOuter;parent_visible=$p;side_outer=$sideOuter;side_visible=$s;
        top_gap=$s.Top-$p.Top;bottom_gap=$s.Bottom-$p.Bottom;edge_gap=$edge;
        remembered_width=$script:follower.UserWidth})
}
$timer.Add_Tick({
    try {
        if ($script:stage -eq 0) {
            $script:follower=New-Object PlaylistFollower($side,[uint32]$PID)
            $script:follower.UpdatePolicy($true,$false)
        } elseif ($script:stage -eq 1) {
            Sample 'normal' $false;$parent.WindowState='Maximized'
        } elseif ($script:stage -eq 2) {
            Sample 'maximized' $true
            $parent.WindowState='Normal';$parent.FormBorderStyle='None'
            $parent.Bounds=[Windows.Forms.Screen]::FromHandle($parent.Handle).Bounds
            $script:follower.UpdatePolicy($true,$true)
        } elseif ($script:stage -eq 3) {
            Sample 'fullscreen' $true
            $parent.FormBorderStyle='Sizable'
            $area=[Windows.Forms.Screen]::FromHandle($parent.Handle).WorkingArea
            $parent.Bounds=New-Object Drawing.Rectangle(($area.Right-700),100,650,450)
            $script:follower.UpdatePolicy($true,$false)
        } else {
            Sample 'screen-edge' $true;$timer.Stop()
            $script:follower.Dispose();$script:follower=$null
            $side.Close();$parent.Close();[Windows.Forms.Application]::ExitThread()
        }
        $script:stage++
    } catch {
        $script:failure=$_;$timer.Stop();[Windows.Forms.Application]::ExitThread()
    }
})
try {
    $parent.Show();$timer.Start();[Windows.Forms.Application]::Run()
    if ($script:failure) {throw $script:failure}
    $foregroundAfter=[PlaylistNative]::GetForegroundWindow()
    @{pid=$PID;frames=$rows.ToArray();foreground_before=$foreground.ToInt64();foreground_after=$foregroundAfter.ToInt64();
        parent_handle=$rows[0].expected_parent;side_handle=$rows[0].side_handle;
        first_show_focus_preserved=($rows[0].foreground -eq $foreground.ToInt64());
        side_never_foreground=(@($rows | Where-Object {$_.foreground -eq $_.side_handle}).Count -eq 0);
        focus_preserved=($foregroundAfter -eq $foreground)} | ConvertTo-Json -Compress -Depth 6
} finally {
    $timer.Dispose();if($script:follower){$script:follower.Dispose()};$side.Dispose();$parent.Dispose()
}
