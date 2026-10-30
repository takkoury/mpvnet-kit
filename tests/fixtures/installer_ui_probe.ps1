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
    [System.Runtime.InteropServices.DllImport("user32.dll",EntryPoint="SendMessageW")] public static extern System.IntPtr Send(System.IntPtr h,int m,System.IntPtr w,System.IntPtr l);
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    public struct Rect {public int Left,Top,Right,Bottom;}
    [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern System.IntPtr SetThreadDpiAwarenessContext(System.IntPtr value);
    [System.Runtime.InteropServices.DllImport("user32.dll",EntryPoint="SendMessageW")] public static extern System.IntPtr FormatRect(System.IntPtr h,int m,System.IntPtr w,ref Rect r);
}
public sealed class EditTrafficProbe : System.Windows.Forms.NativeWindow {
    public int MarginWrites;
    protected override void WndProc(ref System.Windows.Forms.Message m) {
        if(m.Msg==0xD3)MarginWrites++;
        base.WndProc(ref m);
    }
}
'@
Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition $code
[void][InstallerProbeNative]::SetThreadDpiAwarenessContext([IntPtr](-2))
$frames=@();$dialogs=@();$detailDialogs=@()
function Test-ConfirmationActions($Dialog) {
    $accept=$Dialog.ConfirmButton;$cancel=$Dialog.CancelAction;$parent=$accept.Parent
    return $cancel.Left -ge 0 -and $cancel.Top -ge 0 -and $cancel.Right -le $accept.Left -and
        $accept.Right -le $parent.ClientSize.Width -and $accept.Top -ge 0 -and
        $cancel.Bottom -le $parent.ClientSize.Height -and $accept.Bottom -le $parent.ClientSize.Height
}
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
    $summary="Update the configuration.`nTarget: X:/fixture/player/portable_config`nNecessary upgrade notice."
    $details=("Changed runtime file: scripts/example.lua`nComplete file and recovery details.`n" * 180)
    $dialog=New-Object KitInstallerConfirmation([single]$scale,$summary,'Confirm update','Start update','File changes',$details)
    try {
        [void]$dialog.Handle;$dialog.PerformLayout();$dialog.ContentHost.PerformLayout()
        foreach($panel in $dialog.ContentHost.Controls) {$panel.PerformLayout()}
        $initialHeight=$dialog.Height;$initiallyCollapsed=-not $dialog.DetailsExpanded
        $summaryBox=$dialog.MessageText;$detailsBox=$dialog.DetailsText
        $dialog.MessageText.Select(8,5);$dialog.DetailsText.Select(9,7)
        $actionsFit=Test-ConfirmationActions $dialog
        $click=[Windows.Forms.Button].GetMethod('OnClick',[Reflection.BindingFlags]'Instance,NonPublic')
        [void]$click.Invoke($dialog.DetailsButton,([object[]]@([EventArgs]::Empty)))
        $dialog.PerformLayout();$dialog.ContentHost.PerformLayout()
        foreach($panel in $dialog.ContentHost.Controls) {$panel.PerformLayout()}
        $expanded=$dialog.DetailsExpanded;$expandedHeight=$dialog.Height
        $expandedContentPreserved=$dialog.MessageText.Text.Replace("`r`n","`n") -ceq $summary -and
            $dialog.DetailsText.Text.Replace("`r`n","`n") -ceq $details
        $actionsFit=$actionsFit -and (Test-ConfirmationActions $dialog)
        $detailsFit=$dialog.DetailsText.Height -gt 0 -and $dialog.MessageText.Height -gt 0 -and
            $dialog.MessageText.Bottom -le $dialog.DetailsButton.Top -and
            $dialog.DetailsButton.Bottom -le $dialog.DetailsText.Top -and
            $dialog.DetailsText.Bottom -le $dialog.DetailsText.Parent.ClientSize.Height -and
            $dialog.DetailsButton.Right -le $dialog.DetailsButton.Parent.ClientSize.Width
        foreach($control in @($dialog.MessageText,$dialog.DetailsButton,$dialog.DetailsText)) {
            $detailsFit=$detailsFit -and $control.Left -ge 0 -and $control.Top -ge 0 -and
                $control.Right -le $control.Parent.ClientSize.Width -and $control.Bottom -le $control.Parent.ClientSize.Height
        }
        $selectionPreserved=$dialog.MessageText.SelectionStart -eq 8 -and $dialog.MessageText.SelectionLength -eq 5 -and
            $dialog.DetailsText.SelectionStart -eq 9 -and $dialog.DetailsText.SelectionLength -eq 7
        [void]$click.Invoke($dialog.DetailsButton,([object[]]@([EventArgs]::Empty)))
        $dialog.PerformLayout();$dialog.ContentHost.PerformLayout()
        foreach($panel in $dialog.ContentHost.Controls) {$panel.PerformLayout()}
        $selectionPreserved=$selectionPreserved -and $dialog.MessageText.SelectionStart -eq 8 -and $dialog.MessageText.SelectionLength -eq 5 -and
            $dialog.DetailsText.SelectionStart -eq 9 -and $dialog.DetailsText.SelectionLength -eq 7
        $area=[Windows.Forms.Screen]::FromHandle($dialog.Handle).WorkingArea
        $detailDialogs+=@{scale=$scale;shown=$dialog.Visible;initially_collapsed=$initiallyCollapsed;expanded=$expanded;
            collapsed_again=-not $dialog.DetailsExpanded;heights=@($initialHeight,$expandedHeight,$dialog.Height);
            summary_preserved=$dialog.MessageText.Text.Replace("`r`n","`n") -ceq $summary;
            details_preserved=$dialog.DetailsText.Text.Replace("`r`n","`n") -ceq $details;
            expanded_content_preserved=$expandedContentPreserved;
            textboxes_preserved=[object]::ReferenceEquals($summaryBox,$dialog.MessageText) -and [object]::ReferenceEquals($detailsBox,$dialog.DetailsText);
            selection_preserved=$selectionPreserved;details_fit=$detailsFit;actions_fit=$actionsFit -and (Test-ConfirmationActions $dialog);
            default_cancel=[object]::ReferenceEquals($dialog.AcceptButton,$dialog.CancelAction) -and [object]::ReferenceEquals($dialog.CancelButton,$dialog.CancelAction);
            within_screen=$dialog.Width -le $area.Width -and $expandedHeight -le $area.Height -and $expandedHeight -le [Math]::Round(560*$scale);
            details_subtle=$dialog.DetailsButton.Subtle;dialog_result=$dialog.DialogResult.ToString()}
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
$idleChecks=@()
foreach($bars in @('None','Vertical')) {
    $box=New-Object KitInstallerTextBox
    $probe=New-Object EditTrafficProbe
    try {
        $box.Multiline=$true;$box.ReadOnly=$true;$box.ScrollBars=$bars
        $box.Size=New-Object Drawing.Size(300,160);$box.Text=('Selectable text with wrapped lines. '*100)
        [void]$box.Handle;$probe.AssignHandle($box.Handle);$box.Select(4,8)
        $probe.MarginWrites=0
        for($i=0;$i -lt 80;$i++) {
            [void][InstallerProbeNative]::Send($box.Handle,0x200,[IntPtr]::Zero,[IntPtr](65536*20+20+$i))
            [void][InstallerProbeNative]::Send($box.Handle,0x113,[IntPtr]::Zero,[IntPtr]::Zero)
        }
        $idleChecks+=@{bars=$bars;margin_writes=$probe.MarginWrites;selection=$box.SelectionStart -eq 4 -and $box.SelectionLength -eq 8}
    } finally {$probe.ReleaseHandle();$box.Dispose()}
}
@{frames=$frames;dialogs=$dialogs;detail_dialogs=$detailDialogs;choices=$results;scroll=$scrollChecks;idle=$idleChecks}|ConvertTo-Json -Depth 6 -Compress
