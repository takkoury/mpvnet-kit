param([Parameter(Mandatory=$true)][string]$SourcePath)
$ErrorActionPreference='Stop'
$source=[IO.File]::ReadAllText($SourcePath)
$code=[regex]::Match($source,"(?s)Add-Type -TypeDefinition \(?@'\r?\n(.*?)\r?\n'@").Groups[1].Value
if (-not $code) {throw 'missing production C#'}
$code += "`n" + [IO.File]::ReadAllText((Join-Path (Split-Path -Parent $SourcePath) 'shortcut-key-names.cs'))
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
Add-Type -TypeDefinition $code -ReferencedAssemblies System.Windows.Forms,System.Drawing
$form=New-Object PlaylistForm
$filter=New-Object PlaylistKeys($form)
try {
    $flags=[Reflection.BindingFlags]'Instance,NonPublic'
    $allowedField=$filter.GetType().GetField('allowed',$flags)
    $openingField=$filter.GetType().GetField('opening',$flags)
    $heldField=$filter.GetType().GetField('held',$flags)
    $held=$heldField.GetValue($filter);$held.Add(75,'k')
    $filter.UpdateBindings([string[]]@('k','F6','Ctrl+<'),[string[]]@('F6'))
    if ($held.Count -ne 0) {throw 'old held key not released'}
    $allowed=$allowedField.GetValue($filter);$opening=$openingField.GetValue($filter)
    if ($allowed.Contains('Space') -or -not $allowed.Contains('k') -or -not $opening.Contains('F6')) {throw 'new map not applied'}
    $held.Add(75,'k');$filter.UpdateBindings([string[]]@('Ctrl+<','F6','k'),[string[]]@('F6'))
    if ($held.Count -ne 1) {throw 'unchanged map interrupted held key'}
    $filter.UpdateBindings([string[]]@(),[string[]]@())
    if ($allowed.Count -ne 0 -or $opening.Count -ne 0 -or $held.Count -ne 0) {throw 'empty map did not disable forwarding'}
    $cases=@(@(75,0,'k'),@(75,131072,'Ctrl+k'),@(77,65536,'M'),@(77,196608,'Ctrl+Shift+m'),@(117,0,'F6'),@(188,196608,'Ctrl+<'),@(9,0,'Tab'))
    foreach($c in $cases) { if ([PlaylistKeys]::Canonical($c[0],[Windows.Forms.Keys]$c[1]) -cne $c[2]) {throw 'canonical key mismatch'} }
    foreach($vk in @(27,38,40,46)) {if ($null -ne [PlaylistKeys]::Canonical($vk,[Windows.Forms.Keys]0)) {throw 'local key stolen'}}
    '{"ok":true,"map_replace":true,"unchanged_hold":true,"empty_map":true,"key_cases":7,"local_keys_preserved":true}'
} finally { $filter.Dispose();$form.Dispose() }
