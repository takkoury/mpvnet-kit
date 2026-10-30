param([string]$SourcePath,[string]$OutputPath)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
$code=[IO.File]::ReadAllText($SourcePath)
$code+=@'
public sealed class InstallerProbe : KitInstallerForm {
    public int SystemPaint;
    public InstallerProbe(float scale) : base(scale) { }
    protected override void DefWndProc(ref System.Windows.Forms.Message m) {
        if(m.Msg==0x85 || m.Msg==0x86)SystemPaint++;
        base.DefWndProc(ref m);
    }
    public void ProbeFrame() {
        var h=Handle;SystemPaint=0;
        var active=System.Windows.Forms.Message.Create(h,0x86,new System.IntPtr(1),System.IntPtr.Zero);WndProc(ref active);
        var paint=System.Windows.Forms.Message.Create(h,0x85,new System.IntPtr(1),System.IntPtr.Zero);WndProc(ref paint);
    }
}
public static class InstallerProbeNative {
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    public struct Rect {public int Left,Top,Right,Bottom;}
    [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern System.IntPtr SetThreadDpiAwarenessContext(System.IntPtr value);
    [System.Runtime.InteropServices.DllImport("user32.dll",EntryPoint="SendMessageW")] public static extern System.IntPtr FormatRect(System.IntPtr h,int m,System.IntPtr w,ref Rect r);
}
'@
Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition $code
[void][InstallerProbeNative]::SetThreadDpiAwarenessContext([IntPtr](-2))
$frames=@();$dialogs=@()
foreach($scale in @(1.0,1.5,2.0)) {
    $form=New-Object InstallerProbe([single]$scale)
    try {
        $form.ProbeFrame();$form.PerformLayout()
        $frames+=@{scale=$scale;shown=$form.Visible;taskbar=$form.ShowInTaskbar;minimize=$form.MinimizeBox;maximize=$form.MaximizeBox;
            system_paint=$form.SystemPaint;content_top=$form.ContentHost.Top}
    } finally {$form.Dispose()}
    $message=(('Long complete path and release notice.'+[char]10+[char]10) * 160)
    $dialog=New-Object KitInstallerConfirmation([single]$scale,$message,'Confirm update','Start update')
    try {
        [void]$dialog.Handle;$dialog.PerformLayout()
        $area=[Windows.Forms.Screen]::FromPoint([Drawing.Point]::Empty).WorkingArea
        $cancel=$dialog.CancelAction;$accept=$dialog.ConfirmButton
        $buttonParent=$accept.Parent
        $dialogs+=@{scale=$scale;shown=$dialog.Visible;minmax=$dialog.MinimizeBox -or $dialog.MaximizeBox;
            text_preserved=$dialog.MessageText.Text.Replace("`r`n","`n") -ceq $message;scrolling=$dialog.MessageText.ScrollBars.ToString();
            default_cancel=[object]::ReferenceEquals($dialog.AcceptButton,$cancel) -and [object]::ReferenceEquals($dialog.CancelButton,$cancel);
            within_screen=$dialog.Width -le $area.Width -and $dialog.Height -le $area.Height;
            buttons_visible=$accept.Left -ge 0 -and $cancel.Left -ge 0 -and $accept.Right -le $buttonParent.ClientSize.Width -and $cancel.Bottom -le $buttonParent.ClientSize.Height;
            separate=$cancel.Right -le $accept.Left -or $accept.Right -le $cancel.Left}
        if($scale -eq 1.0 -and $OutputPath) {
            $bitmap=New-Object Drawing.Bitmap($dialog.ClientSize.Width,$dialog.ClientSize.Height)
            try {
                $dialog.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$bitmap.Width,$bitmap.Height)))
                $bitmap.Save($OutputPath,[Drawing.Imaging.ImageFormat]::Png)
            } finally {$bitmap.Dispose()}
        }
    } finally {$dialog.Dispose()}
}
$results=@()
foreach($choice in @('CancelAction','ConfirmButton')) {
    $dialog=New-Object KitInstallerConfirmation([single]1.0,'Body','Confirm update','Start update')
    try {
        $button=$dialog.$choice
        [void][Windows.Forms.Button].GetMethod('OnClick',[Reflection.BindingFlags]'Instance,NonPublic').Invoke($button,@([EventArgs]::Empty))
        $results+=$dialog.DialogResult.ToString()
    } finally {$dialog.Dispose()}
}
$scrollChecks=@()
foreach($height in @(180,196,220)) {
    $box=New-Object KitInstallerTextBox
    try {
        $box.Multiline=$true;$box.WordWrap=$true;$box.ScrollBars='Vertical';$box.ReadOnly=$true
        $box.Font=New-Object Drawing.Font('Microsoft YaHei UI',10.5)
        $box.Size=New-Object Drawing.Size(240,$height)
        $box.Text=('Long wrapped text for reading the final complete line. '*100)
        [void]$box.Handle;$box.Select(8,5);$box.ScrollToLine([int]::MaxValue)
        $rect=New-Object InstallerProbeNative+Rect
        [void][InstallerProbeNative]::FormatRect($box.Handle,0xB2,[IntPtr]::Zero,[ref]$rect)
        $last=$box.GetPositionFromCharIndex($box.GetFirstCharIndexFromLine($box.TotalLines-1)).Y
        $previous=$box.GetPositionFromCharIndex($box.GetFirstCharIndexFromLine($box.TotalLines-2)).Y
        $scrollChecks+=@{height=$height;complete=$last+($last-$previous) -le $rect.Bottom;selection=$box.SelectionStart -eq 8 -and $box.SelectionLength -eq 5}
    } finally {$box.Font.Dispose();$box.Dispose()}
}
@{frames=$frames;dialogs=$dialogs;choices=$results;scroll=$scrollChecks}|ConvertTo-Json -Depth 6 -Compress
