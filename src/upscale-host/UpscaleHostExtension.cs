using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading.Tasks;
using MpvNet;

namespace KitUpscaleHost;

public sealed class UpscaleHostExtension : IExtension
{
    private const string SupportedHost = "7.1.2.0+96afc62165b5a1df186fc79c58813f37061ace9a";
    private const string LoadMessage = "mpvnet-kit-upscale-host-load";
    private const string StatusProperty = "user-data/mpvnet/upscale-host";
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower };
    private readonly MainPlayer _player = Global.Player;
    private readonly object _queue = new();
    private readonly NativeRuntime _runtime = new();
    private readonly string _hostIssue;
    private Request? _pending;
    private bool _working;
    private bool _closed;

    public UpscaleHostExtension()
    {
        var hostVersion = Assembly.GetEntryAssembly()
            ?.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
        _hostIssue = RuntimeInformation.ProcessArchitecture != Architecture.X64 ? "host-architecture" :
            hostVersion != SupportedHost ? "host-version" : "";
        lock (_queue)
        {
            _player.Shutdown += OnShutdown;
            _player.ClientMessage += OnMessage;
            Publish(0, "", _hostIssue.Length == 0 ? "idle" : "unsupported", _hostIssue);
        }
    }

    private void OnMessage(string[] args)
    {
        if (args.Length < 2 || args[0] != LoadMessage ||
            !int.TryParse(args[1], NumberStyles.None, CultureInfo.InvariantCulture, out int serial) || serial < 1)
            return;

        var bundleId = args.Length == 3 && RuntimeBundle.IsBundleId(args[2]) ? args[2] : "";
        lock (_queue)
        {
            if (_closed)
                return;
            // One worker owns native loading. Keep the latest pending intent while it is occupied.
            _pending = new Request(serial, bundleId);
            if (!_working)
            {
                _working = true;
                _ = Task.Run(ProcessRequests);
            }
        }
    }

    private void ProcessRequests()
    {
        while (true)
        {
            Request request;
            lock (_queue)
            {
                if (_closed || _pending is not { } next)
                {
                    _working = false;
                    return;
                }
                request = next;
                _pending = null;
            }

            string status = "failed";
            string reason = "";
            string module = "";
            int win32Error = 0;
            try
            {
                if (_hostIssue.Length != 0)
                {
                    status = "unsupported";
                    reason = _hostIssue;
                }
                else if (request.BundleId.Length == 0)
                    reason = "request-invalid";
                else
                {
                    var configRoot = _player.GetPropertyString("options/config-dir");
                    Publish(request.Serial, request.BundleId, "loading");
                    _runtime.Load(string.IsNullOrEmpty(configRoot) ? _player.ConfigFolder : configRoot, request.BundleId);
                    status = "ready";
                }
            }
            catch (HostFailure error)
            {
                reason = error.Reason;
                module = error.Module;
                win32Error = error.Win32Error;
            }
            catch (Exception error)
            {
                reason = error switch
                {
                    FileNotFoundException or DirectoryNotFoundException => "bundle-missing",
                    UnauthorizedAccessException or IOException => "bundle-read",
                    JsonException or KeyNotFoundException or InvalidOperationException or FormatException => "bundle-receipt",
                    _ => "host-load"
                };
            }

            Publish(request.Serial, request.BundleId, status, reason, module, win32Error);
        }
    }

    private void Publish(int serial, string bundleId, string status, string reason = "", string module = "", int win32Error = 0)
    {
        lock (_queue)
        {
            if (_closed || _player.Handle == IntPtr.Zero)
                return;
            // One property write keeps status, serial and the native path snapshot together.
            var response = new Response(1, serial, bundleId, status, reason, module, win32Error, _runtime.LoadedPaths);
            _player.SetPropertyString(StatusProperty, JsonSerializer.Serialize(response, JsonOptions));
        }
    }

    private void OnShutdown()
    {
        lock (_queue)
        {
            _closed = true;
            _pending = null;
            _player.ClientMessage -= OnMessage;
            _player.Shutdown -= OnShutdown;
        }
    }

    private sealed record Request(int Serial, string BundleId);
    private sealed record Response(int Schema, int Serial, string BundleId, string Status, string ErrorReason,
        string Module, int Win32Error, IReadOnlyDictionary<string, string> LoadedPaths);
}
