param([Parameter(Mandatory=$true)][string]$SourcePath,[Parameter(Mandatory=$true)][string]$InputPath,[string]$RenderPath='')
$ErrorActionPreference='Stop'
$utf8=New-Object Text.UTF8Encoding($false)
$out=New-Object IO.StreamWriter([Console]::OpenStandardOutput(),$utf8);$out.AutoFlush=$true
$view=$null;$parent=$null
try {
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Web.Extensions
    $refs=@('System.Core','System.Xaml','System.Web.Extensions',[Windows.Window].Assembly.Location,
        [Windows.Media.Brushes].Assembly.Location,[Windows.Threading.Dispatcher].Assembly.Location)
    Add-Type -ReferencedAssemblies $refs -Path $SourcePath
    $json=New-Object Web.Script.Serialization.JavaScriptSerializer;$json.MaxJsonLength=4194304
    $inputData=$json.DeserializeObject([IO.File]::ReadAllText($InputPath,$utf8))
    $request=$inputData['request'];$media=$inputData['media']
    $actualParent=if($inputData.ContainsKey('fixture_parent_pid')){[int]$inputData['fixture_parent_pid']}else{[int]$request['parent_pid']}
    $parent=[Diagnostics.Process]::GetProcessById($actualParent)
    $view=New-Object MediaInfoView($request,$media,$parent,$true)
    if($inputData.ContainsKey('width')){$view.MinWidth=[double]$inputData['width'];$view.Width=[double]$inputData['width']}
    if($inputData.ContainsKey('height')){$view.MinHeight=[double]$inputData['height'];$view.Height=[double]$inputData['height']}
    function Visual-Children($Node) {
        $Node
        for($i=0;$i -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($Node);$i++) {
            Visual-Children ([Windows.Media.VisualTreeHelper]::GetChild($Node,$i))
        }
    }
    $snapshots=New-Object 'Collections.Generic.List[object]';[void]$view.Snapshot()
    foreach($step in $inputData['steps']) {
        if($step.ContainsKey('page')) {
            $label=if($step['page'] -eq 'details'){[string][char]0x8BE6+[char]0x60C5}else{[string][char]0x6982+[char]0x89C8}
            $button=@(Visual-Children $view.Content | Where-Object {$_ -is [Windows.Controls.Button] -and $_.Content -ceq $label})[0]
            $button.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
        } elseif($step.ContainsKey('query')) {
            $search=@(Visual-Children $view.Content | Where-Object {$_ -is [Windows.Controls.TextBox] -and [Windows.Automation.AutomationProperties]::GetAutomationId($_) -eq 'DetailsSearch'})[0]
            $search.Text=[string]$step['query']
        } elseif($step.ContainsKey('run')) {$view.Run();$view.Tick()}
        elseif($step.ContainsKey('loaded')) {$view.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.FrameworkElement]::LoadedEvent)))}
        $snapshots.Add($view.Snapshot())
    }
    $result=$view.Snapshot();$result['history']=$snapshots.ToArray()
    $readable=@(Visual-Children $view.Content | Where-Object {$_ -is [Windows.Controls.TextBox] -and $_.IsReadOnly})
    $result['reading_controls_unbordered']=@($readable | Where-Object {$_.BorderThickness -ne (New-Object Windows.Thickness(0))}).Count -eq 0
    $result['display_text']=(@(Visual-Children $view.Content | Where-Object {$_ -is [Windows.Controls.TextBlock]} | ForEach-Object {$_.Text}) -join "`n")
    if($RenderPath){
        $bitmap=New-Object Windows.Media.Imaging.RenderTargetBitmap([int]$view.Width,[int]$view.Height,96,96,[Windows.Media.PixelFormats]::Pbgra32)
        $bitmap.Render($view.Content);$encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder
        $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
        $stream=[IO.File]::Open($RenderPath,[IO.FileMode]::CreateNew)
        try{$encoder.Save($stream)}finally{$stream.Dispose()}
    }
    $view.Dispose();$result['disposed_handle_created']=$view.Snapshot()['handle_created']
    $out.WriteLine($json.Serialize($result))
} catch {
    $out.WriteLine((ConvertTo-Json -Compress @{ok=$false;error=$_.Exception.Message}))
    [Console]::Error.WriteLine($_.Exception.ToString());exit 1
} finally {if($view){$view.Dispose()};if($parent){$parent.Dispose()};$out.Dispose()}
