# ----------------------------------------------------------------------------- # What the buttons do # # Part of Store-Gui.ps1. Not runnable on its own: the entry script dot-sources # this file so that everything shares one scope. # ----------------------------------------------------------------------------- 
# ---------------------------------------------------------------- actions
function Do-Search {
    $q = $txtInput.Text.Trim()
    if (-not $q) { return }
    # a product id is not a search term - go straight to the app it names
    if (Test-ProductId $q) { Do-Preview; return }
    Set-Layout 'work'
    $lstResults.Items.Clear()
    $script:Plan = $null
    $lblHint.Text = ((T 'searching') -f $q)
    $raw = Invoke-Capture @('-Search', $q, '-Json')
    $items = @()
    if ($raw -and $raw.Trim()) {
        try {
            # assign first: in PowerShell 5.1, @(ConvertFrom-Json ...) wraps the whole
            # result array into a single element instead of unrolling it
            $parsed = ConvertFrom-Json -InputObject $raw
            $items = @($parsed)
        } catch { }
    }
    if (-not $items.Count) {
        $lblHint.Text = T 'noResults'
        return
    }
    foreach ($it in $items) {
        $sp = New-Object Windows.Controls.StackPanel
        $t1 = New-Object Windows.Controls.TextBlock
        $t1.Text = [string]$it.title
        $t1.Foreground = $script:BrText
        $t1.TextTrimming = 'CharacterEllipsis'
        $t2 = New-Object Windows.Controls.TextBlock
        $t2.Text = ("{0}   {1}" -f $it.id, $it.publisher)
        $t2.Foreground = $script:BrId
        $t2.FontSize = 11
        $t2.TextTrimming = 'CharacterEllipsis'
        [void]$sp.Children.Add($t1)
        [void]$sp.Children.Add($t2)
        $li = New-Object Windows.Controls.ListBoxItem
        $li.Content = $sp
        $li.Tag = [string]$it.id
        $li.Style = $window.Resources['Row']
        [void]$lstResults.Items.Add($li)
    }
    $lblHint.Text = ((T 'pickOne') -f $items.Count) + '  ' + (T 'pickHint')
}

function Do-Preview {
    $t = Get-Target
    if (-not $t) { Do-Search; return }
    Set-Layout 'work'
    $lblHint.Text = T 'resolving'
    $raw = Invoke-Capture (@($t) + (Get-CommonArgs) + @('-List', '-Json'))
    if (-not $raw -or -not $raw.Trim()) {
        $lblHint.Text = T 'cantResolve'
        return
    }
    try { $p = ConvertFrom-Json -InputObject $raw }
    catch { $lblHint.Text = T 'cantResolve'; return }

    $script:Plan = $p
    $lblTitle.Text = [string]$p.title
    $lblPublisher.Text = [string]$p.publisher
    $kind = [string]$p.kind
    if (-not $kind) { $kind = 'packaged' }
    $verTxt = [string]$p.version
    if (-not $verTxt) { $verTxt = '-' }
    $lblVersion.Text = "$verTxt   ($(T $(if ($kind -eq 'win32') { 'win32' } else { 'msix' })))"
    $lblSize.Text = Format-Size ([long]$p.total)
    $deps = @($p.deps)
    if ($deps.Count) {
        $lblDeps.Text = (($deps | ForEach-Object { ([string]$_.name -split '_')[0] }) -join ', ')
    } else {
        $lblDeps.Text = 'none'
    }
    $lblDest.Text = [string]$p.dest
    Set-Icon ([string]$p.icon)
    $script:CanExtract = ($kind -ne 'win32')
    $chkExtract.IsEnabled = $script:CanExtract
    if ($kind -eq 'win32') {
        $lblHint.Text = T 'hintWin32'
    } elseif ($p.extract) {
        $lblHint.Text = ((T 'hintExtract') -f $p.arch)
    } else {
        $lblHint.Text = ((T 'hintSingle') -f $p.arch)
    }
}

function Queue-Run([string[]]$Extra, [string]$label) {
    $t = Get-Target
    if (-not $t) { Do-Search; return }
    if (-not $script:Plan) { Do-Preview }
    if (-not $script:Plan) { return }
    Set-Layout 'work'
    $title = [string]$script:Plan.title
    if (-not $title) { $title = $label }
    $argList = @($t) + (Get-CommonArgs) + $Extra
    $job = New-Job $argList $title ([string]$script:Plan.productId) $script:Plan
    Add-JobLog $job ("{0} {1} {2}" -f (T 'downloadTab'), $job.Id, $title)
    Add-JobLog $job ("> $label")
    Add-JobLog $job ''
    Start-NextJob
}

function Do-Download { Queue-Run @('-Download') (T 'btnDownload') }
function Do-All { Queue-Run @('-All') (T 'btnAll') }

# Unlike the download buttons this one needs no app selected: it walks every
# folder under StoreApps\ and reports which ones the Store has moved past.
function Do-CheckUpdates {
    Set-Layout 'work'
    $a = @('-Check')
    if ($chkKit.IsChecked) { $a += '-Kit' }
    $job = New-Job $a (T 'btnCheck') '' $null
    Add-JobLog $job ("> $(T 'btnCheck')")
    Add-JobLog $job ''
    Start-NextJob
}

function Do-Install {
    $dest = $null
    if ($script:Plan) { $dest = [string]$script:Plan.dest }
    if (-not $dest -or -not (Test-Path -LiteralPath $dest)) {
        $lblHint.Text = T 'needDownload'
        return
    }
    Set-Layout 'work'
    $job = New-Job (@('-Install', '-Path', $dest) + (Get-CommonArgs)) ([string]$script:Plan.title) ([string]$script:Plan.productId) $script:Plan
    Add-JobLog $job ("> $(T 'btnInstall')")
    Start-NextJob
}

function Do-Stop {
    $sel = $tabJobs.SelectedItem
    $job = $null
    if ($sel -and $sel.Header -and $sel.Header.Children) { $job = $sel.Header.Children[1].Tag }
    if (-not $job -or $job.State -ne 'running') { $job = $script:Running }
    Stop-JobRun $job
    Start-NextJob
}

function Do-Clear {
    foreach ($j in @($script:Jobs)) {
        if ($j.State -ne 'running' -and $j.State -ne 'queued') { Close-Job $j }
    }
}

