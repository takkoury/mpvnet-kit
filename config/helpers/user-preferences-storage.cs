using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Security.Cryptography;
using System.Collections.Generic;
using System.Web.Script.Serialization;

public static class UserPreferencesStorage
{
    public const int Limit = 262144;
    public static readonly UTF8Encoding Utf8 = new UTF8Encoding(false, true);
    public static JavaScriptSerializer Json()
    {
        return new JavaScriptSerializer { MaxJsonLength = 1048576, RecursionLimit = 64 };
    }
    public static Dictionary<string, object> Object(object value)
    {
        var result = value as Dictionary<string, object>;
        if (result == null) throw new InvalidDataException("需要 JSON 对象。");
        return result;
    }
    public static string String(Dictionary<string, object> data, string name)
    {
        object value;
        if (!data.TryGetValue(name, out value) || !(value is string))
            throw new InvalidDataException("缺少有效的 " + name + "。");
        return (string)value;
    }
    public static void Schema(Dictionary<string, object> data)
    {
        object schema;
        if (!data.TryGetValue("schema", out schema) || !(schema is int) || (int)schema != 1)
            throw new InvalidDataException("配置版本无法识别；未覆盖原配置。");
    }
    public static string Absolute(string path)
    {
        if (System.String.IsNullOrWhiteSpace(path) || path.Length < 3 ||
            !((path[0] >= 'A' && path[0] <= 'Z') || (path[0] >= 'a' && path[0] <= 'z')) ||
            path[1] != ':' || (path[2] != '\\' && path[2] != '/') || path.IndexOf(':', 2) >= 0)
            throw new InvalidDataException("需要本地绝对路径。");
        foreach (char c in path)
            if (Char.IsControl(c) || c == '\u2028' || c == '\u2029' || c == '"' || c == '<' || c == '>' || c == '|' || c == '?' || c == '*')
                throw new InvalidDataException("路径含无效字符。");
        return Path.GetFullPath(path);
    }
    public static void NoLinks(string path)
    {
        string current = path;
        while (!System.String.IsNullOrEmpty(current))
        {
            try
            {
                if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                    throw new InvalidDataException("配置路径不能经过链接或重解析点。");
            }
            catch (FileNotFoundException) { }
            catch (DirectoryNotFoundException) { }
            current = Path.GetDirectoryName(current);
        }
    }
    public static Dictionary<string, object> Request(string path)
    {
        path = Absolute(path);
        string tempRoot = Path.GetFullPath(Path.GetTempPath()).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        if (!path.StartsWith(tempRoot, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("请求文件必须位于临时目录。");
        NoLinks(path);
        if (!File.Exists(path) || new FileInfo(path).Length > 1048576)
            throw new InvalidDataException("请求文件不存在或过大。");
        var request = Object(Json().DeserializeObject(Utf8.GetString(File.ReadAllBytes(path)).TrimStart('\uFEFF')));
        Schema(request);
        return request;
    }
    static string Target(Dictionary<string, object> request, bool local)
    {
        string path = Absolute(String(request, "settings_path"));
        string name = local ? "mpvnet-local.conf" : "mpvnet-user.json";
        if (!System.String.Equals(Path.GetFileName(path), name, StringComparison.OrdinalIgnoreCase) ||
            (local && !System.String.Equals(Path.GetFileName(Path.GetDirectoryName(path)), "script-opts", StringComparison.OrdinalIgnoreCase)))
            throw new InvalidDataException(local ? "只允许保存 script-opts/mpvnet-local.conf。" : "只允许保存 mpvnet-user.json。");
        if (!Directory.Exists(Path.GetDirectoryName(path)) || Directory.Exists(path))
            throw new InvalidDataException("配置目录不存在或目标不是文件。");
        NoLinks(path);
        return path;
    }
    static void Document(string text)
    {
        var document = Object(Json().DeserializeObject(text.TrimStart('\uFEFF')));
        Schema(document);
        foreach (string name in new [] { "shortcuts", "settings" })
        {
            object value;
            if (document.TryGetValue(name, out value) && !(value is Dictionary<string, object>))
                throw new InvalidDataException(name + " 必须是 JSON 对象；未覆盖原配置。");
        }
    }
    static string ReadExisting(string path, bool local)
    {
        if (new FileInfo(path).Length > Limit) throw new InvalidDataException("原配置超过 256 KiB；未覆盖原配置。");
        string text = Utf8.GetString(File.ReadAllBytes(path));
        if (local) ParseLocal(text);
        else Document(text);
        return text;
    }
    static bool Matches(string path, bool expectedExists, string expectedText, bool local)
    {
        if (File.Exists(path) != expectedExists) return false;
        return !expectedExists || System.String.Equals(ReadExisting(path, local), expectedText, StringComparison.Ordinal);
    }
    static readonly string[] LocalNames = { "capture_root", "ffmpeg_path", "python_path", "mpv_path" };
    sealed class LocalLine
    {
        public string Body, Ending, Key;
    }
    static List<LocalLine> LocalLines(string raw)
    {
        var lines = new List<LocalLine>();
        for (int start = 0; start < raw.Length; )
        {
            int end = raw.IndexOf('\n', start);
            if (end < 0) end = raw.Length;
            string body = raw.Substring(start, end - start);
            string ending = end < raw.Length ? "\n" : "";
            if (ending.Length > 0 && body.EndsWith("\r", StringComparison.Ordinal))
            { body = body.Substring(0, body.Length - 1); ending = "\r\n"; }
            string key = null;
            // Match mp.options exactly: no trimming, and only a leading # is a comment.
            int equals = body.IndexOf('=');
            if (!body.StartsWith("#", StringComparison.Ordinal) && equals >= 0)
            {
                string candidate = body.Substring(0, equals);
                if (Array.IndexOf(LocalNames, candidate) >= 0) key = candidate;
            }
            lines.Add(new LocalLine { Body = body, Ending = ending, Key = key });
            start = end < raw.Length ? end + 1 : raw.Length;
        }
        return lines;
    }
    public static Dictionary<string, object> ParseLocal(string raw)
    {
        if (raw == null || Utf8.GetByteCount(raw) > Limit)
            throw new InvalidDataException("本机路径配置无效或超过 256 KiB。");
        var values = new Dictionary<string, object>();
        foreach (string name in LocalNames) values[name] = "";
        var seen = new HashSet<string>();
        foreach (LocalLine line in LocalLines(raw))
        {
            if (line.Key == null) continue;
            if (!seen.Add(line.Key)) throw new InvalidDataException("本机路径配置有重复项目；未覆盖原配置。");
            string value = line.Body.Substring(line.Body.IndexOf('=') + 1);
            // f:lines() strips a terminal CR even without a final LF.
            if (line.Ending.Length == 0 && value.EndsWith("\r", StringComparison.Ordinal)) value = value.Substring(0, value.Length - 1);
            values[line.Key] = value;
        }
        return values;
    }
    static string LocalDocument(string raw, Dictionary<string, object> changes)
    {
        var values = ParseLocal(raw);
        foreach (var entry in changes)
        {
            if (Array.IndexOf(LocalNames, entry.Key) < 0 || !(entry.Value is string))
                throw new InvalidDataException("本机路径项目或值无效。");
            if ((string)entry.Value != "") Absolute((string)entry.Value);
        }
        var lines = LocalLines(raw);
        string ending = "\r\n";
        foreach (LocalLine line in lines) if (line.Ending != "") { ending = line.Ending; break; }
        var result = new StringBuilder();
        var seen = new HashSet<string>();
        foreach (LocalLine line in lines)
        {
            object value;
            if (line.Key != null && changes.TryGetValue(line.Key, out value))
            {
                seen.Add(line.Key);
                if ((string)value == "") continue;
                if ((string)value != (string)values[line.Key]) { result.Append(line.Key).Append('=').Append((string)value).Append(line.Ending); continue; }
            }
            result.Append(line.Body).Append(line.Ending);
        }
        foreach (string name in LocalNames)
        {
            object value;
            if (!changes.TryGetValue(name, out value) || seen.Contains(name) || (string)value == "") continue;
            if (result.Length > 0 && result[result.Length - 1] != '\n') result.Append(ending);
            result.Append(name).Append('=').Append((string)value).Append(ending);
        }
        return result.ToString();
    }
    static string MutexName(string path)
    {
        using (var hash = SHA256.Create())
            return @"Local\MpvnetUserSettings-" + BitConverter.ToString(hash.ComputeHash(Utf8.GetBytes(path.ToUpperInvariant()))).Replace("-", "");
    }
    public static string Error(Exception error)
    {
        if (error is InvalidDataException) return error.Message;
        if (error is DecoderFallbackException) return "原配置不是有效的 UTF-8 文本；未覆盖原配置。";
        if (error is UnauthorizedAccessException) return "没有保存配置的权限，请检查文件权限后重试。";
        if (error is IOException) return "无法保存配置，请检查文件是否被其他程序占用后重试。";
        return "配置内容无效或嵌套过深；未覆盖原配置。";
    }
    public static object Save(Dictionary<string, object> request)
    {
        return SaveCore(request, false);
    }
    public static object SaveLocal(Dictionary<string, object> request)
    {
        return SaveCore(request, true);
    }
    static object SaveCore(Dictionary<string, object> request, bool local)
    {
        string temporary = null;
        bool entered = false;
        Mutex mutex = null;
        try
        {
            Schema(request);
            string path = Target(request, local);
            object exists;
            if (!request.TryGetValue("expected_exists", out exists) || !(exists is bool))
                throw new InvalidDataException("缺少原配置存在状态。");
            string expected = String(request, "expected_text");
            if (Utf8.GetByteCount(expected) > Limit) throw new InvalidDataException("原配置超过 256 KiB。");
            object changes;
            if (local && !request.TryGetValue("values", out changes)) throw new InvalidDataException("缺少本机路径项目。");
            string documentText = local ? LocalDocument((bool)exists ? expected : "", Object(request["values"])) : String(request, "document_text").TrimStart('\uFEFF');
            byte[] bytes = Utf8.GetBytes(documentText);
            if (bytes.Length > Limit) throw new InvalidDataException("配置超过 256 KiB。");
            // Parse only to validate the envelope. Re-serialization would change
            // unknown high precision numbers and Microsoft JSON date strings.
            if (!local) Document(documentText);
            mutex = new Mutex(false, MutexName(path));
            try { entered = mutex.WaitOne(10000); } catch (AbandonedMutexException) { entered = true; }
            if (!entered) throw new IOException("配置正在保存，请稍后重试。");
            Target(request, local);
            if (!Matches(path, (bool)exists, expected, local)) return new { ok = false, error = "配置已被其他窗口修改，请重新载入后再保存。", conflict = true };
            temporary = Path.Combine(Path.GetDirectoryName(path), (local ? ".mpvnet-local-" : ".mpvnet-user-") + Guid.NewGuid().ToString("N") + ".tmp");
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                stream.Write(bytes, 0, bytes.Length);
                stream.Flush(true);
            }
            Target(request, local);
            NoLinks(temporary);
            if (!Matches(path, (bool)exists, expected, local)) return new { ok = false, error = "配置已被其他窗口修改，请重新载入后再保存。", conflict = true };
            if ((bool)exists) File.Replace(temporary, path, null);
            else File.Move(temporary, path);
            temporary = null;
            // Settings may check that a subsequent read is still this write.
            // Keep the original three-field result for existing callers.
            object returnWritten;
            if (request.TryGetValue("return_written_text", out returnWritten) && returnWritten is bool && (bool)returnWritten)
                return new { ok = true, error = "", conflict = false, written_text = documentText };
            return new { ok = true, error = "", conflict = false };
        }
        catch (Exception error) { return new { ok = false, error = Error(error), conflict = false }; }
        finally
        {
            if (temporary != null)
            {
                try { NoLinks(temporary); if (File.Exists(temporary)) File.Delete(temporary); } catch { }
            }
            if (entered) mutex.ReleaseMutex();
            if (mutex != null) mutex.Dispose();
        }
    }
}
