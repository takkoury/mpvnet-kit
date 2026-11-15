using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;

internal sealed class UpscaleModels
{
    readonly string configRoot, bundleRoot;
    readonly Dictionary<string, object> definitions;

    public UpscaleModels(string configRoot, string bundleRoot)
    {
        this.configRoot = configRoot;
        this.bundleRoot = bundleRoot;
        try {
            string manifest = Path.Combine(configRoot, "upscale", "models.json");
            var data = UpscaleData.Parse(UpscaleData.Read(manifest, 32 * 1024));
            object entries;
            if (UpscaleData.Number(data, "schema") != 1 || !data.TryGetValue("models", out entries))
                throw new InvalidDataException();
            definitions = entries as Dictionary<string, object>;
            if (definitions == null || definitions.Count == 0) throw new InvalidDataException();
        } catch (Exception error) when (error is IOException || error is UnauthorizedAccessException ||
            error is InvalidDataException || error is ArgumentException || error is InvalidOperationException ||
            error is UpscaleFailure || error is System.Security.SecurityException) {
            throw new UpscaleFailure("model_integrity");
        }
    }

    public UpscaleModel Select(string id)
    {
        object entry;
        if (!definitions.TryGetValue(id, out entry)) throw new UpscaleFailure("unsupported_input");
        var definition = entry as Dictionary<string, object>;
        try {
            if (definition == null) throw new InvalidDataException();
            string source = UpscaleData.Text(definition, "source"), path = UpscaleData.Text(definition, "path");
            string hash = UpscaleData.Text(definition, "sha256");
            long pad = UpscaleData.Number(definition, "pad_multiple");
            if ((source != "config" && source != "bundle") || !UpscaleData.IsHash(hash) ||
                UpscaleData.Number(definition, "scale") != 2 || (pad != 1 && pad != 4) ||
                UpscaleData.Number(definition, "recipe") != 1)
                throw new InvalidDataException();
            bool fromConfig = source == "config";
            string prefix = fromConfig ? "upscale/models/" : "models/";
            if (path == null || !path.StartsWith(prefix, StringComparison.Ordinal)) throw new InvalidDataException();
            string fullPath = UpscaleData.Relative(fromConfig ? configRoot : bundleRoot, path);
            return new UpscaleModel(fullPath, hash, fromConfig, (int)pad);
        } catch (Exception error) when (error is InvalidDataException || error is ArgumentException) {
            throw new UpscaleFailure("model_integrity");
        }
    }

    public Dictionary<string, string> Probe()
    {
        var errors = new Dictionary<string, string>();
        foreach (string id in definitions.Keys) {
            try {
                var model = Select(id);
                // Bundle model files already participate in the component readiness check.
                if (model.FromConfig) model.RequireAsset();
            } catch (UpscaleFailure error) {
                errors[id] = error.Message;
            }
        }
        return errors;
    }
}

internal sealed class UpscaleModel
{
    readonly string path, hash;
    readonly int padMultiple;
    public readonly bool FromConfig;

    public UpscaleModel(string path, string hash, bool fromConfig, int padMultiple)
    {
        this.path = path;
        this.hash = hash;
        FromConfig = fromConfig;
        this.padMultiple = padMultiple;
    }

    public int Pad(int size) => (int)(((size + (long)padMultiple - 1) / padMultiple) * padMultiple);

    public void RequireAsset()
    {
        string integrityError = FromConfig ? "model_integrity" : "bundle_integrity";
        string actual;
        try {
            UpscaleData.RejectLinks(path);
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            using (var sha = SHA256.Create())
                actual = UpscaleData.Hex(sha.ComputeHash(stream));
        } catch (IOException error) when (FromConfig && (error is FileNotFoundException || error is DirectoryNotFoundException)) {
            throw new UpscaleFailure("model_missing");
        } catch (Exception error) when (error is IOException || error is UnauthorizedAccessException ||
            error is UpscaleFailure || error is System.Security.SecurityException) {
            throw new UpscaleFailure(integrityError);
        }
        if (actual != hash) throw new UpscaleFailure(integrityError);
    }
}
