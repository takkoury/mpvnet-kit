using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

// Launch the existing editor without starting PowerShell or compiling UI sources.
// The controller still owns the request, session token and persistence protocol.
public static class KitSettingsHost
{
    [STAThread]
    public static int Main(string[] arguments)
    {
        SettingsEditor editor = null;
        using (var output = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false)) { AutoFlush = true })
        {
            try
            {
                string requestPath = null;
                bool validate = false, noShow = false;
                for (int index = 0; index < arguments.Length; index++)
                {
                    string argument = arguments[index];
                    if (String.Equals(argument, "-RequestPath", StringComparison.OrdinalIgnoreCase)
                        && requestPath == null && index + 1 < arguments.Length)
                        requestPath = arguments[++index];
                    else if (String.Equals(argument, "-ValidateOnly", StringComparison.OrdinalIgnoreCase) && !validate)
                        validate = true;
                    else if (String.Equals(argument, "-NoShow", StringComparison.OrdinalIgnoreCase) && !noShow)
                        noShow = true;
                    else throw new ArgumentException("设置窗口启动参数无效。");
                }
                if (String.IsNullOrWhiteSpace(requestPath)) throw new ArgumentException("缺少设置窗口请求。");
                var request = UserPreferencesStorage.Request(requestPath);
                editor = new SettingsEditor(request, validate, noShow);
                if (validate) output.WriteLine(UserPreferencesStorage.Json().Serialize(editor.Validate(request)));
                else editor.Run();
                return 0;
            }
            catch (Exception error)
            {
                output.WriteLine(UserPreferencesStorage.Json().Serialize(new Dictionary<string, object> {
                    { "ok", false }, { "error", error.Message }
                }));
                return 1;
            }
            finally { if (editor != null) editor.Finish(); }
        }
    }
}
