param([Parameter(Mandatory=$true)][string]$SourceDirectory,
      [Parameter(Mandatory=$true)][string]$PaintPath)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
Add-Type -AssemblyName System.Windows.Forms,System.Drawing,System.Web.Extensions
$inputs=@('playlist-window-controls.cs','shortcut-key-names.cs','playlist-context-menu.cs') | ForEach-Object { Join-Path $SourceDirectory $_ }
$inputs += Join-Path $PSScriptRoot 'playlist_context_menu_probe.cs'
Add-Type -Path $inputs -ReferencedAssemblies System.Windows.Forms,System.Drawing,System.Web.Extensions,System.Core
$data=[PlaylistContextMenuProbe]::Run($PaintPath)
$serializer=New-Object Web.Script.Serialization.JavaScriptSerializer
$serializer.Serialize($data)
