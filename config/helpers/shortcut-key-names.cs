// This deliberately describes a small layout-independent ASCII keyboard set.
// Lua validates the same canonical names before installing any binding.
public static class ShortcutKeyNames
{
    public static string FromVirtualKey(int vk, bool ctrl, bool alt, bool shift)
    {
        string key = null;
        bool shiftedCharacter = false;
        if (vk >= 65 && vk <= 90)
        {
            key = ((char)(shift && !ctrl && !alt ? vk : vk + 32)).ToString();
            if (!ctrl && !alt) shift = false;
        }
        else if (vk >= 48 && vk <= 57)
        {
            key = shift ? ")!@#$%^&*("[vk - 48].ToString() : ((char)vk).ToString();
            shiftedCharacter = true;
        }
        else if (vk >= 112 && vk <= 135) key = "F" + (vk - 111);
        else
        {
            switch (vk)
            {
                case 8: key = "BS"; break;
                case 9: key = "Tab"; break;
                case 13: key = "Enter"; break;
                case 32: key = "Space"; break;
                case 33: key = "PGUP"; break;
                case 34: key = "PGDWN"; break;
                case 35: key = "End"; break;
                case 36: key = "Home"; break;
                case 37: key = "Left"; break;
                case 39: key = "Right"; break;
                case 186: key = shift ? ":" : ";"; shiftedCharacter = true; break;
                case 187: key = shift ? "+" : "="; shiftedCharacter = true; break;
                case 188: key = shift ? "<" : ","; shiftedCharacter = true; break;
                case 189: key = shift ? "_" : "-"; shiftedCharacter = true; break;
                case 190: key = shift ? ">" : "."; shiftedCharacter = true; break;
                case 191: key = shift ? "?" : "/"; shiftedCharacter = true; break;
                case 192: key = shift ? "~" : "`"; shiftedCharacter = true; break;
                case 219: key = shift ? "{" : "["; shiftedCharacter = true; break;
                case 220: key = shift ? "|" : "\\"; shiftedCharacter = true; break;
                case 221: key = shift ? "}" : "]"; shiftedCharacter = true; break;
                case 222: key = shift ? "\"" : "'"; shiftedCharacter = true; break;
            }
        }
        if (key == null || (!ctrl && !alt && key == "_") || (ctrl && !alt && !shift && key == "f") ||
            (alt && !ctrl && !shift && key == "F4")) return null;
        if (shiftedCharacter) shift = false;
        return (ctrl ? "Ctrl+" : "") + (alt ? "Alt+" : "") + (shift ? "Shift+" : "") + key;
    }

    public static bool IsCanonical(string value)
    {
        if (System.String.IsNullOrEmpty(value)) return false;
        for (int modifiers = 0; modifiers < 8; modifiers++)
            for (int vk = 0; vk <= 222; vk++)
                if (System.String.Equals(value, FromVirtualKey(vk, (modifiers & 1) != 0,
                    (modifiers & 2) != 0, (modifiers & 4) != 0), System.StringComparison.Ordinal)) return true;
        return false;
    }
}
