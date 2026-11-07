using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Threading;
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
    public string[] ReadClipboard() { return Read(); }

    [STAThread]
    public static int Main(string[] args)
    {
        Console.OutputEncoding = new UTF8Encoding(false);
        var json = new JavaScriptSerializer { MaxJsonLength = 4 * 1024 * 1024 };
        try
        {
            var request = InputProcessor.ParseRequest(File.ReadAllText(args[0], Encoding.UTF8));
            if (args[1] == "normalize")
            {
                var entries = new List<InputEntry>();
                foreach (string path in request.Paths) entries.Add(InputProcessor.Normalize(path, request.WorkingDirectory));
                Console.WriteLine(json.Serialize(entries));
                return 0;
            }
            string[] values = args.Length > 2 ? InputProcessor.ParseClipboardText(File.ReadAllText(args[2], Encoding.UTF8)) : request.Paths;
            var source = new PlaylistInputProbe(values, args[1]);
            var response = args[1] == "wait" ? Program.Execute(request, source) : InputProcessor.Process(request, source);
            Console.WriteLine(json.Serialize(response));
        }
        catch (InputFailure error)
        {
            Console.WriteLine(json.Serialize(new InputResponse { status = "error", error_code = error.Code }));
        }
        return 0;
    }
}
