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
        if (System.String.IsNullOrWhiteSpace(path) || !Path.IsPathRooted(path) ||
            path.StartsWith(@"\\", StringComparison.Ordinal) || path.IndexOf(':', 2) >= 0)
            throw new InvalidDataException("需要本地绝对路径。");
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
    static string Target(Dictionary<string, object> request)
    {
        string path = Absolute(String(request, "settings_path"));
        if (!System.String.Equals(Path.GetFileName(path), "mpvnet-user.json", StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("只允许保存 mpvnet-user.json。");
        if (!Directory.Exists(Path.GetDirectoryName(path)) || Directory.Exists(path))
            throw new InvalidDataException("配置目录不存在或目标不是文件。");
        NoLinks(path);
        return path;
    }
    static string ReadExisting(string path)
    {
        if (new FileInfo(path).Length > Limit) throw new InvalidDataException("原配置超过 256 KiB；未覆盖原配置。");
        string text = Utf8.GetString(File.ReadAllBytes(path));
        var document = Object(Json().DeserializeObject(text.TrimStart('\uFEFF')));
        Schema(document);
        object shortcuts;
        if (document.TryGetValue("shortcuts", out shortcuts) && !(shortcuts is Dictionary<string, object>))
            throw new InvalidDataException("原快捷键配置损坏；未覆盖原配置。");
        return text;
    }
    static bool Matches(string path, bool expectedExists, string expectedText)
    {
        if (File.Exists(path) != expectedExists) return false;
        return !expectedExists || System.String.Equals(ReadExisting(path), expectedText, StringComparison.Ordinal);
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
        string temporary = null;
        bool entered = false;
        Mutex mutex = null;
        try
        {
            Schema(request);
            string path = Target(request);
            object exists;
            if (!request.TryGetValue("expected_exists", out exists) || !(exists is bool))
                throw new InvalidDataException("缺少原配置存在状态。");
            string expected = String(request, "expected_text");
            if (Utf8.GetByteCount(expected) > Limit) throw new InvalidDataException("原配置超过 256 KiB。");
            string documentText = String(request, "document_text").TrimStart('\uFEFF');
            byte[] bytes = Utf8.GetBytes(documentText);
            if (bytes.Length > Limit) throw new InvalidDataException("配置超过 256 KiB。");
            // Parse only to validate the envelope. Re-serialization would change
            // unknown high precision numbers and Microsoft JSON date strings.
            var document = Object(Json().DeserializeObject(documentText));
            Schema(document);
            object shortcuts;
            if (!document.TryGetValue("shortcuts", out shortcuts) || !(shortcuts is Dictionary<string, object>))
                throw new InvalidDataException("快捷键必须是 JSON 对象。");
            mutex = new Mutex(false, MutexName(path));
            try { entered = mutex.WaitOne(10000); } catch (AbandonedMutexException) { entered = true; }
            if (!entered) throw new IOException("配置正在保存，请稍后重试。");
            Target(request);
            if (!Matches(path, (bool)exists, expected)) return new { ok = false, error = "配置已被其他窗口修改，请重新载入后再保存。", conflict = true };
            temporary = Path.Combine(Path.GetDirectoryName(path), ".mpvnet-user-" + Guid.NewGuid().ToString("N") + ".tmp");
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                stream.Write(bytes, 0, bytes.Length);
                stream.Flush(true);
            }
            Target(request);
            NoLinks(temporary);
            if (!Matches(path, (bool)exists, expected)) return new { ok = false, error = "配置已被其他窗口修改，请重新载入后再保存。", conflict = true };
            if ((bool)exists) File.Replace(temporary, path, null);
            else File.Move(temporary, path);
            temporary = null;
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
