using System;
using System.Linq;
using System.Collections.Generic;
using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

public sealed partial class SettingsEditor
{
    readonly Queue<string> closePages = new Queue<string>();
    readonly List<string> closeSavedPages = new List<string>();
    bool closeSaveRunning, closeAccepted, settingsSaveUnconfirmed;
    string closeSavePage = "", closeSavePhase = "", closeRefreshId = "";
    DateTime closeStepStarted;
    TextBlock closeProgress;

    bool PageDirty(string id) { return id == "shortcuts" ? shortcuts.Dirty : model.Dirty(id); }
    void ShowClosePrompt()
    {
        shortcuts.CancelCapture();
        var panel = new StackPanel();
        panel.Children.Add(new TextBlock { Text = "保存对设置的修改？", FontSize = 18, FontWeight = FontWeights.SemiBold });
        panel.Children.Add(new TextBlock { Text = "以下分类有未保存的修改：\n" + String.Join("、", DirtyPages().Select(SettingsDraft.PageName)) +
            (settingsSaveUnconfirmed || shortcuts.SaveUnconfirmed ? "\n先前提交的保存仍可能完成；不保存仅放弃尚未提交的修改。" : ""),
            TextWrapping = TextWrapping.Wrap, Foreground = Brush("#BCBCBC"), Margin = new Thickness(0,14,0,24) });
        var actions = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        panel.Children.Add(actions);
        var accept = CloseChoice("保存", "CloseSave", BeginCloseSave);
        accept.Background = Brush("#1287BB"); accept.BorderBrush = Brush("#1287BB"); accept.IsDefault = true;
        accept.IsEnabled = !disconnected && !settingsSaveUnconfirmed && !shortcuts.SaveUnconfirmed;
        var discard = CloseChoice("不保存", "CloseDiscard", delegate { CloseOverlay(); CompleteClosing(); });
        var cancel = CloseChoice("取消", "CloseCancel", CloseOverlay); cancel.Margin = new Thickness(0);
        actions.Children.Add(accept); actions.Children.Add(discard); actions.Children.Add(cancel);
        ShowOverlay(panel, accept.IsEnabled ? accept : cancel);
    }
    Button CloseChoice(string label, string id, Action action)
    {
        var button = Button(label, action); button.Width = 104; button.Height = 36;
        button.Padding = new Thickness(12,6,12,6); button.Margin = new Thickness(0,0,8,0);
        System.Windows.Automation.AutomationProperties.SetAutomationId(button,id);
        return button;
    }
    void CompleteClosing()
    {
        closeSaveRunning = false; closeSavePhase = ""; forceClose = true;
        if (validation) OnClosing(this,new CancelEventArgs()); else Close();
    }
    string CloseSaveProblem(string id)
    {
        if (disconnected) return "播放器连接已中断。";
        if (settingsSaveUnconfirmed || shortcuts.SaveUnconfirmed) return "先前保存的结果尚未确认，请等待回执后重试。";
        if (id == "shortcuts") return shortcuts.CanSave ? "" : (shortcuts.Notice.Length > 0 ? shortcuts.Notice : "快捷键当前无法保存。");
        string error = SettingsDraft.Str(latest,id == "paths" ? "paths_error" : "error");
        if (error.Length > 0) return error;
        if (SettingsDraft.Flag(latest,"saving")) return "另一项保存仍在进行，请稍后重试。";
        string baseline;
        if (!model.Revisions.TryGetValue(id,out baseline) || baseline != SettingsDraft.Str(latest,id == "paths" ? "paths_revision" : "revision"))
            return "配置已被其他窗口修改，请核对后再保存。";
        try { model.Values(id); } catch (Exception e) { return e.Message; }
        return "";
    }
    void BeginCloseSave()
    {
        if (saving || shortcuts.Saving || closeSaveRunning) return;
        CloseOverlay(); search.Clear();
        closePages.Clear(); closeSavedPages.Clear(); localError = "";
        foreach (string id in DirtyPages()) closePages.Enqueue(id);
        // Catch known conflicts/invalid input before writing the first page.
        foreach (string id in closePages) {
            string problem = CloseSaveProblem(id);
            if (problem.Length > 0) { closeSavePage = id; StopCloseSave(problem); return; }
        }
        closeSaveRunning = true;
        var panel = new StackPanel { Focusable = true };
        panel.Children.Add(new TextBlock { Text = "正在保存设置…", FontSize = 18, FontWeight = FontWeights.SemiBold });
        closeProgress = new TextBlock { Margin = new Thickness(0,16,0,0), TextWrapping = TextWrapping.Wrap, Foreground = Brush("#BCBCBC") };
        panel.Children.Add(closeProgress); ShowOverlay(panel,panel);
        NextCloseSave();
    }
    void NextCloseSave()
    {
        if (!closeSaveRunning) return;
        while (closePages.Count > 0 && !PageDirty(closePages.Peek())) closePages.Dequeue();
        if (closePages.Count == 0) { CloseOverlay(); CompleteClosing(); return; }
        closeSavePage = closePages.Dequeue(); SelectPage(closeSavePage);
        closeSavePhase = "refresh"; closeRefreshId = Guid.NewGuid().ToString("N"); closeStepStarted = DateTime.UtcNow;
        closeProgress.Text = "正在保存“" + SettingsDraft.PageName(closeSavePage) + "”…";
        if (closeSavePage == "shortcuts") shortcuts.RequestRefresh(closeRefreshId);
        else Action("editor-refresh",closeRefreshId);
    }
    void CloseRefreshReceived(string domain, string refreshId)
    {
        if (!closeSaveRunning || closeSavePhase != "refresh" || refreshId != closeRefreshId ||
            (closeSavePage == "shortcuts") != (domain == "shortcuts")) return;
        // The fresh state is already adopted before this callback. Enabling the
        // body synchronously permits model checks; the modal scrim still blocks input.
        bodyPanel.IsEnabled = true; Refresh();
        if (!PageDirty(closeSavePage)) { bodyPanel.IsEnabled = false; NextCloseSave(); return; }
        string problem = CloseSaveProblem(closeSavePage);
        if (problem.Length > 0) { StopCloseSave(problem); return; }
        if (!save.IsEnabled) { StopCloseSave(notice.Text.Length > 0 ? notice.Text : "当前分类无法保存。"); return; }
        closeSavePhase = "save"; closeStepStarted = DateTime.UtcNow; Save();
        if (closeSaveRunning) {
            bodyPanel.IsEnabled = false;
            if (!saving && !shortcuts.Saving) StopCloseSave("保存请求未能送达，请核对配置。");
        }
    }
    void ClosePageSaved(bool succeeded, string error)
    {
        if (!closeSaveRunning || closeSavePhase != "save") return;
        if (!succeeded) { StopCloseSave(error.Length > 0 ? error : "保存未成功，草稿已保留。"); return; }
        closeSavedPages.Add(closeSavePage);
        if (error.Length > 0) { StopCloseSave(error); return; }
        NextCloseSave();
    }
    void ShortcutsState(Dictionary<string,object> state)
    {
        shortcuts.Adopt(state);
        CloseRefreshReceived("shortcuts",shortcuts.RefreshId);
        if (closeSaveRunning && closeSavePage == "shortcuts" && closeSavePhase == "save" && !shortcuts.Saving)
            ClosePageSaved(shortcuts.LastSaveSucceeded,shortcuts.LastSaveSucceeded ? "" : shortcuts.Notice);
        if (search.Text.Trim().Length > 0) Search();
    }
    void PollCloseSave()
    {
        if (!closeSaveRunning) return;
        if (closeSavePhase == "save" && closeSavePage == "shortcuts" && !shortcuts.Saving) {
            ClosePageSaved(shortcuts.LastSaveSucceeded,shortcuts.LastSaveSucceeded ? "" : shortcuts.Notice); return;
        }
        if ((DateTime.UtcNow - closeStepStarted).TotalSeconds > 20) {
            if (closeSavePhase == "save" && saving) MarkSettingsSaveUnconfirmed();
            else StopCloseSave(closeSavePhase == "refresh" ? "未收到最新配置，请稍后重试。" : "尚未收到保存结果，请先核对配置；窗口保持打开。");
        }
    }
    void MarkSettingsSaveUnconfirmed()
    {
        settingsSaveUnconfirmed = true; saving = false;
        string reason = "保存结果尚未确认，已暂停后续保存。可等待回执，或关闭窗口；关闭不会撤回已提交的保存请求。";
        if (closeSaveRunning) StopCloseSave(reason); else { localError = reason; Refresh(); }
    }
    void StopCloseSave(string reason)
    {
        closeSaveRunning = false; closeSavePhase = ""; closePages.Clear(); CloseOverlay(); bodyPanel.IsEnabled = true;
        if (closeSavePage.Length > 0) SelectPage(closeSavePage);
        localError = "未能完成关闭前保存：" + reason;
        if (closeSavedPages.Count > 0) localError += "\n已保存：" + String.Join("、",closeSavedPages.Select(SettingsDraft.PageName)) + "。其余未保存的修改仍保留。";
        Refresh();
    }
}
