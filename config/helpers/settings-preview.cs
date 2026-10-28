using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;

// Source coordinates are client pixels; destination coordinates are physical
// pixels in the settings client area. Neither text nor OSC size enters this
// calculation, so changing a setting cannot auto-fit its own rendered content.
public sealed class SettingsPreviewGeometry
{
    public Rect Source { get; private set; }
    public Rect Destination { get; private set; }
    public double Scale { get; private set; }
    SettingsPreviewGeometry(Rect source, Rect destination, double scale)
    { Source = source; Destination = destination; Scale = scale; }
    static bool Positive(double value) { return value > 0 && !Double.IsInfinity(value) && !Double.IsNaN(value); }
    public static SettingsPreviewGeometry Calculate(Rect bounds, double width, double height, string mode, double subtitlePosition = 100)
    {
        if (bounds.IsEmpty || !Positive(bounds.Width) || !Positive(bounds.Height) || !Positive(width) || !Positive(height)
            || Double.IsNaN(bounds.X) || Double.IsNaN(bounds.Y) || Double.IsInfinity(bounds.X) || Double.IsInfinity(bounds.Y))
            return new SettingsPreviewGeometry(Rect.Empty, Rect.Empty, 0);
        double cropHeight = height, top = 0;
        if (mode == "subtitles" || mode == "controlbar")
        {
            cropHeight = Math.Min(height, Math.Ceiling(height * (mode == "subtitles" ? 0.45 : 0.35)));
            if (Double.IsNaN(subtitlePosition) || Double.IsInfinity(subtitlePosition)) subtitlePosition = 100;
            double anchor = height * Math.Max(0, Math.Min(100, subtitlePosition)) / 100;
            top = mode == "controlbar" ? height - cropHeight
                : Math.Max(0, Math.Min(height - cropHeight, Math.Round(anchor - cropHeight / 2)));
        }
        Rect source = new Rect(0, top, width, cropHeight);
        double scale = Math.Min(bounds.Width / width, bounds.Height / cropHeight);
        Rect destination = new Rect(bounds.X + (bounds.Width - width * scale) / 2,
            bounds.Y + (bounds.Height - cropHeight * scale) / 2, width * scale, cropHeight * scale);
        return new SettingsPreviewGeometry(source, destination, scale);
    }
    public static Rect SourceInWindow(Rect crop, Rect windowBounds, System.Windows.Point clientOrigin, double thumbnailWidth, double thumbnailHeight)
    {
        if (crop.IsEmpty || windowBounds.IsEmpty || !Positive(windowBounds.Width) || !Positive(windowBounds.Height)
            || !Positive(thumbnailWidth) || !Positive(thumbnailHeight)) return Rect.Empty;
        double x = thumbnailWidth / windowBounds.Width, y = thumbnailHeight / windowBounds.Height;
        double left = Math.Max(0, Math.Round((clientOrigin.X - windowBounds.X + crop.Left) * x));
        double top = Math.Max(0, Math.Round((clientOrigin.Y - windowBounds.Y + crop.Top) * y));
        double right = Math.Min(thumbnailWidth, Math.Round((clientOrigin.X - windowBounds.X + crop.Right) * x));
        double bottom = Math.Min(thumbnailHeight, Math.Round((clientOrigin.Y - windowBounds.Y + crop.Bottom) * y));
        return right > left && bottom > top ? new Rect(left, top, right - left, bottom - top) : Rect.Empty;
    }
}

// A live DWM view of this editor's player. No screen capture files, second
// decoder, copied OSC drawing, focus transfer, or input forwarding is involved.
public sealed class SettingsPreview : IDisposable
{
    [StructLayout(LayoutKind.Sequential)] struct NativeRect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct Size { public int Width, Height; }
    [StructLayout(LayoutKind.Sequential)] struct Point { public int X, Y; }
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
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out NativeRect rect);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr window, ref Point point);
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
    public string Update(Window window, FrameworkElement area, Process player, bool enabled, string mode = "full", double subtitlePosition = 100)
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
            NativeRect client, outer; Size full; Point origin = new Point();
            if (!GetClientRect(handle, out client) || !GetWindowRect(handle, out outer) || !ClientToScreen(handle, ref origin)
                || DwmQueryThumbnailSourceSize(thumbnail, out full) != 0 || full.Width <= 0 || full.Height <= 0
                || outer.Right <= outer.Left || outer.Bottom <= outer.Top)
            { Hide(); return "无法读取播放器画面尺寸。"; }
            var presentation = PresentationSource.FromVisual(window);
            if (presentation == null || presentation.CompositionTarget == null) { Hide(); return "等待预览区域…"; }
            Rect dip = area.TransformToAncestor(window).TransformBounds(new Rect(0, 0, area.ActualWidth, area.ActualHeight));
            Rect pixels = Rect.Transform(dip, presentation.CompositionTarget.TransformToDevice);
            NativeRect target;
            if (!GetClientRect(destination, out target)) { Hide(); return "等待预览区域…"; }
            // The preview area sits outside the scrolling settings pane. Clip
            // defensively during resize/DPI transitions rather than cover controls.
            pixels.Intersect(new Rect(0, 0, target.Right, target.Bottom));
            var geometry = SettingsPreviewGeometry.Calculate(pixels, client.Right - client.Left, client.Bottom - client.Top, mode, subtitlePosition);
            Rect fitted = geometry.Destination;
            if (fitted.IsEmpty || fitted.Width < 1 || fitted.Height < 1) { Hide(); return ""; }
            // rcSource is explicitly in whole-window thumbnail coordinates.
            // Map the client crop through the same queried DWM source size;
            // this avoids relying on rcSource's origin with ClientOnly=true.
            Rect crop = SettingsPreviewGeometry.SourceInWindow(geometry.Source,
                new Rect(outer.Left, outer.Top, outer.Right - outer.Left, outer.Bottom - outer.Top),
                new System.Windows.Point(origin.X, origin.Y), full.Width, full.Height);
            if (crop.IsEmpty) { Hide(); return "无法读取播放器画面尺寸。"; }
            var properties = new Properties { Flags = 1 | 2 | 4 | 8 | 16, Opacity = 255, Visible = true, ClientOnly = false,
                Source = new NativeRect { Left = (int)crop.Left, Top = (int)crop.Top,
                    Right = (int)crop.Right, Bottom = (int)crop.Bottom },
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
