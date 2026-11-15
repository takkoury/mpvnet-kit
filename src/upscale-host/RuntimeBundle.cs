using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace KitUpscaleHost;

internal static class RuntimeBundle
{
    private const string Runtime = "runtime/";
    private const string VapourSynth = Runtime + "Lib/site-packages/vapoursynth/";

    // Windows binds the stable Python DLL and the VS extension by basename.
    internal static readonly string[] NativeLoadOrder =
    [
        Runtime + "python312.dll", Runtime + "python3.dll",
        VapourSynth + "libvapoursynth.dll", VapourSynth + "vsscript.dll"
    ];

    internal const string PythonModule = VapourSynth + "vapoursynth.pyd";
    internal static readonly string[] VapourSynthFilters =
    [
        VapourSynth + "libvapoursynthfilters.dll", VapourSynth + "libvapoursynthfilters_avx2.dll",
        VapourSynth + "libvapoursynthfilters_zn4.dll"
    ];
    private const string PythonPath = Runtime + "python312._pth";
    private static readonly string[] OtherRuntimeFiles =
    [
        Runtime + "python.exe", Runtime + "python312.zip", PythonPath,
        Runtime + "_ctypes.pyd", Runtime + "libffi-8.dll",
        VapourSynth + "__init__.py", VapourSynth + "_utils.py", VapourSynth + "_shell.py",
        PythonModule
    ];

    internal static bool IsBundleId(string value) =>
        value.Length <= 48 && Regex.IsMatch(value, @"\A[a-z0-9]+(?:[.-][a-z0-9]+)*\z", RegexOptions.CultureInvariant);

    internal static string Verify(string configRoot, string bundleId)
    {
        if (!Path.IsPathFullyQualified(configRoot))
            throw new HostFailure("config-root");
        configRoot = Path.GetFullPath(configRoot);

        var manifest = File.ReadAllBytes(ManagedPath(configRoot, "upscale/components.json"));
        using var manifestJson = JsonDocument.Parse(manifest);
        if (manifestJson.RootElement.GetProperty("bundle_id").GetString() != bundleId)
            throw new HostFailure("bundle-id");

        var componentRoot = ManagedPath(configRoot, "components/ai-upscale");
        using var receipt = JsonDocument.Parse(File.ReadAllBytes(ManagedPath(componentRoot, "component.json")));
        var record = receipt.RootElement;
        if (record.GetProperty("schema").GetInt32() != 1 ||
            record.GetProperty("bundle_id").GetString() != bundleId ||
            !DigestMatches(SHA256.HashData(manifest), record.GetProperty("manifest_sha256").GetString()))
            throw new HostFailure("bundle-receipt");

        var records = new Dictionary<string, JsonElement>(StringComparer.OrdinalIgnoreCase);
        foreach (var file in record.GetProperty("files").EnumerateArray())
        {
            if (file.GetProperty("path").GetString() is not { } path || !records.TryAdd(path, file))
                throw new HostFailure("bundle-receipt");
        }

        var bundleRoot = ManagedPath(componentRoot, "bundles/" + bundleId);
        foreach (var relative in NativeLoadOrder.Concat(VapourSynthFilters).Concat(OtherRuntimeFiles))
        {
            if (!records.TryGetValue(relative, out var file))
                throw new HostFailure("bundle-receipt");
            using var stream = File.OpenRead(ManagedPath(bundleRoot, relative));
            if (stream.Length != file.GetProperty("size").GetInt64() ||
                !DigestMatches(SHA256.HashData(stream), file.GetProperty("sha256").GetString()))
                throw new HostFailure("bundle-integrity", Path.GetFileName(relative));
        }

        // Reject site initialization and paths outside this embed distribution.
        var pathEntries = File.ReadLines(ManagedPath(bundleRoot, PythonPath))
            .Select(line => line.Trim().Replace('\\', '/'))
            .Where(line => line.Length > 0 && !line.StartsWith('#'));
        if (!pathEntries.SequenceEqual(new[] { "python312.zip", ".", "Lib/site-packages" }))
            throw new HostFailure("python-isolation");
        if (File.Exists(Resolve(bundleRoot, Runtime + "python3._pth")))
            throw new HostFailure("python-isolation");

        return bundleRoot;
    }

    internal static string Resolve(string bundleRoot, string relative) =>
        Path.Combine(bundleRoot, relative.Replace('/', Path.DirectorySeparatorChar));

    private static string ManagedPath(string root, string relative)
    {
        if ((File.GetAttributes(root) & FileAttributes.ReparsePoint) != 0)
            throw new HostFailure("bundle-path");
        foreach (var part in relative.Split('/'))
        {
            root = Path.Combine(root, part);
            if ((File.GetAttributes(root) & FileAttributes.ReparsePoint) != 0)
                throw new HostFailure("bundle-path");
        }
        return root;
    }

    private static bool DigestMatches(byte[] actual, string? expected) =>
        string.Equals(Convert.ToHexString(actual), expected, StringComparison.OrdinalIgnoreCase);
}
