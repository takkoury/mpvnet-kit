using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Threading;

internal static class UpscaleHelperProbe
{
    static int Main(string[] args)
    {
        if (args[0] == "atomic-read") {
            File.WriteAllText(args[1], "{}");
            using (var held = new FileStream(args[1], FileMode.Open, FileAccess.Read, FileShare.Read)) {
                var release = new Thread(() => { Thread.Sleep(40); held.Dispose(); });
                release.Start();
                try { UpscaleData.AtomicJson(args[1], new Dictionary<string, object> { ["phase"] = "updated" }); }
                finally { release.Join(); }
            }
            Console.WriteLine(File.ReadAllText(args[1]));
            return 0;
        }
        if (args[0] == "child") {
            using (var child = Process.Start(new ProcessStartInfo(Self(), "grandchild") {
                UseShellExecute = false, CreateNoWindow = true,
            })) {
                Console.WriteLine(Process.GetCurrentProcess().Id + "," + child.Id);
                Console.Out.Flush();
                child.WaitForExit();
            }
            return 0;
        }
        if (args[0] == "grandchild") {
            Thread.Sleep(30000);
            return 0;
        }

        string requestPath = args[1];
        var result = new Dictionary<string, object>();
        try {
            using (var request = new UpscaleRequest(requestPath, UpscaleData.Parse(File.ReadAllBytes(requestPath)))) {
                if (args[0] == "job") {
                    UpscaleProcess.Run(Self(), new[] { "child" }, request.ConfigRoot, request.Token, stream => {
                        using (var reader = new StreamReader(stream)) {
                            string temporary = args[2] + ".part";
                            File.WriteAllText(temporary, reader.ReadLine());
                            File.Move(temporary, args[2]);
                            reader.ReadToEnd();
                        }
                    });
                    throw new InvalidOperationException("The worker finished without cancellation.");
                }

                var components = new UpscaleComponents(request, name => File.OpenRead(Path.Combine(request.ConfigRoot, "archives", name)));
                if (args[0] == "install") {
                    using (components.AcquireLock()) components.Install();
                }
                if (args[0] == "probe") {
                    result["component_ready"] = components.IsReady(false);
                    result["model_errors"] = new UpscaleModels(request.ConfigRoot, components.BundleRoot).Probe();
                } else if (args[0] == "prepare") {
                    var model = new UpscaleModels(request.ConfigRoot, components.BundleRoot).Select(request.Model);
                    model.RequireAsset();
                    result["padded_width"] = model.Pad(request.Width);
                    result["padded_height"] = model.Pad(request.Height);
                } else {
                    result["ready"] = components.IsReady(true);
                }
            }
        } catch (UpscaleFailure error) { result["error_reason"] = error.Message; }
        catch (OperationCanceledException) { result["error_reason"] = "cancelled"; }
        catch (Exception error) {
            Console.Error.WriteLine(error.GetType().FullName + ": " + error.Message);
            return 1;
        }
        Console.WriteLine(UpscaleData.Json().Serialize(result));
        return 0;
    }

    static string Self() => Process.GetCurrentProcess().MainModule.FileName;
}
