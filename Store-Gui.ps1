<#
.SYNOPSIS
    Store-Offline GUI - search the Microsoft Store, then download any app offline.

.DESCRIPTION
    A thin front-end over Store-Offline.ps1. Each download runs as its own child
    process in its own tab, so several apps can be queued up and left to run.

      * Search      -Search <text>   -Json
      * Preview     -ProductId ... -List -Json
      * Download    -ProductId ... -Download -ProgressFile <job>.json

    The child writes its console output to a log file and its progress to a JSON
    file; the window polls both. Nothing here talks to the network itself.

    Usage:  idm.cmd            (or: powershell -File Store-Gui.ps1)
#>

$ErrorActionPreference = 'Stop'

# The window needs WPF, which a Server Core installation does not have. Say so
# plainly instead of dying with a type-not-found error, and let idm.cmd fall back
# to the console version.
if ($PSVersionTable.PSVersion.Major -lt 3) {
    [Console]::Error.WriteLine('Store-Gui.ps1 needs PowerShell 3.0 or newer.')
    exit 2
}
try {
    Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
    Add-Type -AssemblyName PresentationCore -ErrorAction Stop
    Add-Type -AssemblyName WindowsBase -ErrorAction Stop
} catch {
    [Console]::Error.WriteLine('This Windows has no WPF, so the window cannot open.')
    [Console]::Error.WriteLine('Use idm-console.cmd instead - downloading works the same.')
    exit 3
}
# needed by Set-Icon, which fetches the app logo from Microsoft's image host
try { Add-Type -AssemblyName System.Net.Http -ErrorAction Stop } catch { }

Set-StrictMode -Version Latest

# ---------------------------------------------------------------- state
$script:Root     = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $script:Root) { $script:Root = (Get-Location).Path }

# ---------------------------------------------------------------- the rest
# The window markup, the helpers, the job model and the buttons all live in the
# lib folder next to this file, dot-sourced below so that they share this
# script's scope. Only the entry point - this file - decides what runs when.
$libDir = Join-Path $script:Root 'lib'
foreach ($part in @('gui-state.ps1', 'gui-xaml.ps1', 'gui-core.ps1', 'gui-jobs.ps1', 'gui-actions.ps1', 'gui-poll.ps1')) {
    $libFile = Join-Path $libDir $part
    if (-not (Test-Path -LiteralPath $libFile)) {
        [Console]::Error.WriteLine("Store-Gui is incomplete: lib\$part is missing.")
        [Console]::Error.WriteLine("The lib folder belongs next to $script:Root")
        exit 4
    }
    . $libFile
}

# ---------------------------------------------------------------- wire it up
$window = [Windows.Markup.XamlReader]::Parse($xaml)

foreach ($n in @('txtInput', 'btnSearch', 'lstResults', 'lblTitle', 'lblPublisher', 'lblVersion',
        'lblSize', 'lblDeps', 'lblDest', 'lblHint', 'cmbArch', 'chkExtract', 'chkDeps', 'chkKit',
        'chkEncrypted',
        'btnPreview', 'btnDownload', 'btnInstall', 'btnAll', 'btnStop', 'btnCheck', 'btnClear',
        'tabJobs', 'imgIcon', 'btnLang', 'lblAppTitle', 'lblAppSub',
        'lblResultsHead', 'lblAppHead', 'lblVersionCap', 'lblSizeCap', 'lblDepsCap',
        'lblDestCap', 'lblArchCap',
        'rootGrid', 'gridMain', 'gridOpts', 'gridBtns', 'brdJobs')) {
    Set-Variable -Name $n -Value $window.FindName($n) -Scope Script
}

# default the architecture picker to this machine
$a = $env:PROCESSOR_ARCHITEW6432
if (-not $a) { $a = $env:PROCESSOR_ARCHITECTURE }
switch -Regex ([string]$a) {
    '^ARM64$' { $cmbArch.SelectedIndex = 2 }
    '^X86$'   { $cmbArch.SelectedIndex = 1 }
    default   { $cmbArch.SelectedIndex = 0 }
}

# the window can be opened from more than one place (E:\idm, the unpacked one-file
# copy, ...), so the title says exactly which copy is running
$window.Title = "Store-Offline  -  $script:Root"

$script:Timer = New-Object Windows.Threading.DispatcherTimer
$script:Timer.Interval = [TimeSpan]::FromMilliseconds(350)
$script:Timer.Add_Tick({ On-Tick })

$btnSearch.Add_Click({ Do-Search })
$btnPreview.Add_Click({ Do-Preview })
$btnDownload.Add_Click({ Do-Download })
$btnInstall.Add_Click({ Do-Install })
$btnAll.Add_Click({ Do-All })
$btnStop.Add_Click({ Do-Stop })
$btnCheck.Add_Click({ Do-CheckUpdates })
$btnClear.Add_Click({ Do-Clear })
$btnLang.Add_Click({ if ($script:Lang -eq 'ar') { Set-Lang 'en' } else { Set-Lang 'ar' } })

$txtInput.Add_KeyDown({
        param($s, $e)
        if ($e.Key -eq 'Return') { Do-Search }
    })

$lstResults.Add_SelectionChanged({
        $sel = $lstResults.SelectedItem
        if ($sel -and $sel.Tag) {
            $txtInput.Text = [string]$sel.Tag
            Do-Preview
        }
    })

Set-Lang 'ar'
Set-Layout 'idle'

$window.Add_Loaded({ $txtInput.Focus() | Out-Null })

[void]$window.ShowDialog()
