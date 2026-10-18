# ----------------------------------------------------------------------------- # Polling the running child # # Part of Store-Gui.ps1. Not runnable on its own: the entry script dot-sources # this file so that everything shares one scope. # ----------------------------------------------------------------------------- 
# ---------------------------------------------------------------- poll
function On-Tick {
    $job = $script:Running
    if (-not $job) { Start-NextJob; return }
    if ($job.State -ne 'running') { $script:Running = $null; Set-StopButton; Start-NextJob; return }

    $all = Read-Shared $job.LogFile
    if ($all -and $all.Length -gt $job.LogPos) {
        $job.Log.AppendText($all.Substring($job.LogPos))
        $job.LogPos = $all.Length
        $job.Log.ScrollToEnd()
    }

    $pf = Read-Shared $job.PfFile
    if ($pf) {
        try {
            $j = ConvertFrom-Json -InputObject $pf
            $job.Bar.Value = [double]$j.percent
            $job.Pct.Text = "$($j.percent)%"
            # the CLI speaks its own state names ("downloading", "installing", ...)
            $sk = [string]$j.state
            if ($sk -eq 'downloading') { $sk = 'running' }
            $txt = T $sk
            if ($j.count -gt 0) { $txt += "  -  file $($j.index)/$($j.count)" }
            if ($j.total -gt 0) { $txt += "  -  $(Format-Size ([long]$j.done)) / $(Format-Size ([long]$j.total))" }
            if ($j.rate -gt 0) { $txt += ("  -  {0:N0} KB/s" -f ($j.rate * 1024)) }
            $eta = Format-Eta ([int]$j.eta)
            if ($eta) { $txt += "  -  ~$eta" }
            if ($j.file) { $txt += "`n$($j.file)" }
            $job.Status.Text = $txt
        } catch { }
    }

    if ($job.Proc -and $job.Proc.HasExited) {
        # flush whatever the child wrote after our last read
        $all = Read-Shared $job.LogFile
        if ($all -and $all.Length -gt $job.LogPos) {
            $job.Log.AppendText($all.Substring($job.LogPos))
            $job.LogPos = $all.Length
        }
        $code = $job.Proc.ExitCode
        if ($code -eq 0) {
            $job.Bar.Value = 100
            $job.Pct.Text = '100%'
            Set-JobState $job 'done' (T 'done')
        } else {
            Set-JobState $job 'failed' ("$(T 'failed')  (exit $code)")
        }
        $script:Running = $null
        Set-StopButton
        Start-NextJob
    }
}

