# ----------------------------------------------------------------------------- # A download is a job, and a job gets its own tab # # Part of Store-Gui.ps1. Not runnable on its own: the entry script dot-sources # this file so that everything shares one scope. # ----------------------------------------------------------------------------- 
# ---------------------------------------------------------------- jobs (a tab each)
function New-Job([string[]]$ScriptArgs, [string]$title, [string]$productId, $plan) {
    $script:JobSeq++
    $id = $script:JobSeq

    $content = [Windows.Markup.XamlReader]::Parse(@'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
      xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Margin="12,10">
  <Grid.RowDefinitions>
    <RowDefinition Height="Auto"/>
    <RowDefinition Height="Auto"/>
    <RowDefinition Height="*"/>
  </Grid.RowDefinitions>
  <Grid Grid.Row="0">
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="*"/>
      <ColumnDefinition Width="Auto"/>
    </Grid.ColumnDefinitions>
    <ProgressBar x:Name="bar" Grid.Column="0" Height="8" Minimum="0" Maximum="100" Value="0"/>
    <TextBlock x:Name="pct" Grid.Column="1" Text="0%" Margin="10,0,0,0"
               Foreground="#8A93A0" VerticalAlignment="Center" MinWidth="46"
               TextAlignment="Right"/>
  </Grid>
  <TextBlock x:Name="st" Grid.Row="1" Text="" Foreground="#7D8694"
             Margin="0,8,0,0" TextWrapping="Wrap"/>
  <TextBox x:Name="log" Grid.Row="2" Background="Transparent" BorderThickness="0"
           Foreground="#A9B2BF" FontFamily="Consolas" FontSize="11.5" IsReadOnly="True"
           VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
           TextWrapping="NoWrap" Margin="0,8,0,0"/>
</Grid>
'@)
    $bar = $content.FindName('bar')
    $pct = $content.FindName('pct')
    $st = $content.FindName('st')
    $lg = $content.FindName('log')
    # the fragment is parsed on its own, so it cannot see the window's resources
    $bar.Style = $window.Resources['Bar']

    $hdr = New-Object Windows.Controls.StackPanel
    $hdr.Orientation = 'Horizontal'
    $h = New-Object Windows.Controls.TextBlock
    $h.Text = $title
    $h.VerticalAlignment = 'Center'
    $h.MaxWidth = 220
    $h.TextTrimming = 'CharacterEllipsis'
    $x = New-Object Windows.Controls.Button
    $x.Content = '✕'
    $x.Width = 18
    $x.Height = 18
    $x.Margin = '9,0,0,0'
    $x.Padding = 0
    $x.FontSize = 10
    $x.Background = 'Transparent'
    $x.Foreground = Brush '8A93A0'
    $x.BorderThickness = 0
    $x.Cursor = 'Hand'
    [void]$hdr.Children.Add($h)
    [void]$hdr.Children.Add($x)

    $tab = New-Object Windows.Controls.TabItem
    $tab.Header = $hdr
    $tab.Content = $content

    $job = [pscustomobject]@{
        Id        = $id
        Title     = $title
        ProductId = $productId
        Args      = $ScriptArgs
        Plan      = $plan
        State     = 'queued'
        Proc      = $null
        LogFile   = Join-Path $script:Tmp "job$id.log"
        PfFile    = Join-Path $script:Tmp "job$id.json"
        LogPos    = [long]0
        Tab       = $tab
        Head      = $h
        Bar       = $bar
        Pct       = $pct
        Status    = $st
        Log       = $lg
    }
    $x.Tag = $job
    $x.Add_Click({ param($s, $e) Close-Job $s.Tag })
    $lg.FlowDirection = 'LeftToRight'

    [void]$tabJobs.Items.Add($tab)
    $tabJobs.SelectedItem = $tab
    $script:Jobs.Add($job)
    return $job
}

function Add-JobLog($job, [string]$line) {
    $job.Log.AppendText($line + "`r`n")
    $job.Log.ScrollToEnd()
}

function Set-JobState($job, [string]$state, [string]$text) {
    $job.State = $state
    $job.Status.Text = $text
    $job.Head.Text = ("{0}  [{1}]" -f $job.Title, (T $state))
}

function Start-JobRun($job) {
    Remove-Item -LiteralPath $job.LogFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $job.PfFile -Force -ErrorAction SilentlyContinue
    $job.LogPos = 0
    $job.Log.Clear()
    $job.Bar.Value = 0
    $job.Pct.Text = '0%'

    $line = (Quote-Args @($script:Exe)) + ' ' +
        (Quote-Args (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:Ps1) + $job.Args +
                @('-ProgressFile', $job.PfFile))) +
        ' > "' + $job.LogFile + '" 2>&1'
    $job.Proc = Start-NoWindow $line
    Set-JobState $job 'running' (T 'running')
    $script:Running = $job
    Set-StopButton
    $script:Timer.Start()
}

# the link is the bottleneck (measured: 4 parallel downloads are not faster than
# one), so the queue runs a single job at a time and the rest wait their turn
function Start-NextJob {
    if ($script:Running) { return }
    foreach ($j in $script:Jobs) {
        if ($j.State -eq 'queued') { Start-JobRun $j; return }
    }
    if (-not (Get-AnyRunning)) { $script:Timer.Stop() }
}

function Get-AnyRunning {
    foreach ($j in $script:Jobs) { if ($j.State -eq 'running') { return $true } }
    return $false
}

# Stop only means something while something is running, so the button follows the
# queue: it lights up the moment a job starts and greys out when the queue is empty.
# (It used to be hard-wired to IsEnabled="False" in the XAML and never switched on,
# which is why it could not be clicked at all.)
function Set-StopButton {
    if (-not $btnStop) { return }
    $on = $null -ne $script:Running
    if ($btnStop.IsEnabled -ne $on) { $btnStop.IsEnabled = $on }
}

function Close-Job($job) {
    if ($job.State -eq 'running' -and $job.Proc -and -not $job.Proc.HasExited) {
        & taskkill.exe /PID $job.Proc.Id /T /F 2>&1 | Out-Null
    }
    if ($script:Running -eq $job) { $script:Running = $null }
    Set-StopButton
    [void]$tabJobs.Items.Remove($job.Tab)
    [void]$script:Jobs.Remove($job)
    Start-NextJob
}

function Stop-JobRun($job) {
    if (-not $job -or $job.State -ne 'running') { return }
    if ($job.Proc -and -not $job.Proc.HasExited) { & taskkill.exe /PID $job.Proc.Id /T /F 2>&1 | Out-Null }
    Add-JobLog $job ''
    Add-JobLog $job (T 'stopNote')
    Add-JobLog $job (T 'stopNote2')
    Set-JobState $job 'stopped' (T 'stopped')
    # nothing is running any more, so let the queue move on straight away
    if ($script:Running -eq $job) { $script:Running = $null }
    Set-StopButton
}

