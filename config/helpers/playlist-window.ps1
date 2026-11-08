param(
    [string]$PayloadPath = '',
    [int]$WaitPid = 0,
    [switch]$NoShow,
    [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false)
$outputWriter = New-Object IO.StreamWriter([Console]::OpenStandardOutput(), $utf8)
$outputWriter.AutoFlush = $true
if ($WaitPid -gt 0) {
    try {
        $waitProcess = [Diagnostics.Process]::GetProcessById($WaitPid)
        [void]$waitProcess.WaitForExit(2500)
        $waitProcess.Dispose()
    } catch {}
    $outputWriter.WriteLine('{"ok":true}')
    $outputWriter.Dispose()
    exit 0
}

$phase = 'input'
$parentProcess = $null
$pipe = $null
$form = $null
$timer = $null
$context = $null
$menu = $null
$searchDismiss = $null
$script:exiting = $false
$script:desiredVisible = $false
[object[]]$script:playlist = @()
$script:playlistPosition = -1
$script:fullscreen = $false
$script:dragging = $false
$script:renderDirty = $false
$script:rendering = $false
$script:dropTargetId = ''
$script:dropAfter = $false
$script:lastSignature = ''
$script:requestId = 0
$script:receivedPlaylist = $false
$script:sentReady = $false
$script:searching = $false
$script:hoverId = ''
$follower = $null
$tip = $null
$keyFilter = $null
$scroll = $null
$script:validationActions = New-Object 'Collections.Generic.List[object]'

function Send-Command([object[]]$command) {
    $script:requestId++
    $writer.WriteLine((@{command = $command; request_id = $script:requestId} | ConvertTo-Json -Compress -Depth 8))
}

function Send-Action([string]$action, [string]$id = '', [string]$target = '', [string]$side = '') {
    if ($ValidateOnly) {
        $script:validationActions.Add(@{action = $action; id = $id; target = $target; side = $side})
        return
    }
    Send-Command @('script-message-to', [string]$payload.script, 'action', [string]$payload.token, $action, $id, $target, $side)
}

function Safe-Label($entry) {
    $value = if ($entry.title) { [string]$entry.title } else { [string]$entry.filename }
    if ($value -match '^[\w+.-]+://') {
        $value = ($value -split '[?#]', 2)[0].TrimEnd('/')
        try {
            $uri = New-Object Uri($value)
            $value = [Uri]::UnescapeDataString(($uri.AbsolutePath.TrimEnd('/') -split '/')[-1])
            if (-not $value) { $value = $uri.Host }
        } catch { $value = ($value -split '/')[-1] }
    } elseif (-not $entry.title) {
        $value = ($value -split '[/\\]')[-1]
    }
    $value = [regex]::Replace($value, '[\x00-\x1f]', ' ').Trim()
    if (-not $value) { $value = '未命名媒体' }
    return $value
}

function Update-ContextMenuState {
    if (-not $menu) { return }
    $exists = $false
    if ($menu.TargetId) {
        foreach ($entry in $script:playlist) {
            if ([string]$entry.id -eq $menu.TargetId) { $exists = $true; break }
        }
    }
    $menu.SetState($script:playlist.Count, [bool]$counter.Enabled, $exists)
}

function Update-ContextMenuHints($state) {
    if (-not $menu) { return }
    $actions = @{
        'file.open'='open-files'; 'file.open-folder'='open-folder'; 'file.open-clipboard'='open-clipboard';
        'file.append'='append-files'; 'file.append-folder'='append-folder'; 'file.append-clipboard'='append-clipboard';
        'file.save-playlist'='save-playlist'; 'playlist.previous'='previous'; 'playlist.next'='next';
        'playlist.first'='first'; 'playlist.last'='last'; 'playlist.shuffle'='shuffle'
    }
    foreach ($name in $actions.Values) { $menu.SetHint($name, '') }
    if ($null -eq $state -or $state.schema -ne 1) { return }
    foreach ($entry in @($state.actions)) {
        if ($actions.ContainsKey([string]$entry.id)) {
            $keys = @($entry.keys | Where-Object { $_ -is [string] -and $_.Length -gt 0 -and $_.Length -le 32 })
            $menu.SetHint($actions[[string]$entry.id], ($keys -join ', '))
        }
    }
}

function Render-Queue {
    if ($script:dragging) { $script:renderDirty = $true; return }
    $needle = if ($script:searching) { $filter.Text.Trim() } else { '' }
    $rows = New-Object 'Collections.Generic.List[object]'
    for ($i = 0; $i -lt $script:playlist.Count; $i++) {
        $entry = $script:playlist[$i]
        $label = Safe-Label $entry
        if (-not $needle -or $label.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $rows.Add(@{id = [string]$entry.id; index = $i; label = $label; entry = $entry})
        }
    }
    $rowsById = @{}
    foreach ($row in $rows) { $rowsById[$row.id] = $row }
    $signature = (@($rows | ForEach-Object { $_.id + ':' + $_.label }) -join "`n")
    $counter.Text = if ($script:playlist.Count -eq 0) { '0 / 0' } elseif ($script:searching) { '{0} / {1}' -f $rows.Count, $script:playlist.Count } else { '{0:00} / {1:00}' -f ([Math]::Max(0, $script:playlistPosition + 1)), $script:playlist.Count }
    $counter.Enabled = $script:playlistPosition -ge 0 -and $script:playlistPosition -lt $script:playlist.Count
    $list.EmptyText = if ($script:playlist.Count -eq 0) { '播放列表为空' } elseif ($rows.Count -eq 0) { '没有匹配的项目' } else { '' }
    $list.AccessibleDescription = $list.EmptyText
    $script:rendering = $true
    try {
        if ($signature -ne $script:lastSignature) {
            if ($tip) { $tip.Cancel() }
            $selected = @($list.SelectedItems | ForEach-Object { [string]$_.Tag.id })
            $topId = if ($list.TopItem) { [string]$list.TopItem.Tag.id } else { '' }
            $list.BeginUpdate()
            try {
                $list.Items.Clear()
                foreach ($row in $rows) {
                    $item = New-Object Windows.Forms.ListViewItem(('{0:00}' -f ($row.index + 1)))
                    [void]$item.SubItems.Add($row.label)
                    $item.Tag = $row
                    $item.Name = [string]$row.id
                    [void]$list.Items.Add($item)
                    if ($selected -contains $row.id) { $item.Selected = $true }
                }
                $newTop = @($list.Items | Where-Object { $_.Tag.id -eq $topId })
                if ($newTop.Count) { $list.TopItem = $newTop[0] }
            } finally { $list.EndUpdate() }
            $script:lastSignature = $signature
        }
        # Current changes are repainted without rebuilding or scrolling the view.
        foreach ($item in $list.Items) {
            if ($rowsById.ContainsKey([string]$item.Tag.id)) { $item.Tag = $rowsById[[string]$item.Tag.id] }
            $number = '{0:00}' -f ($item.Tag.index + 1)
            if ($item.Text -ne $number) { $item.Text = $number }
        }
        $list.FitTitleColumn()
        $list.Invalidate()
    } finally { $script:rendering = $false; $script:renderDirty = $false }
    Update-ContextMenuState
}

function Invalidate-HoverRow([string]$id) {
    if (-not $id) { return }
    foreach ($row in $list.Items) {
        if ([string]$row.Tag.id -eq $id) { $list.Invalidate($row.Bounds); return }
    }
}

function Hide-Window {
    $script:desiredVisible = $false
    if ($keyFilter) { $keyFilter.ReleaseAll() }
    if ($tip) { $tip.Cancel() }
    if ($menu) { $menu.Close() }
    if ($follower) { $follower.UpdatePolicy($false, $script:fullscreen) }
    $form.Hide()
    if (-not $ValidateOnly -and -not $script:exiting) {
        Send-Command @('script-message-to', [string]$payload.script, 'window-hidden', [string]$payload.token)
    }
}

function Set-SearchMode([bool]$enabled, [bool]$focusControl = $true) {
    if ($tip) { $tip.Cancel() }
    if ($keyFilter) { $keyFilter.ReleaseAll(); $keyFilter.SearchActive = $enabled }
    $script:searching = $enabled
    if ($searchDismiss) { $searchDismiss.Active = $enabled }
    $filter.Visible = $enabled
    $footer.Searching = $enabled
    $searchButton.Active = $enabled
    $searchButton.AccessibleName = if ($enabled) { '关闭搜索（Esc）' } else { '搜索播放列表（Ctrl+F）' }
    $searchButton.Invalidate()
    $counter.ForeColor = if ($enabled) { [PlaylistStyle]::Accent } else { [PlaylistStyle]::Muted }
    if ($enabled) { if ($focusControl) { [void]$filter.Focus() } }
    else { $filter.Text = ''; if ($focusControl) { [void]$list.Focus() } }
    Render-Queue
    $footer.PerformLayout()
}

function Locate-Entry([string]$id) {
    # The player resolves its current ID when requested. A changed/removed ID
    # must never fall back to a cached position or a filtered row index.
    if (-not $id -or -not @($script:playlist | Where-Object { [string]$_.id -eq $id }).Count) { return }
    $hadFocus = $form.ContainsFocus
    Set-SearchMode $false $hadFocus
    foreach ($item in $list.Items) {
        $item.Selected = [string]$item.Tag.id -eq $id
        if ($item.Selected) {
            $item.Focused = $true
            $item.EnsureVisible()
        }
    }
    $list.FitTitleColumn()
    $list.Invalidate()
}

function Tooltip-Text($entry) {
    $name = [string]$entry.filename
    if ($name -match '^[\w+.-]+://') { return (Safe-Label $entry) + [Environment]::NewLine + $name }
    try {
        if (-not [IO.Path]::IsPathRooted($name) -and $payload.working_directory) { $name = Join-Path ([string]$payload.working_directory) $name }
        return [IO.Path]::GetFullPath($name)
    } catch { return $name }
}

function Clear-DropMarker {
    $script:dropTargetId = ''
    $list.InsertionMark.Index = -1
    $list.Invalidate()
}

function Exit-Window {
    $script:exiting = $true
    if ($keyFilter) { $keyFilter.ReleaseAll() }
    # A GUI owner may be synchronously waiting for mpv shutdown. Detach this
    # helper's own window before disposal to avoid cross-process owner messages.
    if ($form -and $form.IsHandleCreated) {
        [void][PlaylistNative]::SetWindowLongPtr($form.Handle, -8, [IntPtr]::Zero)
    }
    if ($tip) { $tip.Cancel() }
    if ($context) { $context.ExitThread() }
}

try {
    if (-not [IO.Path]::IsPathRooted($PayloadPath)) { throw 'payload' }
    $fullPath = [IO.Path]::GetFullPath($PayloadPath)
    if ([IO.Path]::GetDirectoryName($fullPath).TrimEnd('\') -ine [IO.Path]::GetTempPath().TrimEnd('\') -or
        [IO.Path]::GetFileName($fullPath) -notmatch '^mpvnet-playlist-[\d-]+\.json$') { throw 'payload' }
    $payload = [IO.File]::ReadAllText($fullPath, $utf8) | ConvertFrom-Json
    [IO.File]::Delete($fullPath)
    if ([string]$payload.token -notmatch '^[\d-]+$' -or [string]$payload.script -notmatch '^[\w-]+$') { throw 'identity' }
    if (-not $ValidateOnly) {
        $parentProcess = [Diagnostics.Process]::GetProcessById([int]$payload.parent_pid)
        if ($parentProcess.HasExited) { exit 0 }
    }
    $script:desiredVisible = [bool]$payload.visible
    $phase = 'window'
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Add-Type -Path (Join-Path $PSScriptRoot 'KitPlaylistWindow.dll')
    # One DPI coordinate system for native rectangles, Screen and Form bounds.
    try { [void][PlaylistNative]::SetThreadDpiAwarenessContext([IntPtr](-4)) } catch {}
    [Windows.Forms.Application]::SetUnhandledExceptionMode([Windows.Forms.UnhandledExceptionMode]::CatchException)
    [Windows.Forms.Application]::add_ThreadException({
        param($sender, $errorArgs)
        # WinForms otherwise opens a modal error dialog, blocking hide and exit.
        $script:sessionFailed = $true
        $script:sessionErrorClass = $errorArgs.Exception.GetType().Name
        $script:sessionErrorLine = 0
        for ($failure = $errorArgs.Exception; $failure; $failure = $failure.InnerException) {
            if ($failure.ErrorRecord -and $failure.ErrorRecord.InvocationInfo.ScriptLineNumber) {
                $script:sessionErrorClass = $failure.GetType().Name
                $script:sessionErrorLine = [int]$failure.ErrorRecord.InvocationInfo.ScriptLineNumber
            }
        }
        $baseFailure = $errorArgs.Exception.GetBaseException()
        if (-not $script:sessionErrorLine) {
            $script:sessionErrorMember = $baseFailure.TargetSite.Name
            $script:sessionErrorType = $baseFailure.TargetSite.DeclaringType.FullName
        }
        $script:sessionErrorCallers = New-Object 'Collections.Generic.List[string]'
        $managedTrace = New-Object Diagnostics.StackTrace($baseFailure)
        foreach ($frame in $managedTrace.GetFrames()) {
            $method = $frame.GetMethod()
            $typeName = if ($method.DeclaringType) { $method.DeclaringType.FullName } else { '' }
            if ($typeName.StartsWith('System.Windows.Forms.') -or $typeName.StartsWith('System.Drawing.')) {
                $script:sessionErrorCallers.Add($typeName + '.' + $method.Name)
                if ($script:sessionErrorCallers.Count -ge 12) { break }
            }
        }
        if ($baseFailure -is [ArgumentException] -and $baseFailure.ParamName -match '^[A-Za-z_][A-Za-z0-9_]{0,79}$') {
            $script:sessionErrorParameter = $baseFailure.ParamName
        }
        Exit-Window
    })
    [Windows.Forms.Application]::EnableVisualStyles()
    $form = New-Object PlaylistForm
    $form.Text = ''
    $form.ShowInTaskbar = $false
    $form.FormBorderStyle = 'Sizable'
    $form.MinimizeBox = $false
    $form.MaximizeBox = $false
    $form.ShowIcon = $false

    $form.StartPosition = 'Manual'
    $form.ClientSize = New-Object Drawing.Size(340, 420)
    if ($ValidateOnly -and $payload.client_width) { $form.ClientSize = New-Object Drawing.Size(([Math]::Max(220,[int]$payload.client_width)),420) }
    $form.BackColor = [PlaylistStyle]::Background
    $form.ForeColor = [PlaylistStyle]::Text
    $mainFont = New-Object Drawing.Font('Microsoft YaHei UI', 9.75)
    $currentFont = New-Object Drawing.Font($mainFont, [Drawing.FontStyle]::Bold)
    $numberFont = New-Object Drawing.Font('Microsoft YaHei UI', 8.25)
    $form.Font = $mainFont
    $form.KeyPreview = $true
    $form.AutoScaleMode = 'Dpi'
    $form.AutoScaleDimensions = New-Object Drawing.SizeF(96, 96)
    $caption = New-Object PlaylistBar
    $caption.Dock = 'Top'
    $caption.Height = 32
    $caption.BackColor = [PlaylistStyle]::Chrome
    $captionLabel = New-Object Windows.Forms.Label
    $captionLabel.Text = '播放列表'
    $captionLabel.Dock = 'Fill'
    $captionLabel.Padding = New-Object Windows.Forms.Padding(16, 0, 0, 0)
    $captionLabel.TextAlign = 'MiddleLeft'
    $captionLabel.ForeColor = [PlaylistStyle]::Muted
    $captionFont = New-Object Drawing.Font('Microsoft YaHei UI', 9)
    $captionLabel.Font = $captionFont
    $closeButton = New-Object PlaylistCloseButton
    $closeButton.BackColor = [PlaylistStyle]::Chrome
    $closeButton.Dock = 'Right'
    $closeButton.Add_Click({ $form.Close() })
    $searchButton = New-Object PlaylistCloseButton
    $searchButton.BackColor = [PlaylistStyle]::Chrome
    $searchButton.SearchIcon = $true
    $searchButton.AccessibleName = '搜索播放列表（Ctrl+F）'
    $searchButton.Dock = 'None'
    $searchButton.Width = 36
    $searchButton.Add_Click({ Set-SearchMode (-not $script:searching); if ($script:searching) { $filter.SelectAll() } })
    $caption.Controls.Add($captionLabel)
    $caption.Controls.Add($closeButton)
    $form.CaptionPanel = $caption
    $form.CaptionLabel = $captionLabel
    $form.CloseButton = $closeButton
    $filter = New-Object Windows.Forms.TextBox
    $footer = New-Object PlaylistFooter
    $footer.Editor = $filter
    $footer.Search = $searchButton
    $footer.Dock = 'Bottom'
    $footer.Height = 32
    $footer.Padding = New-Object Windows.Forms.Padding(8, 3, 8, 3)
    $footer.BackColor = [PlaylistStyle]::Chrome
    $footer.Font = $captionFont
    $form.FooterPanel = $footer
    $filter.Dock = 'None'
    $filter.Visible = $false
    $filter.BackColor = [PlaylistStyle]::Hover
    $filter.ForeColor = $form.ForeColor
    $filter.BorderStyle = 'FixedSingle'
    $filter.AccessibleName = '搜索播放列表'
    $counter = New-Object PlaylistCounterButton
    $counter.Dock = 'None'
    $counter.TextAlign = 'MiddleCenter'
    $counter.ForeColor = [PlaylistStyle]::Muted
    $counter.BackColor = $footer.BackColor
    $counter.FlatStyle = 'Flat'
    $counter.FlatAppearance.BorderSize = 0
    $counter.FlatAppearance.MouseOverBackColor = [PlaylistStyle]::Hover
    $counter.FlatAppearance.MouseDownBackColor = [PlaylistStyle]::Selected
    $counter.Cursor = [Windows.Forms.Cursors]::Hand
    $counter.AccessibleName = [PlaylistStyle]::Locate
    $counter.TabStop = $false
    $footer.Counter = $counter
    $counter.Add_TextChanged({ $footer.PerformLayout() })
    $list = New-Object PlaylistList
    $list.AccessibleName = '播放列表'
    $list.Dock = 'Fill'
    $list.View = 'Details'
    $list.FullRowSelect = $true
    $list.MultiSelect = $false
    $list.HideSelection = $false
    $list.ShowItemToolTips = $false
    $list.HeaderStyle = 'None'
    $list.BorderStyle = 'None'
    $list.BackColor = $form.BackColor
    $list.ForeColor = $form.ForeColor
    $list.AllowDrop = $true
    $form.AllowDrop = $true
    $list.OwnerDraw = $true
    [void]$list.Columns.Add('', 44)
    [void]$list.Columns.Add('Title', 270)
    $rowImages = New-Object Windows.Forms.ImageList
    $rowImages.ImageSize = New-Object Drawing.Size(1, 34)
    $rowBitmap = New-Object Drawing.Bitmap(1, 34)
    $rowImages.Images.Add($rowBitmap)
    $list.SmallImageList = $rowImages
    $scroll = New-Object PlaylistScroll($list)
    $form.Controls.Add($list)
    $form.Controls.Add($scroll)
    $footer.Controls.Add($filter)
    $footer.Controls.Add($counter)
    $footer.Controls.Add($searchButton)
    $form.Controls.Add($footer)
    $form.Controls.Add($caption)
    $tip = New-Object PlaylistTip($form.Font)
    $keyFilter = New-Object PlaylistKeys($form)
    $keyFilter.add_Transmit({
        param($keyPhase, $keyName)
        if (-not $ValidateOnly -and $writer -and -not $script:exiting) { Send-Command @('script-message-to', [string]$payload.script, 'key', [string]$payload.token, $keyPhase, $keyName) }
    })
    $searchDismiss = New-Object PlaylistSearchDismiss($form, $filter)
    $searchDismiss.add_Dismiss({ Set-SearchMode $false })
    $menu = New-Object PlaylistContextMenu($form, $list, $keyFilter)
    $menu.add_Prepare({ if ($tip) { $tip.Cancel() }; Update-ContextMenuState })
    $menu.add_InvokeAction({
        param($action, $id)
        if ($action -eq 'search') { Set-SearchMode $true; $filter.SelectAll() }
        else { Send-Action $action $id }
    })
    $form.Add_VisibleChanged({ if (-not $form.Visible) { if ($menu) { $menu.Close() }; if ($keyFilter) { $keyFilter.ReleaseAll() }; if ($tip) { $tip.Cancel() } } })
    $form.Add_Deactivate({ if ($keyFilter) { $keyFilter.ReleaseAll() }; if ($tip) { $tip.Cancel() }; if ($script:searching -and -not $menu.Visible) { Set-SearchMode $false $false } })
    $counter.Add_Click({ $tip.Cancel(); Send-Action 'locate' })
    $counter.Add_MouseMove({ param($sender,$eventArgs) if ($menu.Visible) { $tip.Cancel(); return }; if ($counter.Enabled) { $tip.Schedule([PlaylistStyle]::Locate,$counter,$eventArgs.Location,$true) } })
    $counter.Add_MouseLeave({ $tip.Cancel() })
    $searchButton.Add_MouseMove({ param($sender,$eventArgs) if ($menu.Visible) { $tip.Cancel(); return }; $tip.Schedule($searchButton.AccessibleName,$searchButton,$eventArgs.Location,$true) })
    $searchButton.Add_MouseLeave({ $tip.Cancel() })
    $form.Add_LocationChanged({ if ($tip) { $tip.Cancel() } })
    $form.Add_Resize({ if ($tip) { $tip.Cancel() } })
    $list.add_ViewportInput({ if ($tip) { $tip.Cancel() } })
    $list.Add_MouseDown({ $tip.Cancel() })
    $list.Add_KeyDown({ $tip.Cancel() })
    $list.Add_DrawColumnHeader({ param($sender, $eventArgs) $eventArgs.DrawDefault = $true })
    $list.Add_DrawSubItem({
        param($sender, $eventArgs)
        $selected = $eventArgs.Item.Selected
        $current = $eventArgs.Item.Tag.index -eq $script:playlistPosition
        $bg = [PlaylistStyle]::RowBackground($current, $selected, ($eventArgs.Item.Tag.id -eq $script:hoverId))
        $fg = if ($eventArgs.ColumnIndex -eq 0) { [PlaylistStyle]::Number } elseif ($current) { [PlaylistStyle]::Accent } else { $form.ForeColor }
        $font = if ($eventArgs.ColumnIndex -eq 0) { $numberFont } elseif ($current) { $currentFont } else { $mainFont }
        $scale = $eventArgs.Graphics.DpiX / 96.0
        $brush = New-Object Drawing.SolidBrush($bg)
        try { $eventArgs.Graphics.FillRectangle($brush, $eventArgs.Bounds) } finally { $brush.Dispose() }
        if ($current -and $eventArgs.ColumnIndex -eq 0) {
            $bar = New-Object Drawing.SolidBrush([PlaylistStyle]::Accent)
            try { $eventArgs.Graphics.FillRectangle($bar, $eventArgs.Bounds.Left, [single]($eventArgs.Bounds.Top + 8*$scale), [single](3*$scale), [single][Math]::Max(1, $eventArgs.Bounds.Height - 16*$scale)) } finally { $bar.Dispose() }
        }
        $textBounds = $eventArgs.Bounds
        if ($eventArgs.ColumnIndex -eq 0) { $textBounds.X += [int](12*$scale); $textBounds.Width = [int](24*$scale) }
        else { $textBounds.Width = [Math]::Max(1,$textBounds.Width-[int](12*$scale)) }
        [Windows.Forms.TextRenderer]::DrawText($eventArgs.Graphics, $eventArgs.SubItem.Text, $font,
            $textBounds, $fg, ([Windows.Forms.TextFormatFlags]::Left -bor [Windows.Forms.TextFormatFlags]::VerticalCenter -bor [Windows.Forms.TextFormatFlags]::EndEllipsis -bor [Windows.Forms.TextFormatFlags]::NoPrefix -bor [Windows.Forms.TextFormatFlags]::NoPadding))
        # Selection is a thin blue outline, independent from the current fill.
        # Keyboard navigation strengthens the outline; mouse focus does not.
        if ($eventArgs.ColumnIndex -eq 1 -and ($selected -or ($list.Focused -and $list.KeyboardFocusCue -and $eventArgs.Item.Focused))) {
            $focused = $list.Focused -and $list.KeyboardFocusCue -and $eventArgs.Item.Focused
            $weight = if ($focused) { 2 } else { 1 }
            $pen = New-Object Drawing.Pen([PlaylistStyle]::Accent, [single][Math]::Max(1, $scale*$weight))
            $bounds = $eventArgs.Item.Bounds
            $inset = [int][Math]::Ceiling($scale*$weight/2)
            try { $eventArgs.Graphics.DrawRectangle($pen, $bounds.Left+$inset, $bounds.Top+$inset,
                [Math]::Max(1, [Math]::Min($bounds.Width, $list.ClientSize.Width)-2*$inset-1), [Math]::Max(1,$bounds.Height-2*$inset-1)) }
            finally { $pen.Dispose() }
        }
        if ($eventArgs.Item.Tag.id -eq $script:dropTargetId) {
            # Native InsertionMark is unreliable in Details view; draw the same cue.
            $pen = New-Object Drawing.Pen([PlaylistStyle]::Accent, [single](2*$scale))
            $y = if ($script:dropAfter) { $eventArgs.Bounds.Bottom - 1 } else { $eventArgs.Bounds.Top }
            try { $eventArgs.Graphics.DrawLine($pen, $eventArgs.Bounds.Left, $y, $eventArgs.Bounds.Right, $y) }
            finally { $pen.Dispose() }
        }
    })
    $filter.Add_TextChanged({ Render-Queue })
    $form.Add_KeyDown({
        param($sender, $eventArgs)
        if ($menu -and $menu.Visible) { return }
        if ($eventArgs.Control -and -not $eventArgs.Alt -and -not $eventArgs.Shift -and $eventArgs.KeyCode -eq 'F') {
            Set-SearchMode $true; $filter.SelectAll(); $eventArgs.SuppressKeyPress = $true
        } elseif ($script:searching -and -not $eventArgs.Control -and -not $eventArgs.Alt -and -not $eventArgs.Shift -and $eventArgs.KeyCode -eq 'Escape') {
            Set-SearchMode $false; $eventArgs.SuppressKeyPress = $true
        }
    })
    $list.Add_KeyDown({
        param($sender, $eventArgs)
        if ($menu -and $menu.Visible) { return }
        if (-not $eventArgs.Control -and -not $eventArgs.Alt -and -not $eventArgs.Shift -and $eventArgs.KeyCode -eq 'Delete' -and $list.SelectedItems.Count -eq 1) {
            Send-Action 'remove' ([string]$list.SelectedItems[0].Tag.id)
            $eventArgs.SuppressKeyPress = $true
        }
    })
    $list.Add_MouseMove({
        param($sender, $eventArgs)
        if ($menu.Visible) { $tip.Cancel(); return }
        $item = $list.GetItemAt($eventArgs.X, $eventArgs.Y)
        $id = if ($item) { [string]$item.Tag.id } else { '' }
        if ($script:hoverId -ne $id) {
            $oldHoverId = $script:hoverId; $script:hoverId = $id
            Invalidate-HoverRow $oldHoverId; Invalidate-HoverRow $id
        }
        if ($item -and -not $script:dragging) { $tip.Schedule((Tooltip-Text $item.Tag.entry),$list,$eventArgs.Location,$false) }
        else { $tip.Cancel() }
    })
    $list.Add_MouseLeave({ $oldHoverId = $script:hoverId; $script:hoverId = ''; Invalidate-HoverRow $oldHoverId; $tip.Cancel() })
    $list.Add_DoubleClick({
        if ($list.SelectedItems.Count -eq 1) { Send-Action 'play' ([string]$list.SelectedItems[0].Tag.id) }
    })
    $list.Add_ItemDrag({
        param($sender, $eventArgs)
        if ($script:rendering) { return }
        $script:dragging = $true
        try {
            $data = New-Object Windows.Forms.DataObject
            $data.SetData('mpvnet-playlist-entry', [string]$eventArgs.Item.Tag.id)
            [void]$list.DoDragDrop($data, [Windows.Forms.DragDropEffects]::Move)
        } finally { $script:dragging = $false; Clear-DropMarker; if ($script:renderDirty) { Render-Queue } }
    })
    $dragOver = {
        param($sender, $eventArgs)
        if ($eventArgs.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) {
            $eventArgs.Effect = [Windows.Forms.DragDropEffects]::Copy
            Clear-DropMarker
        } elseif ($eventArgs.Data.GetDataPresent('mpvnet-playlist-entry')) {
            $eventArgs.Effect = [Windows.Forms.DragDropEffects]::Move
            $point = $list.PointToClient((New-Object Drawing.Point($eventArgs.X, $eventArgs.Y)))
            $target = $list.GetItemAt($point.X, $point.Y)
            $after = $false
            if ($target) { $after = $point.Y -ge ($target.Bounds.Top + $target.Bounds.Height / 2) }
            elseif ($list.Items.Count) { $target = $list.Items[$list.Items.Count - 1]; $after = $true }
            if ($target) {
                $script:dropTargetId = [string]$target.Tag.id
                $script:dropAfter = $after
                $list.InsertionMark.Index = $target.Index
                $list.InsertionMark.AppearsAfterItem = $after
                $list.Invalidate()
            }
        } else { $eventArgs.Effect = [Windows.Forms.DragDropEffects]::None }
    }
    $drop = {
        param($sender, $eventArgs)
        Clear-DropMarker
        if ($eventArgs.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) {
            $files = @($eventArgs.Data.GetData([Windows.Forms.DataFormats]::FileDrop) | Where-Object {
                [IO.File]::Exists([string]$_) -or [IO.Directory]::Exists([string]$_)
            })
            if ($files.Count) { Send-Action 'append' (ConvertTo-Json -InputObject $files -Compress) }
        } elseif ($eventArgs.Data.GetDataPresent('mpvnet-playlist-entry') -and $list.Items.Count) {
            $point = $list.PointToClient((New-Object Drawing.Point($eventArgs.X, $eventArgs.Y)))
            $target = $list.GetItemAt($point.X, $point.Y)
            $side = 'before'
            if ($target) {
                if ($point.Y -ge ($target.Bounds.Top + $target.Bounds.Height / 2)) { $side = 'after' }
            } else { $target = $list.Items[$list.Items.Count - 1]; $side = 'after' }
            Send-Action 'move' ([string]$eventArgs.Data.GetData('mpvnet-playlist-entry')) ([string]$target.Tag.id) $side
        }
    }
    $list.Add_DragEnter($dragOver); $list.Add_DragOver($dragOver); $list.Add_DragDrop($drop)
    $form.Add_DragEnter($dragOver); $form.Add_DragOver($dragOver); $form.Add_DragDrop($drop)
    $list.Add_DragLeave({ Clear-DropMarker }); $form.Add_DragLeave({ Clear-DropMarker })
    $form.Add_FormClosing({
        param($sender, $eventArgs)
        if (-not $script:exiting) { $eventArgs.Cancel = $true; Hide-Window }
    })
    [void]$form.Handle
    $form.ApplyPresentationDpi()
    try { $dark = 1; [void][PlaylistNative]::DwmSetWindowAttribute($form.Handle, 20, [ref]$dark, 4) } catch {}
    try { $borderColor = -2; [void][PlaylistNative]::DwmSetWindowAttribute($form.Handle, 34, [ref]$borderColor, 4) } catch {}

    if ($ValidateOnly) {
        $foregroundBefore = [PlaylistNative]::GetForegroundWindow()
        $script:playlist = @(if ($null -ne $payload.playlist) { $payload.playlist })
        $script:playlistPosition = [int]$payload.position
        if ($payload.filter) { Set-SearchMode $true; $filter.Text = [string]$payload.filter }
        Render-Queue
        $form.PerformLayout()
        [void]$list.Handle
        [Windows.Forms.Application]::DoEvents()
        Render-Queue
        $rows = @($list.Items | ForEach-Object { @{id = $_.Tag.id; index = $_.Tag.index; number = $_.Text; label = $_.SubItems[1].Text; current = $_.Tag.index -eq $script:playlistPosition} })
        foreach ($item in $list.Items) { if ([string]$item.Tag.id -eq [string]$payload.selected_id) { $item.Selected = $true } }
        if ($payload.hover_id) { $script:hoverId = [string]$payload.hover_id }
        $normalCount = $counter.Text
        $beforeBounds = $list.Bounds
        $beforeFooterBounds = $footer.Bounds
        $initialSearch = $script:searching
        $initialFilter = $filter.Text
        Set-SearchMode $true
        $searchBounds = $list.Bounds
        $searchFooterBounds = $footer.Bounds
        $searchBoundsStable = $list.Bounds -eq $beforeBounds
        Set-SearchMode $false
        $restoredBounds = $list.Bounds
        $restoredFooterBounds = $footer.Bounds
        $restoredBoundsStable = $list.Bounds -eq $beforeBounds
        if ($initialSearch) { Set-SearchMode $true; $filter.Text = $initialFilter }
        $searchProbe = @{}
        if ($payload.search_probe) {
            Set-SearchMode $false
            $searchClick = $searchButton.GetType().GetMethod('OnClick', [Reflection.BindingFlags]'Instance,NonPublic')
            [void]$searchClick.Invoke($searchButton,@([EventArgs]::Empty))
            $searchProbe.opened = $script:searching -and $searchButton.Active -and $footer.Searching
            $searchProbe.controls_separate = $filter.Right -le $counter.Left -and $counter.Right -le $searchButton.Left
            $filter.Text = 'one'
            $searchProbe.filtered = $list.Items.Count
            [void]$searchClick.Invoke($searchButton,@([EventArgs]::Empty))
            $searchProbe.closed = -not $script:searching -and -not $searchButton.Active -and $filter.Text -eq ''
            $searchProbe.rows_restored = $list.Items.Count
        }
        $dismissProbe = @{}
        if ($payload.dismiss_probe) {
            Set-SearchMode $true
            $filter.Text = 'two'
            $dismissProbe.filtered = $list.Items.Count
            $message = [Windows.Forms.Message]::Create($filter.Handle,0x201,[IntPtr]::Zero,[IntPtr]::Zero)
            $dismissProbe.editor_allowed = -not $searchDismiss.PreFilterMessage([ref]$message)
            $dismissProbe.editor_keeps_search = $script:searching
            $message = [Windows.Forms.Message]::Create($list.Handle,0x201,[IntPtr]::Zero,[IntPtr]::Zero)
            $dismissProbe.first_consumed = $searchDismiss.PreFilterMessage([ref]$message)
            $dismissProbe.closed = -not $script:searching -and -not $filter.Visible -and $filter.Text -eq ''
            $dismissProbe.restored = $list.Items.Count
            $message.Msg = 0x202
            $dismissProbe.up_consumed = $searchDismiss.PreFilterMessage([ref]$message)
            $message.Msg = 0x203
            $dismissProbe.double_consumed = $searchDismiss.PreFilterMessage([ref]$message)
            $message.Msg = 0x202
            $dismissProbe.double_up_consumed = $searchDismiss.PreFilterMessage([ref]$message)
            $message.Msg = 0x201
            $dismissProbe.next_allowed = -not $searchDismiss.PreFilterMessage([ref]$message)
            Set-SearchMode $true
            $filter.Text = 'two'
            $message = [Windows.Forms.Message]::Create($searchButton.Handle,0x201,[IntPtr]::Zero,[IntPtr]::Zero)
            $dismissProbe.button_consumed = $searchDismiss.PreFilterMessage([ref]$message)
            $dismissProbe.button_closed = -not $script:searching
            foreach ($kind in @(0x204,0x207,0xA1)) {
                Set-SearchMode $true
                $filter.Text = 'two'
                $message = [Windows.Forms.Message]::Create($list.Handle,$kind,[IntPtr]::Zero,[IntPtr]::Zero)
                $dismissProbe["outside_$kind"] = $searchDismiss.PreFilterMessage([ref]$message) -and -not $script:searching
                $message.Msg = $kind + 1
                $dismissProbe["release_$kind"] = $searchDismiss.PreFilterMessage([ref]$message)
            }
            $otherWindow = New-Object Windows.Forms.Form
            try {
                Set-SearchMode $true
                $message = [Windows.Forms.Message]::Create($otherWindow.Handle,0x201,[IntPtr]::Zero,[IntPtr]::Zero)
                $dismissProbe.other_window_allowed = -not $searchDismiss.PreFilterMessage([ref]$message)
            } finally { $otherWindow.Dispose() }
            Set-SearchMode $true
            $filter.Text = 'two'
            $deactivate = $form.GetType().GetMethod('OnDeactivate', [Reflection.BindingFlags]'Instance,NonPublic')
            [void]$deactivate.Invoke($form,@([EventArgs]::Empty))
            $dismissProbe.deactivated = -not $script:searching -and $filter.Text -eq ''
        }
        if ($payload.click_counter -and $counter.Enabled) {
            $clickMethod = $counter.GetType().GetMethod('OnClick', [Reflection.BindingFlags]'Instance,NonPublic')
            [void]$clickMethod.Invoke($counter, @([EventArgs]::Empty))
        }
        if ($null -ne $payload.PSObject.Properties['locate_id']) { Locate-Entry ([string]$payload.locate_id) }
        $located = @($list.SelectedItems | ForEach-Object { [string]$_.Tag.id })
        $selectedVisible = $list.SelectedItems.Count -eq 1 -and $list.SelectedItems[0].Bounds.Top -ge 0 -and
            $list.SelectedItems[0].Bounds.Bottom -le $list.ClientSize.Height
        $parentRect = New-Object PlaylistNative+Rect
        $parentRect.Left = 120; $parentRect.Top = -180; $parentRect.Right = 700; $parentRect.Bottom = 900
        $areaRect = New-Object PlaylistNative+Rect
        $areaRect.Left = 0; $areaRect.Top = 0; $areaRect.Right = 1000; $areaRect.Bottom = 800
        $layout = [PlaylistFollower]::Layout($parentRect, $areaRect, 400, $false)
        $tipText = if ($script:playlist.Count) { Tooltip-Text $script:playlist[0] } else { '' }
        $tipSize = [PlaylistTip]::Measure($tipText, $mainFont, 96)
        $painted = $false
        $paintSamples = @{}
        $outlineSamples = @{}
        $counterSamples = @{}
        if ($payload.counter_hover) {
            $hoverMethod = $counter.GetType().GetMethod('OnMouseEnter',[Reflection.BindingFlags]'Instance,NonPublic')
            [void]$hoverMethod.Invoke($counter,@([EventArgs]::Empty))
            $counterCanvas = New-Object Drawing.Bitmap($counter.Width,$counter.Height)
            try {
                $counter.DrawToBitmap($counterCanvas,(New-Object Drawing.Rectangle(0,0,$counter.Width,$counter.Height)))
                $counterSamples.corner = $counterCanvas.GetPixel(0,0).ToArgb()
                $counterSamples.edge = $counterCanvas.GetPixel([int]($counter.Width/2),1).ToArgb()
                $counterSamples.background = $counter.BackColor.ToArgb()
            } finally { $counterCanvas.Dispose() }
        }
        if ($payload.paint_path) {
            $paintPath = [IO.Path]::GetFullPath([string]$payload.paint_path)
            if (-not $paintPath.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) { throw 'paint-path' }
            $canvas = New-Object Drawing.Bitmap($form.ClientSize.Width, $form.ClientSize.Height)
            try {
                $form.DrawToBitmap($canvas, (New-Object Drawing.Rectangle(0,0,$canvas.Width,$canvas.Height)))
                $list.DrawToBitmap($canvas, $list.Bounds)
                $scroll.DrawToBitmap($canvas, $scroll.Bounds)
                $footer.DrawToBitmap($canvas, $footer.Bounds)
                $counter.DrawToBitmap($canvas, (New-Object Drawing.Rectangle(($footer.Left + $counter.Left),($footer.Top + $counter.Top),$counter.Width,$counter.Height)))
                if ($script:searching) { $filter.DrawToBitmap($canvas,(New-Object Drawing.Rectangle(($footer.Left+$filter.Left),($footer.Top+$filter.Top),$filter.Width,$filter.Height))) }
                $caption.DrawToBitmap($canvas, $caption.Bounds)
                $captionLabel.DrawToBitmap($canvas, (New-Object Drawing.Rectangle(($caption.Left + $captionLabel.Left),($caption.Top + $captionLabel.Top),$captionLabel.Width,$captionLabel.Height)))
                $closeButton.DrawToBitmap($canvas, (New-Object Drawing.Rectangle(($caption.Left + $closeButton.Left),($caption.Top + $closeButton.Top),$closeButton.Width,$closeButton.Height)))
                $searchButton.DrawToBitmap($canvas, (New-Object Drawing.Rectangle(($footer.Left + $searchButton.Left),($footer.Top + $searchButton.Top),$searchButton.Width,$searchButton.Height)))
                foreach ($item in $list.Items) {
                    $point = New-Object Drawing.Point(($list.Left + $list.Width - 20), ($list.Top + $item.Bounds.Top + [int]($item.Bounds.Height / 2)))
                    if ($point.Y -ge $list.Top -and $point.Y -lt $list.Bottom) {
                        $paintSamples[[string]$item.Tag.id] = $canvas.GetPixel($point.X,$point.Y).ToArgb()
                        $edgeY = $list.Top + $item.Bounds.Top + [int][Math]::Ceiling($canvas.HorizontalResolution/96.0/2)
                        $outlineSamples[[string]$item.Tag.id] = $canvas.GetPixel(($list.Left+$list.Columns[0].Width+10),$edgeY).ToArgb()
                    }
                }
                $canvas.Save($paintPath, [Drawing.Imaging.ImageFormat]::Png)
                $painted = $true
            } finally { $canvas.Dispose() }
        }
        $windowStyle = [PlaylistNative]::GetWindowLongPtr($form.Handle,-16).ToInt64()
        $closeHidden = $null
        if ($payload.click_close) {
            $closeClick = $closeButton.GetType().GetMethod('OnClick', [Reflection.BindingFlags]'Instance,NonPublic')
            [void]$closeClick.Invoke($closeButton, @([EventArgs]::Empty))
            $closeHidden = -not $script:desiredVisible -and -not $form.Visible -and -not $form.IsDisposed
        }
        $menuProbe = $null
        if ($payload.menu_probe) {
            Update-ContextMenuHints $payload.menu_probe.shortcuts
            $menu.PrepareTarget([string]$payload.menu_probe.id)
            $menuItems = @{}
            $pendingItems = New-Object 'Collections.Generic.Queue[object]'
            foreach ($item in $menu.Items) { $pendingItems.Enqueue($item) }
            while ($pendingItems.Count) {
                $item = $pendingItems.Dequeue()
                if ($item -is [Windows.Forms.ToolStripMenuItem]) {
                    if ($item.Name) { $menuItems[$item.Name] = @{enabled=$item.Enabled; available=$item.Available; hint=$item.ShortcutKeyDisplayString} }
                    foreach ($child in $item.DropDownItems) { $pendingItems.Enqueue($child) }
                }
            }
            if ($payload.menu_probe.action) { $menu.Execute([string]$payload.menu_probe.action) }
            $menuProbe = @{items=$menuItems; searching=$script:searching; visible=$menu.Visible; target_id=$menu.TargetId}
        }
        $outputWriter.WriteLine((@{ok = $true; rows = $rows; count = $normalCount; shown = $form.Visible;
            context_menu = $menuProbe;
            presentation = @{native_caption = ($windowStyle -band 0xC00000) -ne 0; sizing_frame = ($windowStyle -band 0x40000) -ne 0;
                title = $captionLabel.Text; close_name = $closeButton.AccessibleName; close_hides = $closeHidden;
                title_above_list = $caption.Bottom -le $list.Top; empty_text = $list.EmptyText; font = $form.Font.Name;
                row_backgrounds = $paintSamples; row_outlines = $outlineSamples; counter_hover = $counterSamples;
                current_bold = $currentFont.Bold; row_columns = $list.Columns.Count;
                caption_height = $caption.Height; client_width = $form.ClientSize.Width;
                caption_bounds = $caption.Bounds.ToString(); title_bounds = $captionLabel.Bounds.ToString(); close_bounds = $closeButton.Bounds.ToString();
                search_name = $searchButton.AccessibleName; search_not_overlapping = $counter.Right -le $searchButton.Left;
                search_in_footer = $searchButton.Parent -eq $footer; search_bounds = $searchButton.Bounds.ToString();
                search_field_width = $filter.Width; search_controls_separate = -not $script:searching -or ($filter.Right -le $counter.Left -and $counter.Right -le $searchButton.Left);
                search_toggle = $searchProbe; search_dismiss = $dismissProbe; counter_width = $counter.Width; footer_width = $footer.ClientSize.Width};
            footer_bounds_stable = $searchBoundsStable -and $restoredBoundsStable -and $beforeFooterBounds -eq $searchFooterBounds -and $beforeFooterBounds -eq $restoredFooterBounds;
            layout_bounds = @{normal = $beforeBounds.ToString(); search = $searchBounds.ToString(); restored = $restoredBounds.ToString();
                footer_normal = $beforeFooterBounds.ToString(); footer_search = $searchFooterBounds.ToString(); footer_restored = $restoredFooterBounds.ToString()};
            locate = @{selected_ids = $located; selected_visible = $selectedVisible; top_index = $list.TopIndex;
                focused_id = if ($list.FocusedItem) { [string]$list.FocusedItem.Tag.id } else { '' };
                searching = $script:searching; filter = $filter.Text; counter_enabled = $counter.Enabled;
                counter_name = $counter.AccessibleName; counter_hand = $counter.Cursor -eq [Windows.Forms.Cursors]::Hand;
                focus_preserved = [PlaylistNative]::GetForegroundWindow() -eq $foregroundBefore};
            actions = $script:validationActions.ToArray(); caption_empty = $form.Text -eq '';
            no_minmax = -not $form.MinimizeBox -and -not $form.MaximizeBox;
            layout_top = $layout.Top; layout_height = $layout.Bottom-$layout.Top; layout_right = $layout.Right;
            tooltip_width = $tipSize.Width; tooltip_height = $tipSize.Height; painted = $painted} | ConvertTo-Json -Compress -Depth 8))
        exit 0
    }
    $phase = 'ipc'
    $pipeName = [string]$payload.pipe
    if ($pipeName.StartsWith('\\.\pipe\')) { $pipeName = $pipeName.Substring(9) }
    if (-not $pipeName) { throw 'pipe' }
    $pipe = New-Object IO.Pipes.NamedPipeClientStream('.', $pipeName, [IO.Pipes.PipeDirection]::InOut, [IO.Pipes.PipeOptions]::Asynchronous)
    $pipe.Connect(10000)
    $reader = New-Object IO.StreamReader($pipe, $utf8)
    $writer = New-Object IO.StreamWriter($pipe, $utf8)
    $writer.AutoFlush = $true
    $readTask = $reader.ReadLineAsync()
    Send-Command @('observe_property', 1, 'playlist')
    Send-Command @('observe_property', 2, 'playlist-pos')
    Send-Command @('observe_property', 3, 'fullscreen')
    Send-Command @('observe_property', 4, 'user-data/mpvnet/playlist-window')
    Send-Command @('observe_property', 5, 'user-data/mpvnet/shortcuts')
    Send-Command @('enable_event', 'client-message')
    $phase = 'session'
    $context = New-Object Windows.Forms.ApplicationContext
    $script:lastParent = [IntPtr]::Zero
    $timer = New-Object Windows.Forms.Timer
    # Catch the initial IPC snapshot promptly, then retain the established idle
    # cadence. A stalled peer must not keep the faster startup poll indefinitely.
    $timer.Interval = 15
    $script:startupClock = [Diagnostics.Stopwatch]::StartNew()
    $script:lastLifeCheck = [Environment]::TickCount
    $follower = if ($NoShow) { $null } else { New-Object PlaylistFollower($form, [uint32]$payload.parent_pid) }
    $timer.Add_Tick({
        try {
            if ($parentProcess.HasExited) { Exit-Window; return }
            $updates = 0
            while ($readTask.IsCompleted -and $updates -lt 64) {
                if ($readTask.IsFaulted -or $null -eq $readTask.Result) {
                    if ($parentProcess.HasExited) { Exit-Window; return }
                    throw 'ipc-disconnected'
                }
                $playlistEvent = $readTask.Result | ConvertFrom-Json
                if ($playlistEvent.event -eq 'property-change') {
                    switch ($playlistEvent.name) {
                        'playlist' {
                            $script:playlist = @(if ($null -ne $playlistEvent.data) { $playlistEvent.data })
                            Render-Queue
                            $script:receivedPlaylist = $true
                        }
                        'playlist-pos' { $script:playlistPosition = [int]$playlistEvent.data; Render-Queue }
                        'fullscreen' { $script:fullscreen = [bool]$playlistEvent.data }
                        'user-data/mpvnet/shortcuts' {
                            Update-ContextMenuHints $playlistEvent.data
                            if ($null -ne $playlistEvent.data -and $playlistEvent.data.schema -eq 1 -and
                                $null -ne $playlistEvent.data.forward_keys -and $null -ne $playlistEvent.data.opening_keys) {
                                $keyFilter.UpdateBindings([string[]]@($playlistEvent.data.forward_keys), [string[]]@($playlistEvent.data.opening_keys))
                            }
                        }
                        'user-data/mpvnet/playlist-window' {
                            if ($playlistEvent.data.token -eq $payload.token) { $script:desiredVisible = [bool]$playlistEvent.data.visible }
                        }
                    }
                } elseif ($playlistEvent.event -eq 'client-message' -and $playlistEvent.args.Count -ge 3 -and
                    $playlistEvent.args[0] -eq 'mpvnet-playlist-locate' -and $playlistEvent.args[1] -eq $payload.token) {
                    Locate-Entry ([string]$playlistEvent.args[2])
                } elseif ($playlistEvent.event -eq 'client-message' -and $playlistEvent.args.Count -ge 2 -and
                    $playlistEvent.args[0] -eq 'mpvnet-playlist-close' -and $playlistEvent.args[1] -eq $payload.token) {
                    Exit-Window; return
                } elseif ($playlistEvent.event -eq 'shutdown') { Exit-Window; return }
                $script:readTask = $reader.ReadLineAsync()
                $updates++
            }
            if ($script:receivedPlaylist -and -not $script:sentReady) {
                $script:sentReady = $true
                Send-Command @('script-message-to', [string]$payload.script, 'helper-ready', [string]$payload.token, [string]$PID)
            }
            if ($script:startupClock.IsRunning -and ($script:sentReady -or $script:startupClock.ElapsedMilliseconds -ge 1000)) {
                $timer.Interval = 150
                $script:startupClock.Stop()
            }
            if ($NoShow) { return }
            $follower.UpdatePolicy($script:desiredVisible, $script:fullscreen)
            if ([Environment]::TickCount - $script:lastLifeCheck -ge 1000) {
                $script:lastLifeCheck = [Environment]::TickCount
                $parentProcess.Refresh()
                $follower.RefreshParent($parentProcess.MainWindowHandle)
            }
        } catch {
            $script:sessionFailed = $true
            $script:sessionErrorClass = $_.Exception.GetType().Name
            $script:sessionErrorLine = [int]$_.InvocationInfo.ScriptLineNumber
            Exit-Window
        }
    })
    $script:readTask = $readTask
    $timer.Start()
    [Windows.Forms.Application]::Run($context)
    if ($script:sessionFailed) { throw 'session' }
    $outputWriter.WriteLine('{"ok":true}')
} catch {
    $errorClass = if ($script:sessionErrorClass) { $script:sessionErrorClass } else { $_.Exception.GetType().Name }
    $errorLine = if ($script:sessionFailed) { [int]$script:sessionErrorLine } else { [int]$_.InvocationInfo.ScriptLineNumber }
    $outputWriter.WriteLine((@{ok = $false; phase = $phase; error_class = $errorClass; error_line = $errorLine;
        error_member = $script:sessionErrorMember; error_type = $script:sessionErrorType;
        error_parameter = $script:sessionErrorParameter; error_callers = @($script:sessionErrorCallers)} | ConvertTo-Json -Compress))
    exit 1
} finally {
    $script:exiting = $true
    if ($timer) { $timer.Stop(); $timer.Dispose() }
    if ($searchDismiss) { $searchDismiss.Dispose() }
    if ($menu) { $menu.Dispose() }
    if ($keyFilter) { $keyFilter.Dispose() }
    if ($follower) { $follower.Dispose() }
    if ($tip) { $tip.Dispose() }
    if ($scroll) { $scroll.Dispose() }
    if ($pipe) { $pipe.Dispose() }
    if ($form) { $form.Dispose() }
    if ($mainFont) { $mainFont.Dispose() }
    if ($currentFont) { $currentFont.Dispose() }
    if ($numberFont) { $numberFont.Dispose() }
    if ($captionFont) { $captionFont.Dispose() }
    if ($rowImages) { $rowImages.Dispose() }
    if ($rowBitmap) { $rowBitmap.Dispose() }
    if ($parentProcess) { $parentProcess.Dispose() }
    if ($context) { $context.Dispose() }
    $outputWriter.Dispose()
}
