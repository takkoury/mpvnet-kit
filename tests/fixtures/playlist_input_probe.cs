using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Threading;
using System.Runtime.InteropServices;
using System.Web.Script.Serialization;
using KitPlaylistInput;

public sealed class PlaylistInputProbe : IInputSource
{
    readonly string[] values;
    readonly string behavior;
    PlaylistInputProbe(string[] input, string action) { values = input; behavior = action; }
    string[] Read()
    {
        if (behavior == "cancel") return null;
        if (behavior == "unavailable") throw new InputFailure("input_unavailable");
        if (behavior == "wait") { Console.WriteLine("READY"); Console.Out.Flush(); Thread.Sleep(30000); }
        return values;
    }
    public string[] SelectFiles(InputRequest request) { return Read(); }
    public string SelectFolder(InputRequest request)
    {
        var paths = Read();
        return paths == null || paths.Length == 0 ? null : paths[0];
    }
    public string[] ReadClipboard() { return Read(); }
    public string SelectSavePath(InputRequest request)
    {
        var paths = Read();
        return paths == null || paths.Length == 0 ? null : paths[0];
    }

    sealed class InjectedScanner : IDirectoryScanner
    {
        readonly string behavior;
        public InjectedScanner(string action) { behavior = action; }
        public IEnumerable<string> EnumerateEntries(string directory)
        {
            if (behavior == "scanner-denied") throw new UnauthorizedAccessException();
            if (behavior == "scanner-disappeared") throw new DirectoryNotFoundException();
            if (behavior == "scanner-many-unrelated")
            {
                for (int i = 0; i < 60000; i++) yield return Path.Combine(directory, "ignored.txt");
                yield break;
            }
            if (behavior == "scanner-many-candidates")
            {
                for (int i = 0; i < 6000; i++) yield return Path.Combine(directory, "candidate.mkv");
                yield break;
            }
            foreach (string path in Directory.EnumerateFileSystemEntries(directory))
            {
                yield return path;
                if (behavior == "scanner-late-denied") throw new UnauthorizedAccessException();
            }
        }
    }

    [STAThread]
    public static int Main(string[] args)
    {
        Console.OutputEncoding = new UTF8Encoding(false);
        var json = new JavaScriptSerializer { MaxJsonLength = 4 * 1024 * 1024 };
        try
        {
            var request = InputProcessor.ParseRequest(File.ReadAllText(args[0], Encoding.UTF8));
            if (args[1] == "folder-com")
            {
                var dialog = FolderPicker.Create();
                try
                {
                    uint options;
                    dialog.GetOptions(out options);
                    Console.WriteLine(json.Serialize(new { options = options, required = FolderPicker.FolderOptions }));
                }
                finally { Marshal.FinalReleaseComObject(dialog); }
                return 0;
            }
            if (args[1] == "normalize")
            {
                var entries = new List<InputEntry>();
                foreach (string path in request.Paths) entries.Add(InputProcessor.Normalize(path, request.WorkingDirectory));
                Console.WriteLine(json.Serialize(entries));
                return 0;
            }
            string[] values = args.Length > 2 && args[2].Length != 0 ? InputProcessor.ParseClipboardText(File.ReadAllText(args[2], Encoding.UTF8)) : request.Paths;
            var source = new PlaylistInputProbe(values, args[1]);
            var scanner = args[1].StartsWith("scanner-", StringComparison.Ordinal) ? new InjectedScanner(args[1]) : null;
            Func<PlaylistReader> reader = args.Length > 3 && args[3].Length != 0 ?
                (Func<PlaylistReader>)(() => new PlaylistReader(args[3], request.MetadataCodepage)) : null;
            Action ensureParent = args[1] == "parent-exited" ? (Action)(() => { throw new InputFailure("parent_unavailable"); }) : null;
            var response = args[1] == "wait" ? Program.Execute(request, source) : InputProcessor.Process(request, source, scanner, reader, ensureParent);
            Console.WriteLine(json.Serialize(response));
        }
        catch (InputFailure error)
        {
            Console.WriteLine(json.Serialize(new InputResponse { status = "error", error_code = error.Code }));
        }
        return 0;
    }
}
