using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Threading;

internal sealed class UpscaleComponents
{
    const string BaseFolder = "components/ai-upscale";
    const string SevenZip = "tools/7zr.exe";
    const long MaxArchiveBytes = 3L * 1024 * 1024 * 1024, MaxExpandedBytes = 4L * 1024 * 1024 * 1024;
    static readonly string[] ProbeFiles = {
        "runtime/python.exe", "runtime/python3.dll", "runtime/python312.dll",
        "runtime/python312.zip", "runtime/python312._pth",
        "runtime/Lib/site-packages/vapoursynth/vsscript.dll",
        "runtime/Lib/site-packages/vapoursynth/libvapoursynth.dll",
        "runtime/Lib/site-packages/vapoursynth/vapoursynth.pyd",
        "plugins/vsmlrt-cuda/trtexec.exe", "plugins/vstrt.dll", "models/cugan.onnx", "models/esrgan.onnx",
    };
    static readonly HashSet<string> DownloadHosts = new HashSet<string>(StringComparer.OrdinalIgnoreCase) {
        "developer.download.nvidia.com", "docs.nvidia.com", "www.python.org", "files.pythonhosted.org",
        "github.com", "raw.githubusercontent.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com",
    };

    sealed class Member
    {
        public string Source, Target, Text, Hash;
        public long Size;
    }
    sealed class Archive
    {
        public string Name, Hash, Format;
        public long Size;
        public Uri Url;
        public List<Member> Members;
    }

    readonly UpscaleRequest request;
    readonly Func<string, Stream> archiveSource;
    readonly string root, receiptPath;
    readonly List<Archive> archives = new List<Archive>();
    readonly List<Member> generated = new List<Member>();
    readonly Dictionary<string, Member> expected = new Dictionary<string, Member>(StringComparer.OrdinalIgnoreCase);
    long downloaded, acquired;
    readonly Stopwatch progress = Stopwatch.StartNew();
    public readonly string BundleRoot, BundleId, ManifestHash, CacheRoot;
    public readonly long DownloadBytes, ExpandedBytes;
    public bool HasReceipt => File.Exists(receiptPath);

    public UpscaleComponents(UpscaleRequest request, Func<string, Stream> archiveSource = null)
    {
        this.request = request;
        this.archiveSource = archiveSource;
        root = Path.Combine(request.ConfigRoot, BaseFolder.Replace('/', '\\'));
        receiptPath = Path.Combine(root, "component.json");
        CacheRoot = Path.Combine(root, "cache");
        try {
            string manifest = Path.Combine(request.ConfigRoot, "upscale", "components.json");
            byte[] bytes = UpscaleData.Read(manifest, 1024 * 1024);
            ManifestHash = UpscaleData.Hash(bytes);
            var data = UpscaleData.Parse(bytes);
            if (UpscaleData.Number(data, "schema") != 1) throw new InvalidDataException();
            BundleId = UpscaleData.Text(data, "bundle_id");
            if (!ValidBundleId(BundleId)) throw new InvalidDataException();
            BundleRoot = Path.Combine(root, "bundles", BundleId);
            var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var row in Records(data, "archives")) {
                var archive = new Archive {
                    Name = UpscaleData.Text(row, "name"), Hash = UpscaleData.Text(row, "sha256"),
                    Format = UpscaleData.Text(row, "format"), Size = UpscaleData.Number(row, "size"),
                    Url = new Uri(UpscaleData.Text(row, "url"), UriKind.Absolute),
                };
                if (archive.Name == null || archive.Name.Contains("/") || !names.Add(archive.Name) ||
                    !UpscaleData.IsHash(archive.Hash) || archive.Size <= 0 || archive.Size > MaxArchiveBytes ||
                    (archive.Format != "zip" && archive.Format != "7z" && archive.Format != "raw"))
                    throw new InvalidDataException();
                UpscaleData.Relative(root, archive.Name);
                ValidateUrl(archive.Url);
                archive.Members = Records(row, "extract").Select(entry => Register(entry, false)).ToList();
                if (archive.Members.Count == 0 || (archive.Format == "raw" &&
                    (archive.Members.Count != 1 || archive.Members[0].Source != archive.Name || archive.Members[0].Size != archive.Size)))
                    throw new InvalidDataException();
                archives.Add(archive);
            }
            foreach (var row in Records(data, "generated_files")) generated.Add(Register(row, true));
            DownloadBytes = archives.Sum(archive => archive.Size);
            ExpandedBytes = expected.Values.Sum(member => member.Size);
            if (DownloadBytes <= 0 || DownloadBytes > MaxArchiveBytes || ExpandedBytes <= 0 ||
                ExpandedBytes > MaxExpandedBytes || DownloadBytes != UpscaleData.Number(data, "download_bytes") ||
                ExpandedBytes != UpscaleData.Number(data, "expanded_bytes") ||
                ProbeFiles.Any(path => !expected.ContainsKey(path)) || !expected.ContainsKey(SevenZip) ||
                archives.FirstOrDefault()?.Members.SingleOrDefault()?.Target != SevenZip)
                throw new InvalidDataException();
        } catch (Exception error) when (error is InvalidDataException || error is IOException || error is
            ArgumentException || error is FormatException || error is InvalidOperationException || error is OverflowException) {
            throw new UpscaleFailure("bundle_integrity");
        }
    }

    static bool ValidBundleId(string id) => id != null && id.Length >= 3 && id.Length <= 48 &&
        id.StartsWith("trt-", StringComparison.Ordinal) &&
        id.All(c => c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-' || c == '.') &&
        !id.EndsWith(".", StringComparison.Ordinal);

    Member Register(Dictionary<string, object> row, bool isGenerated)
    {
        var member = new Member {
            Source = UpscaleData.Text(row, "source"), Target = UpscaleData.Text(row, isGenerated ? "path" : "target"),
            Size = UpscaleData.Number(row, "size"), Hash = UpscaleData.Text(row, "sha256"),
            Text = UpscaleData.Text(row, "text"),
        };
        UpscaleData.Relative(root, member.Target);
        if (member.Size < 0 || member.Size > MaxExpandedBytes || expected.ContainsKey(member.Target)) throw new InvalidDataException();
        if (isGenerated) {
            if (member.Text == null || !UpscaleData.IsHash(member.Hash)) throw new InvalidDataException();
            byte[] bytes = UpscaleData.Utf8.GetBytes(member.Text);
            if (bytes.Length != member.Size || UpscaleData.Hash(bytes) != member.Hash) throw new InvalidDataException();
        } else UpscaleData.Relative(root, member.Source);
        expected.Add(member.Target, member);
        return member;
    }

    static IEnumerable<Dictionary<string, object>> Records(Dictionary<string, object> row, string field)
    {
        object source;
        if (!row.TryGetValue(field, out source)) throw new InvalidDataException();
        var values = source as object[];
        if (values == null || values.Length > 4096) throw new InvalidDataException();
        foreach (object value in values) {
            var record = value as Dictionary<string, object>;
            if (record == null) throw new InvalidDataException();
            yield return record;
        }
    }

    public bool IsReady(bool full)
    {
        try {
            request.Token.ThrowIfCancellationRequested();
            if (!File.Exists(receiptPath)) return false;
            var receipt = UpscaleData.Parse(UpscaleData.Read(receiptPath, 1024 * 1024));
            if (UpscaleData.Number(receipt, "schema") != 1 || UpscaleData.Text(receipt, "bundle_id") != BundleId ||
                UpscaleData.Text(receipt, "manifest_sha256") != ManifestHash) return false;
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var row in Records(receipt, "files")) {
                request.Token.ThrowIfCancellationRequested();
                string path = UpscaleData.Text(row, "path"), sha = UpscaleData.Text(row, "sha256");
                long size = UpscaleData.Number(row, "size");
                Member member;
                if (path == null || !seen.Add(path) || !expected.TryGetValue(path, out member) ||
                    member.Target != path || size != member.Size || !UpscaleData.IsHash(sha) ||
                    (member.Hash != null && member.Hash != sha)) return false;
                string file = UpscaleData.Relative(BundleRoot, path);
                UpscaleData.RejectLinks(file);
                var item = new FileInfo(file);
                if (!item.Exists || item.Length != size) return false;
                if (full || ProbeFiles.Contains(path)) {
                    using (var input = item.Open(FileMode.Open, FileAccess.Read, FileShare.Read))
                        if (Transfer(input, Stream.Null, size) != sha) return false;
                }
            }
            return seen.Count == expected.Count;
        } catch (Exception error) when (error is IOException || error is UnauthorizedAccessException ||
            error is UpscaleFailure || error is ArgumentException || error is InvalidDataException) { return false; }
    }

    public FileStream AcquireLock()
    {
        UpscaleData.RejectLinks(root);
        Directory.CreateDirectory(root);
        string lockPath = Path.Combine(root, "transaction.lock");
        UpscaleData.RejectLinks(lockPath);
        try {
            return new FileStream(lockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        } catch (IOException error) when ((error.HResult & 0xffff) == 32 || (error.HResult & 0xffff) == 33) {
            throw new UpscaleFailure("component_busy");
        }
    }

    public string CreateStage()
    {
        string parent = Path.Combine(root, "staging");
        UpscaleData.RejectLinks(parent);
        string stage = Path.Combine(parent, Guid.NewGuid().ToString("N"));
        if (Directory.Exists(stage) || File.Exists(stage)) throw new UpscaleFailure("bundle_conflict");
        Directory.CreateDirectory(stage);
        return stage;
    }

    public void Install()
    {
        request.Progress("verifying");
        if (IsReady(true)) return;
        UpscaleData.RejectLinks(BundleRoot);
        if (Directory.Exists(BundleRoot) || File.Exists(BundleRoot)) throw new UpscaleFailure("bundle_conflict");
        CheckPreviousReceipt();
        ulong available, capacity, free;
        if (!GetDiskFreeSpaceEx(root, out available, out capacity, out free) ||
            available < (ulong)(DownloadBytes + ExpandedBytes))
            throw new UpscaleFailure("component_disk_space");

        string stage = CreateStage();
        try {
            string candidate = Path.Combine(stage, "bundle");
            Directory.CreateDirectory(candidate);
            var files = new List<Dictionary<string, object>>();
            foreach (Archive archive in archives) {
                request.Token.ThrowIfCancellationRequested();
                string source = Path.Combine(stage, archive.Name);
                request.Progress("downloading", DownloadStatus(archive));
                Download(archive, source);
                acquired += archive.Size;
                request.Progress("extracting", DownloadStatus(archive));
                Extract(archive, source, candidate, files);
                File.Delete(source);
            }
            foreach (Member member in generated) {
                using (var input = new MemoryStream(UpscaleData.Utf8.GetBytes(member.Text)))
                    WriteMember(input, candidate, member, files);
            }

            request.Token.ThrowIfCancellationRequested();
            request.Progress("committing");
            Directory.CreateDirectory(Path.GetDirectoryName(BundleRoot));
            Directory.Move(candidate, BundleRoot);
            try {
                UpscaleData.AtomicJson(receiptPath, new Dictionary<string, object> {
                    ["schema"] = 1, ["bundle_id"] = BundleId, ["manifest_sha256"] = ManifestHash,
                    ["files"] = files,
                });
            } catch {
                try { Directory.Move(BundleRoot, candidate); }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
                throw;
            }
        } finally { UpscaleData.DeleteOwnedStage(stage); }
    }

    void CheckPreviousReceipt()
    {
        UpscaleData.RejectLinks(receiptPath);
        if (!File.Exists(receiptPath)) return;
        try {
            var previous = UpscaleData.Parse(UpscaleData.Read(receiptPath, 1024 * 1024));
            string previousId = UpscaleData.Text(previous, "bundle_id");
            if (UpscaleData.Number(previous, "schema") == 1 && previousId != BundleId && ValidBundleId(previousId) &&
                UpscaleData.IsHash(UpscaleData.Text(previous, "manifest_sha256")) &&
                Directory.Exists(Path.Combine(root, "bundles", previousId)) && Records(previous, "files").Any()) return;
        } catch (Exception error) when (error is IOException || error is ArgumentException || error is InvalidDataException) { }
        throw new UpscaleFailure("bundle_conflict");
    }

    Dictionary<string, object> DownloadStatus(Archive archive) => new Dictionary<string, object> {
        ["downloaded_bytes"] = Math.Max(acquired, downloaded), ["download_bytes"] = DownloadBytes, ["archive"] = archive.Name,
    };

    static void ValidateUrl(Uri url)
    {
        if (url.Scheme != Uri.UriSchemeHttps || !url.IsDefaultPort || url.UserInfo.Length != 0 || !DownloadHosts.Contains(url.Host))
            throw new InvalidDataException();
    }

    void Download(Archive archive, string destination)
    {
        if (archiveSource != null) {
            using (var input = archiveSource(archive.Name)) WriteArchive(archive, destination, input);
            return;
        }
        try {
            Uri url = archive.Url;
            for (int redirects = 0; redirects <= 5; redirects++) {
                request.Token.ThrowIfCancellationRequested();
                ValidateUrl(url);
                var query = (HttpWebRequest)WebRequest.Create(url);
                query.AllowAutoRedirect = false;
                query.Timeout = 45000;
                query.ReadWriteTimeout = 45000;
                query.UserAgent = "mpvnet-kit components/1";
                using (request.Token.Register(query.Abort))
                using (var response = (HttpWebResponse)query.GetResponse()) {
                    int status = (int)response.StatusCode;
                    if (status >= 300 && status < 400) {
                        string location = response.Headers["Location"];
                        if (String.IsNullOrEmpty(location)) throw new UpscaleFailure("component_download_failed");
                        url = new Uri(url, location);
                        continue;
                    }
                    if (response.StatusCode != HttpStatusCode.OK ||
                        (response.ContentLength >= 0 && response.ContentLength != archive.Size))
                        throw new UpscaleFailure("bundle_integrity");
                    using (var input = response.GetResponseStream()) WriteArchive(archive, destination, input);
                    return;
                }
            }
        } catch (WebException) {
            request.Token.ThrowIfCancellationRequested();
            throw new UpscaleFailure("component_download_failed");
        } catch (IOException) {
            request.Token.ThrowIfCancellationRequested();
            throw;
        }
        throw new UpscaleFailure("component_download_failed");
    }

    void WriteArchive(Archive archive, string destination, Stream input)
    {
        using (var output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None)) {
            string hash = Transfer(input, output, archive.Size, size => {
                downloaded = acquired + size;
                if (progress.ElapsedMilliseconds < 300) return;
                request.Progress("downloading", DownloadStatus(archive));
                progress.Restart();
            });
            if (hash != archive.Hash) throw new UpscaleFailure("bundle_integrity");
        }
    }

    void Extract(Archive archive, string source, string candidate, List<Dictionary<string, object>> files)
    {
        if (archive.Format == "raw") {
            using (var input = File.OpenRead(source)) WriteMember(input, candidate, archive.Members[0], files);
            return;
        }
        if (archive.Format == "zip") {
            using (var input = File.OpenRead(source))
            using (var zip = new ZipArchive(input, ZipArchiveMode.Read, false)) {
                var entries = zip.Entries.ToLookup(entry => entry.FullName, StringComparer.Ordinal);
                foreach (Member member in archive.Members) {
                    var entry = entries[member.Source].SingleOrDefault();
                    if (entry == null || entry.Length != member.Size || IsZipLink(entry.ExternalAttributes))
                        throw new UpscaleFailure("bundle_integrity");
                    using (var stream = entry.Open()) WriteMember(stream, candidate, member, files);
                }
            }
            return;
        }

        string sevenZip = UpscaleData.Relative(candidate, SevenZip);
        Dictionary<string, long> members = ReadSevenZipListing(sevenZip, source, candidate);
        foreach (Member member in archive.Members) {
            long size;
            if (!members.TryGetValue(member.Source, out size) || size != member.Size)
                throw new UpscaleFailure("bundle_integrity");
            uint status = UpscaleProcess.Run(sevenZip, new[] { "x", "-so", "-spd", "-bd", "--", source, member.Source.Replace('/', '\\') },
                candidate, request.Token, output => WriteMember(output, candidate, member, files));
            if (status != 0) throw new UpscaleFailure("component_extract_failed");
        }
    }

    static bool IsZipLink(int attributes) => ((attributes >> 16) & 0xf000) == 0xa000 || (attributes & 0x400) != 0;

    Dictionary<string, long> ReadSevenZipListing(string sevenZip, string source, string candidate)
    {
        var members = new Dictionary<string, long>(StringComparer.Ordinal);
        uint status = UpscaleProcess.Run(sevenZip, new[] { "l", "-ba", "-slt", "-sccUTF-8", "--", source }, candidate,
            request.Token, output => {
                using (var reader = new StreamReader(output, UpscaleData.Utf8)) {
                    string path = null, line;
                    while ((line = reader.ReadLine()) != null) {
                        if (line.StartsWith("Symbolic Link = ", StringComparison.Ordinal) ||
                            line.StartsWith("Hard Link = ", StringComparison.Ordinal))
                            throw new UpscaleFailure("component_extract_failed");
                        if (line.StartsWith("Path = ", StringComparison.Ordinal)) {
                            path = line.Substring(7).Replace('\\', '/');
                            UpscaleData.Relative(candidate, path);
                        } else if (line.StartsWith("Size = ", StringComparison.Ordinal) && path != null) {
                            long size;
                            if (!Int64.TryParse(line.Substring(7), out size) || members.ContainsKey(path))
                                throw new UpscaleFailure("component_extract_failed");
                            members.Add(path, size);
                            path = null;
                        }
                    }
                }
            });
        if (status != 0) throw new UpscaleFailure("component_extract_failed");
        return members;
    }

    void WriteMember(Stream input, string candidate, Member member, List<Dictionary<string, object>> files)
    {
        string target = UpscaleData.Relative(candidate, member.Target);
        Directory.CreateDirectory(Path.GetDirectoryName(target));
        string hash;
        using (var output = new FileStream(target, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            hash = Transfer(input, output, member.Size);
        if (member.Hash != null && member.Hash != hash) throw new UpscaleFailure("bundle_integrity");
        files.Add(new Dictionary<string, object> { ["path"] = member.Target, ["size"] = member.Size, ["sha256"] = hash });
    }

    string Transfer(Stream input, Stream output, long expectedSize, Action<long> changed = null)
    {
        var buffer = new byte[128 * 1024];
        using (var hash = SHA256.Create()) {
            long size = 0;
            int count;
            while ((count = input.Read(buffer, 0, buffer.Length)) != 0) {
                request.Token.ThrowIfCancellationRequested();
                size += count;
                if (size > expectedSize) throw new UpscaleFailure("bundle_integrity");
                hash.TransformBlock(buffer, 0, count, buffer, 0);
                output.Write(buffer, 0, count);
                if (changed != null) changed(size);
            }
            if (size != expectedSize) throw new UpscaleFailure("bundle_integrity");
            hash.TransformFinalBlock(Array.Empty<byte>(), 0, 0);
            return UpscaleData.Hex(hash.Hash);
        }
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool GetDiskFreeSpaceEx(string directory, out ulong available, out ulong total, out ulong free);
}
