param([Parameter(Mandatory=$true)][string]$SourcePath)
$ErrorActionPreference = 'Stop'
$source = [IO.File]::ReadAllText($SourcePath)
$code = [regex]::Match($source,"(?s)Add-Type -TypeDefinition \(?@'\r?\n(.*?)\r?\n'@").Groups[1].Value
if (-not $code) { throw 'Missing production C#.' }
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
$code += "`n" + [IO.File]::ReadAllText((Join-Path (Split-Path -Parent $SourcePath) 'shortcut-key-names.cs'))
$code += @'
public sealed class PlaylistPopupProbe : Form {
    public int PopupFlags;
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams {
        get { var p=base.CreateParams; p.ExStyle |= PopupFlags; return p; }
    }
}
public static class PlaylistParentProbe {
    [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
    static extern IntPtr CreateDesktop(string name,IntPtr device,IntPtr mode,uint flags,uint access,IntPtr attributes);
    [DllImport("user32.dll",SetLastError=true)] static extern bool SetThreadDesktop(IntPtr desktop);
    [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr desktop);
    public static readonly System.Collections.Generic.Dictionary<string,bool> Checks = new System.Collections.Generic.Dictionary<string,bool>();
    public static string Failure;
    public static string Geometry;
    static IntPtr desktop;
    static void Pump() {
        var end=DateTime.UtcNow.AddMilliseconds(160);
        while(DateTime.UtcNow<end) { Application.DoEvents();System.Threading.Thread.Sleep(10); }
    }
    static void Work() {
        Form player=null,replacement=null;
        PlaylistForm side=null;
        PlaylistPopupProbe popup=null,tool=null,plain=null;
        PlaylistFollower follower=null;
        try {
            desktop=CreateDesktop("kit-playlist-"+Guid.NewGuid().ToString("N"),IntPtr.Zero,IntPtr.Zero,0,0x10000000,IntPtr.Zero);
            if(desktop==IntPtr.Zero || !SetThreadDesktop(desktop)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            PlaylistNative.SetThreadDpiAwarenessContext(new IntPtr(-4));
            // This desktop is never switched to. Native visibility and enumeration
            // are real, but none of these windows appear on the user's desktop.
            player=new Form { StartPosition=FormStartPosition.Manual, Bounds=new Rectangle(80,80,600,400), FormBorderStyle=FormBorderStyle.None };
            player.Show();
            uint pid=(uint)System.Diagnostics.Process.GetCurrentProcess().Id;
            side=new PlaylistForm { ShowInTaskbar=false, StartPosition=FormStartPosition.Manual };
            follower=new PlaylistFollower(side,pid);follower.UpdatePolicy(true,false);Pump();
            Checks["initial_player"]=follower.Parent==player.Handle;
            Rectangle original=side.Bounds;
            popup=new PlaylistPopupProbe { PopupFlags=0x08000000, ShowInTaskbar=false, FormBorderStyle=FormBorderStyle.None, Bounds=new Rectangle(150,120,800,650) };
            popup.Show();PlaylistNative.SetWindowLongPtr(popup.Handle,-8,IntPtr.Zero);
            follower.RefreshParent(popup.Handle);Pump();
            Checks["preferred_popup_rejected"]=follower.Parent==player.Handle;
            Checks["menu_does_not_move_or_resize_side"]=side.Bounds==original;
            Geometry="before="+original+" after="+side.Bounds;
            Checks["cold_popup_rejected"]=PlaylistNative.FindParent(pid,popup.Handle)==player.Handle;
            tool=new PlaylistPopupProbe { PopupFlags=0x80, ShowInTaskbar=false, FormBorderStyle=FormBorderStyle.None, Bounds=new Rectangle(150,120,850,680) };
            tool.Show();PlaylistNative.SetWindowLongPtr(tool.Handle,-8,IntPtr.Zero);
            Checks["preferred_tool_rejected"]=PlaylistNative.FindParent(pid,tool.Handle)==player.Handle;
            Checks["largest_popup_rejected"]=PlaylistNative.FindParent(pid,IntPtr.Zero)==player.Handle;
            // Even a second ordinary top-level window cannot steal a live parent.
            plain=new PlaylistPopupProbe { ShowInTaskbar=true, Bounds=new Rectangle(170,140,450,300) };
            plain.Show();follower.RefreshParent(plain.Handle);
            Checks["confirmed_parent_stable"]=follower.Parent==player.Handle;
            plain.Dispose();plain=null;
            player.Hide();follower.RefreshParent(popup.Handle);Pump();
            Checks["hidden_player_not_replaced"]=follower.Parent==player.Handle && !side.Visible;
            player.Show();player.Bounds=new Rectangle(110,100,620,440);follower.RefreshParent(popup.Handle);Pump();
            PlaylistNative.Rect outer;
            var main=PlaylistNative.GetVisibleBounds(player.Handle,out outer);
            var list=PlaylistNative.GetVisibleBounds(side.Handle,out outer);
            Geometry+=" main="+main.Top+","+main.Bottom+" side="+list.Top+","+list.Bottom;
            Checks["move_resize_still_follows_player"]=follower.Parent==player.Handle && main.Top==list.Top && main.Bottom==list.Bottom;
            follower.Dispose();follower=null;side.Dispose();side=null;
            player.Dispose();player=null;
            replacement=new Form { StartPosition=FormStartPosition.Manual, Bounds=new Rectangle(90,90,600,400), FormBorderStyle=FormBorderStyle.None };
            replacement.Show();
            Checks["recreated_player_found"]=PlaylistNative.FindParent(pid,popup.Handle)==replacement.Handle;
        } catch(Exception e) { Failure=e.ToString(); }
        finally {
            if(follower!=null)follower.Dispose();
            if(side!=null)side.Dispose();
            if(popup!=null)popup.Dispose();if(tool!=null)tool.Dispose();if(plain!=null)plain.Dispose();
            if(player!=null)player.Dispose();if(replacement!=null)replacement.Dispose();
        }
    }
    public static void Run() {
        var worker=new System.Threading.Thread(Work);worker.SetApartmentState(System.Threading.ApartmentState.STA);
        worker.IsBackground=true;worker.Start();
        var deadline=DateTime.UtcNow.AddSeconds(15);
        while(worker.IsAlive && DateTime.UtcNow<deadline) { Application.DoEvents();worker.Join(10); }
        if(worker.IsAlive)throw new TimeoutException("private desktop fixture initialization");
        if(desktop!=IntPtr.Zero)CloseDesktop(desktop);
    }
}
'@
Add-Type -TypeDefinition $code -ReferencedAssemblies System.Windows.Forms,System.Drawing
[PlaylistParentProbe]::Run()
if ([PlaylistParentProbe]::Failure) { throw [PlaylistParentProbe]::Failure }
@{checks=[PlaylistParentProbe]::Checks; geometry=[PlaylistParentProbe]::Geometry; input_desktop_used=$false} | ConvertTo-Json -Depth 4 -Compress
