using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;

// A live DWM view of this editor's player. No screen capture files, second
// decoder, copied OSC drawing, focus transfer, or input forwarding is involved.
public sealed class SettingsPreview : IDisposable
{
    [StructLayout(LayoutKind.Sequential)] struct NativeRect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct Size { public int Width, Height; }
    [StructLayout(LayoutKind.Sequential)] struct Properties
    {
        public uint Flags;
        public NativeRect Destination, Source;
        public byte Opacity;
        [MarshalAs(UnmanagedType.Bool)] public bool Visible;
        [MarshalAs(UnmanagedType.Bool)] public bool ClientOnly;
    }
    [DllImport("dwmapi.dll")] static extern int DwmRegisterThumbnail(IntPtr destination, IntPtr source, out IntPtr thumbnail);
    [DllImport("dwmapi.dll")] static extern int DwmUnregisterThumbnail(IntPtr thumbnail);
    [DllImport("dwmapi.dll")] static extern int DwmUpdateThumbnailProperties(IntPtr thumbnail, ref Properties properties);
    [DllImport("dwmapi.dll")] static extern int DwmQueryThumbnailSourceSize(IntPtr thumbnail, out Size size);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr window);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr window, out NativeRect rect);
    IntPtr thumbnail, source;
    bool disposed;
    public bool Visible { get; private set; }
    public static Rect Fit(Rect bounds, double width, double height)
    {
        if (bounds.IsEmpty || bounds.Width <= 0 || bounds.Height <= 0 || width <= 0 || height <= 0) return Rect.Empty;
        double scale = Math.Min(bounds.Width / width, bounds.Height / height);
        double w = width * scale, h = height * scale;
        return new Rect(bounds.X + (bounds.Width - w) / 2, bounds.Y + (bounds.Height - h) / 2, w, h);
    }
    public string Update(Window window, FrameworkElement area, Process player, bool enabled)
    {
        if (disposed) return "预览已结束";
        if (!enabled || !window.IsVisible || window.WindowState == WindowState.Minimized || !area.IsVisible)
        { Hide(); return ""; }
        try
        {
            player.Refresh();
            IntPtr handle = player.MainWindowHandle;
            uint pid;
            GetWindowThreadProcessId(handle, out pid);
            if (handle == IntPtr.Zero || !IsWindow(handle) || pid != player.Id)
            { DisposeThumbnail(); return "等待播放器窗口…"; }
            if (IsIconic(handle) || !IsWindowVisible(handle))
            { Hide(); return "播放器已最小化或隐藏，恢复窗口后可继续预览。"; }
            IntPtr destination = new WindowInteropHelper(window).Handle;
            if (destination == IntPtr.Zero) return "等待预览区域…";
            if (source != handle || thumbnail == IntPtr.Zero)
            {
                DisposeThumbnail();
                if (DwmRegisterThumbnail(destination, handle, out thumbnail) != 0)
                { DisposeThumbnail(); return "暂时无法显示播放器画面。"; }
                source = handle;
            }
            NativeRect client; Size full;
            if (!GetClientRect(handle, out client) || DwmQueryThumbnailSourceSize(thumbnail, out full) != 0)
            { Hide(); return "无法读取播放器画面尺寸。"; }
            var presentation = PresentationSource.FromVisual(window);
            if (presentation == null || presentation.CompositionTarget == null) { Hide(); return "等待预览区域…"; }
            Rect dip = area.TransformToAncestor(window).TransformBounds(new Rect(0, 0, area.ActualWidth, area.ActualHeight));
            Rect pixels = Rect.Transform(dip, presentation.CompositionTarget.TransformToDevice);
            Rect fitted = Fit(pixels, client.Right - client.Left, client.Bottom - client.Top);
            NativeRect target;
            if (fitted.IsEmpty || !GetClientRect(destination, out target)) { Hide(); return "等待预览区域…"; }
            // The preview area sits outside the scrolling settings pane. Clip
            // defensively during resize/DPI transitions rather than cover controls.
            fitted.Intersect(new Rect(0, 0, target.Right, target.Bottom));
            if (fitted.IsEmpty) { Hide(); return ""; }
            var properties = new Properties { Flags = 1 | 4 | 8 | 16, Opacity = 255, Visible = true, ClientOnly = true,
                Destination = new NativeRect { Left = (int)Math.Ceiling(fitted.Left), Top = (int)Math.Ceiling(fitted.Top),
                    Right = (int)Math.Floor(fitted.Right), Bottom = (int)Math.Floor(fitted.Bottom) } };
            if (DwmUpdateThumbnailProperties(thumbnail, ref properties) != 0)
            { DisposeThumbnail(); return "暂时无法刷新播放器画面。"; }
            Visible = true; return "";
        }
        catch { DisposeThumbnail(); return "播放器画面暂不可用。"; }
    }
    public void Hide()
    {
        if (thumbnail != IntPtr.Zero)
        {
            var properties = new Properties { Flags = 8, Visible = false };
            DwmUpdateThumbnailProperties(thumbnail, ref properties);
        }
        Visible = false;
    }
    void DisposeThumbnail()
    {
        if (thumbnail != IntPtr.Zero) DwmUnregisterThumbnail(thumbnail);
        thumbnail = source = IntPtr.Zero; Visible = false;
    }
    public void Dispose() { DisposeThumbnail(); disposed = true; }
}
