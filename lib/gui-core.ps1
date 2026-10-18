# ----------------------------------------------------------------------------- # Small helpers, and the two languages # # Part of Store-Gui.ps1. Not runnable on its own: the entry script dot-sources # this file so that everything shares one scope. # ----------------------------------------------------------------------------- 
# ---------------------------------------------------------------- helpers
function Brush([string]$hex) {
    $c = [Windows.Media.Color]::FromRgb(
        [Convert]::ToInt32($hex.Substring(0, 2), 16),
        [Convert]::ToInt32($hex.Substring(2, 2), 16),
        [Convert]::ToInt32($hex.Substring(4, 2), 16))
    New-Object Windows.Media.SolidColorBrush $c
}
$script:BrText  = Brush 'E6E9EE'
$script:BrMuted = Brush '7D8694'
$script:BrId    = Brush '8A93A0'

function Format-Size([long]$b) {
    if ($b -ge 1GB) { return ('{0:N2} GB' -f ($b / 1GB)) }
    return ('{0:N1} MB' -f ($b / 1MB))
}

function Format-Eta([int]$sec) {
    if ($sec -le 0) { return '' }
    # [int] casts ROUND in PowerShell (unlike C#'s truncation), so 3492/3600 = 0.97
    # used to become "1h". Floor explicitly.
    $h = [Math]::Floor($sec / 3600)
    $m = [Math]::Floor(($sec % 3600) / 60)
    $s = $sec % 60
    if ($h -gt 0) { return ('{0}h {1}m' -f $h, $m) }
    if ($m -gt 0) { return ('{0}m {1}s' -f $m, $s) }
    return ('{0}s' -f $s)
}

# Read a file another process is still writing to. Store-Offline.ps1 pins its
# output to UTF-8 whenever it is driven by this window, so these are all UTF-8.
function Read-Shared([string]$p, [Text.Encoding]$Enc) {
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    if (-not $Enc) { $Enc = New-Object Text.UTF8Encoding($false) }
    try {
        $fs = [IO.File]::Open($p, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $sr = New-Object IO.StreamReader($fs, $Enc)
            return $sr.ReadToEnd()
        } finally { $fs.Dispose() }
    } catch { return $null }
}

function Quote-Args([string[]]$a) {
    ($a | ForEach-Object {
            if ($_ -match '[\s"&^|<>]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
        }) -join ' '
}

# Run a command line through cmd the way this window always has, but with no
# console at all. -WindowStyle Hidden is not enough on Windows 11: Windows
# Terminal hosts the console and shows the black box anyway, so every search,
# preview and download flashed one. CreateNoWindow means none is ever made.
function Start-NoWindow([string]$Line, [switch]$Wait) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = 'cmd.exe'
    # cmd strips the first and the last quote of a /c line that starts with one,
    # which would eat the quotes of the redirection, so the line gets its own pair
    if ($Line.StartsWith('"')) { $psi.Arguments = '/c "' + $Line + '"' }
    else { $psi.Arguments = '/c ' + $Line }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi)
    if ($Wait) {
        $p.WaitForExit()
        $code = $p.ExitCode
        $p.Dispose()
        return $code
    }
    return $p
}

# short, blocking call used for search and preview
function Invoke-Capture([string[]]$ScriptArgs) {
    Remove-Item -LiteralPath $script:CapFile -Force -ErrorAction SilentlyContinue
    $line = (Quote-Args @($script:Exe)) + ' ' +
        (Quote-Args (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:Ps1) + $ScriptArgs)) +
        ' > "' + $script:CapFile + '" 2>nul'
    [void](Start-NoWindow $line -Wait)
    return (Read-Shared $script:CapFile)
}

function Get-Arch { return [string]$cmbArch.SelectedItem.Content }

function Get-CommonArgs {
    $a = @('-Arch', (Get-Arch))
    if ($chkExtract.IsChecked -and $script:CanExtract) { $a += '-Extract' }
    if (-not $chkDeps.IsChecked) { $a += '-NoDeps' }
    if ($chkKit.IsChecked) { $a += '-Kit' }
    # the encrypted builds are the real current ones, but they only install on a
    # machine with the Store licence, so they are opt-in
    if ($chkEncrypted.IsChecked) { $a += '-Encrypted' }
    return $a
}

# A Store product id, in either of the two shapes Microsoft uses:
#   9NKSQGP7F2NH     a packaged (MSIX/AppX) app          - 12 chars, starts with 9
#   XP9KN75RRB9NHS   an unpackaged Win32 app (.exe/.msi) - starts with XP
function Test-ProductId([string]$q) {
    if ($q -match '^9[0-9A-Z]{11}$') { return $true }
    if ($q -match '^XP[0-9A-Z]{8,}$') { return $true }
    return $false
}

# -ProductId / -Url when we have a concrete target, otherwise $null
function Get-Target {
    $q = $txtInput.Text.Trim()
    if ($q -match '^https?://') { return @('-Url', $q) }
    if (Test-ProductId $q) { return @('-ProductId', $q) }
    $sel = $lstResults.SelectedItem
    if ($sel -and $sel.Tag) { return @('-ProductId', [string]$sel.Tag) }
    return $null
}

function Set-Icon([string]$url) {
    $imgIcon.Source = $null
    if (-not $url) { return }
    # the icon is cached on first sight (file name = SHA-1 of its url), so the next
    # preview of the same app is instant - and still there when the network is off
    $cached = $null
    try {
        $sha = [System.Security.Cryptography.SHA1]::Create()
        $name = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($url))) -replace '-', '').ToLower() + '.png'
        $sha.Dispose()
        $cached = Join-Path $script:IconDir $name
    } catch { $cached = $null }
    # download synchronously with a short timeout: a plain BitmapImage UriSource loads
    # in the background and would leave the box empty until the bytes arrive
    $bytes = $null
    try {
        $c = [System.Net.Http.HttpClient]::new()
        $c.Timeout = [TimeSpan]::FromSeconds(15)
        $bytes = $c.GetByteArrayAsync($url).GetAwaiter().GetResult()
        $c.Dispose()
    } catch {
        try {
            $wc = New-Object System.Net.WebClient
            $bytes = $wc.DownloadData($url)
            $wc.Dispose()
        } catch { $bytes = $null }
    }
    if ((-not $bytes -or $bytes.Length -lt 100) -and $cached -and (Test-Path -LiteralPath $cached)) {
        $bytes = [IO.File]::ReadAllBytes($cached)
    }
    if (-not $bytes -or $bytes.Length -lt 100) { return }
    if ($cached) {
        try { [IO.File]::WriteAllBytes($cached, $bytes) } catch { }
    }
    try {
        $ms = New-Object IO.MemoryStream -ArgumentList (, $bytes)
        $bmp = New-Object Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit()
        $bmp.StreamSource = $ms
        $bmp.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bmp.EndInit()
        $bmp.Freeze()
        $imgIcon.Source = $bmp
        $ms.Dispose()
    } catch { $imgIcon.Source = $null }
}

# ---------------------------------------------------------------- languages
$script:S = @{
    en = @{
        sub          = 'Download any Microsoft Store app together with the frameworks it needs. x64 when it exists, x86 when it does not. Installing is optional.'
        lang         = 'العربية'
        search       = 'Search'
        results      = 'RESULTS'
        app          = 'APP'
        nothing      = 'Nothing selected'
        version      = 'Version'
        download     = 'Download'
        frameworks   = 'Frameworks'
        folder       = 'Folder'
        arch         = 'Architecture'
        chkExtract   = 'This architecture only (skip the other slices of the bundle)'
        chkDeps      = 'Include frameworks'
        chkKit       = 'Offline kit (install.cmd for any PC)'
        chkEncrypted = 'Allow encrypted builds (.emsix - needs a Store licence)'
        btnDownload  = 'Download'
        btnPreview   = 'Preview'
        btnAll       = 'Download + Install'
        btnInstall   = 'Install only'
        btnStop      = 'Stop'
        btnCheck     = 'Check updates'
        btnClear     = 'Clear finished'
        hintIdle     = 'Paste a Microsoft Store link, or type a name and press Search.'
        hintSingle   = 'This app is offered as a single {0} package, so nothing has to be extracted.'
        hintExtract  = 'Only the {0} package is taken out of the bundle - the other architectures are not downloaded.'
        hintWin32    = 'Unpackaged Win32 app: the Store only links to the publisher''s own installer, so it is downloaded and you run it yourself.'
        msix         = 'MSIX package'
        win32        = 'Win32 installer'
        searching    = 'Searching the Store for ''{0}'' ...'
        noResults    = 'No results.'
        resolving    = 'Reading Store metadata ...'
        cantResolve  = 'Could not resolve this app.'
        ready        = 'Ready.'
        pickOne      = '{0} result(s) - pick one.'
        pickHint     = 'Pick a result to see its size, then press Download.'
        queued       = 'queued'
        running      = 'downloading'
        installing   = 'installing'
        done         = 'done'
        failed       = 'failed'
        stopped      = 'stopped'
        needDownload = 'Nothing downloaded yet - press Download first.'
        stopNote     = '*** stopped. What was already downloaded is kept -'
        stopNote2    = '*** press Download again and it continues where it left off.'
        tab          = 'Tab'
        downloadTab  = 'Download'
    }
    ar = @{
        sub          = 'نزّل أي برنامج من متجر مايكروسوفت مع الـ frameworks اللي محتاجها. x64 لو موجودة، x86 لو مش موجودة. التثبيت اختياري.'
        lang         = 'English'
        search       = 'بحث'
        results      = 'النتايج'
        app          = 'البرنامج'
        nothing      = 'مفيش حاجة مختارة'
        version      = 'النسخة'
        download     = 'الحجم'
        frameworks   = 'المكتبات'
        folder       = 'المجلد'
        arch         = 'المعمارية'
        chkExtract   = 'المعمارية دي بس (تجاهل باقي الشرائح في الباندل)'
        chkDeps      = 'نزّل المكتبات كمان'
        chkKit       = 'كيت أوفلاين (install.cmd يشتغل على أي جهاز)'
        chkEncrypted = 'اسمح بالنسخ المشفّرة (.emsix - محتاجة رخصة من المتجر)'
        btnDownload  = 'تنزيل'
        btnPreview   = 'معاينة'
        btnAll       = 'تنزيل + تثبيت'
        btnInstall   = 'تثبيت بس'
        btnStop      = 'إيقاف'
        btnCheck     = 'افحص التحديثات'
        btnClear     = 'امسح اللي خلص'
        hintIdle     = 'الصق رابط من المتجر، أو اكتب اسم واضغط بحث.'
        hintSingle   = 'البرنامج ده متاح كحزمة {0} واحدة، فمفيش حاجة تتستخرج.'
        hintExtract  = 'هيتم أخذ حزمة {0} بس من الباندل - باقي المعماريات مش هتتنزّل.'
        hintWin32    = 'تطبيق Win32 عادي: المتجر بيدّي لينك المثبّت بتاع المطوّر بس، فهيتنزّل وتشغّله بنفسك.'
        msix         = 'حزمة MSIX'
        win32        = 'مثبّت Win32'
        searching    = 'بيدور في المتجر على ''{0}'' ...'
        noResults    = 'مفيش نتايج.'
        resolving    = 'بيقرا بيانات البرنامج ...'
        cantResolve  = 'مش قادر يجيب البرنامج ده.'
        ready        = 'جاهز.'
        pickOne      = '{0} نتيجة - اختار واحدة.'
        pickHint     = 'اختار نتيجة تشوف حجمها، وبعدين اضغط تنزيل.'
        queued       = 'في الانتظار'
        running      = 'بينزّل'
        installing   = 'بيثبّت'
        done         = 'خلص'
        failed       = 'فشل'
        stopped      = 'اتوقف'
        needDownload = 'مفيش حاجة اتنزّلت - اضغط تنزيل الأول.'
        stopNote     = '*** اتوقف. اللي اتنزّل محفوظ -'
        stopNote2    = '*** اضغط تنزيل تاني وهو هيكمّل من مكانه.'
        tab          = 'تبويب'
        downloadTab  = 'تنزيل'
    }
}

function T([string]$key) {
    $d = $script:S[$script:Lang]
    if ($d.ContainsKey($key)) { return $d[$key] }
    if ($script:S['en'].ContainsKey($key)) { return $script:S['en'][$key] }
    return $key
}

# The window starts as a small search box and only grows when there is something
# to show: the results list, the app details, the job tabs and their logs are all
# empty and useless until then, so they are hidden and their rows collapsed to 0.
function Set-Layout([string]$mode) {
    $work = ($mode -ne 'idle')
    $vis = if ($work) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
    foreach ($e in @($gridMain, $gridOpts, $gridBtns, $brdJobs)) { $e.Visibility = $vis }
    for ($i = 2; $i -le 5; $i++) {
        $star = ($work -and $i -eq 2)
        $rootGrid.RowDefinitions[$i].Height =
            if ($star) { [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star) }
            elseif ($work) { [Windows.GridLength]::Auto }
            else { [Windows.GridLength]::new(0) }
    }
    $window.MinHeight = if ($work) { 700 } else { 250 }
    $window.Height = if ($work) { 880 } else { 250 }
}

function Set-Lang([string]$lang) {
    $script:Lang = $lang
    $rtl = ($lang -eq 'ar')
    $dir = [System.Windows.FlowDirection]::LeftToRight
    if ($rtl) { $dir = [System.Windows.FlowDirection]::RightToLeft }
    $window.FlowDirection = $dir
    $lblAppSub.Text = T 'sub'
    $btnLang.Content = T 'lang'
    $btnSearch.Content = T 'search'
    $lblResultsHead.Text = T 'results'
    $lblAppHead.Text = T 'app'
    $lblVersionCap.Text = T 'version'
    $lblSizeCap.Text = T 'download'
    $lblDepsCap.Text = T 'frameworks'
    $lblDestCap.Text = T 'folder'
    $lblArchCap.Text = T 'arch'
    $chkExtract.Content = T 'chkExtract'
    $chkDeps.Content = T 'chkDeps'
    $chkKit.Content = T 'chkKit'
    $chkEncrypted.Content = T 'chkEncrypted'
    $btnDownload.Content = T 'btnDownload'
    $btnPreview.Content = T 'btnPreview'
    $btnAll.Content = T 'btnAll'
    $btnInstall.Content = T 'btnInstall'
    $btnStop.Content = T 'btnStop'
    $btnCheck.Content = T 'btnCheck'
    $btnClear.Content = T 'btnClear'
    if (-not $script:Plan) {
        $lblTitle.Text = T 'nothing'
        $lblHint.Text = T 'hintIdle'
    }
    # the log is always English console output
    foreach ($j in $script:Jobs) { $j.Log.FlowDirection = 'LeftToRight' }
    $txtInput.FlowDirection = 'LeftToRight'
    $lblDest.FlowDirection = 'LeftToRight'
}

