# ClaudeCapper - control panel
# Copyright 2026 Yasir Mo (https://github.com/yasir-mo). Apache License 2.0.
# Shows live usage, lets you pause the stopper deliberately, and edits config.json
# (threshold and daily pacing). Changes apply immediately; the hook script reads
# config.json on every check.

$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$configFile = Join-Path $toolDir 'config.json'
$errorLog = Join-Path $toolDir 'gui-error.log'

try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    # ---------- config ----------
    function Load-Config {
        $cfg = @{ threshold = 90; pausedUntilEpoch = [long]0; pacingEnabled = $false; pointsPerDay = 14.3 }
        if (Test-Path $configFile) {
            try {
                $j = Get-Content $configFile -Raw | ConvertFrom-Json
                if ($null -ne $j.threshold)            { $cfg.threshold = [double]$j.threshold }
                if ($null -ne $j.pausedUntilEpoch)     { $cfg.pausedUntilEpoch = [long]$j.pausedUntilEpoch }
                if ($null -ne $j.pacing) {
                    if ($null -ne $j.pacing.enabled)      { $cfg.pacingEnabled = [bool]$j.pacing.enabled }
                    if ($null -ne $j.pacing.pointsPerDay) { $cfg.pointsPerDay = [double]$j.pacing.pointsPerDay }
                }
            } catch {}
        }
        return $cfg
    }
    function Save-Config {
        $obj = [ordered]@{
            threshold = [double]$script:numThreshold.Value
            pausedUntilEpoch = [long]$script:pausedUntilEpoch
            pacing = [ordered]@{
                enabled = [bool]$script:chkPacing.Checked
                pointsPerDay = [double]$script:numPointsPerDay.Value
            }
        }
        $obj | ConvertTo-Json -Depth 4 | Set-Content $configFile -Encoding utf8
    }

    $cfg = Load-Config
    $script:pausedUntilEpoch = $cfg.pausedUntilEpoch
    $script:limits = $null
    $script:loading = $true   # suppress auto-save while controls are initialised
    $script:isExiting = $false

    # ---------- usage fetch ----------
    function Get-FriendlyName([string]$kind, $scope) {
        switch ($kind) {
            'session'       { return '5-hour session' }
            'weekly_all'    { return 'Weekly (all models)' }
            'weekly_scoped' {
                $model = $null
                if ($scope -and $scope.model) { $model = $scope.model.display_name }
                if ($model) { return "Weekly ($model)" } else { return 'Weekly (model)' }
            }
            default         { return $kind }
        }
    }
    function Fetch-Usage {
        $credPath = Join-Path $env:USERPROFILE '.claude\.credentials.json'
        $token = (Get-Content $credPath -Raw | ConvertFrom-Json).claudeAiOauth.accessToken
        $resp = Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/usage' -TimeoutSec 10 -Headers @{
            'Authorization'  = "Bearer $token"
            'anthropic-beta' = 'oauth-2025-04-20'
        }
        return $resp.limits
    }

    # ---------- form ----------
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'ClaudeCapper'
    $form.Icon = [System.Drawing.SystemIcons]::Shield
    $form.FormBorderStyle = 'FixedSingle'
    $form.MaximizeBox = $false
    $form.ClientSize = New-Object System.Drawing.Size(460, 480)
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    # --- system tray icon & menu ---
    $notifyIcon = New-Object System.Windows.Forms.NotifyIcon
    $notifyIcon.Icon = [System.Drawing.SystemIcons]::Shield
    $notifyIcon.Text = 'ClaudeCapper: Active'
    $notifyIcon.Visible = $true

    $trayMenu = New-Object System.Windows.Forms.ContextMenuStrip

    function Restore-Window {
        $form.Show()
        $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
        $form.ShowInTaskbar = $true
        $form.BringToFront()
        $form.Activate()
    }

    function Exit-Application {
        $script:isExiting = $true
        if ($notifyIcon) {
            $notifyIcon.Visible = $false
            $notifyIcon.Dispose()
        }
        $form.Close()
        [System.Windows.Forms.Application]::Exit()
    }

    $itemOpen = New-Object System.Windows.Forms.ToolStripMenuItem('Open ClaudeCapper')
    $itemOpen.Font = New-Object System.Drawing.Font($itemOpen.Font, [System.Drawing.FontStyle]::Bold)
    $itemOpen.Add_Click({ Restore-Window })
    $trayMenu.Items.Add($itemOpen) | Out-Null
    $trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    $itemP30 = New-Object System.Windows.Forms.ToolStripMenuItem('Pause 30 min')
    $itemP30.Add_Click({ Set-Pause ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 1800) })
    $trayMenu.Items.Add($itemP30) | Out-Null

    $itemP2h = New-Object System.Windows.Forms.ToolStripMenuItem('Pause 2 h')
    $itemP2h.Add_Click({ Set-Pause ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 7200) })
    $trayMenu.Items.Add($itemP2h) | Out-Null

    $itemPMan = New-Object System.Windows.Forms.ToolStripMenuItem('Pause until resumed')
    $itemPMan.Add_Click({ Set-Pause ([long](-1)) })
    $trayMenu.Items.Add($itemPMan) | Out-Null

    $itemRes = New-Object System.Windows.Forms.ToolStripMenuItem('Resume')
    $itemRes.Add_Click({ Set-Pause ([long]0) })
    $trayMenu.Items.Add($itemRes) | Out-Null

    $trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    $itemExit = New-Object System.Windows.Forms.ToolStripMenuItem('Exit')
    $itemExit.Add_Click({ Exit-Application })
    $trayMenu.Items.Add($itemExit) | Out-Null

    $notifyIcon.ContextMenuStrip = $trayMenu
    $notifyIcon.Add_DoubleClick({ Restore-Window })
    $notifyIcon.Add_MouseClick({
        param($sender, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Restore-Window }
    })

    # --- protection status + pause controls ---
    $grpStatus = New-Object System.Windows.Forms.GroupBox
    $grpStatus.Text = 'Protection'
    $grpStatus.SetBounds(12, 8, 436, 110)
    $form.Controls.Add($grpStatus)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.SetBounds(12, 22, 410, 20)
    $lblStatus.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $grpStatus.Controls.Add($lblStatus)

    $btnPause30 = New-Object System.Windows.Forms.Button
    $btnPause30.Text = 'Pause 30 min'
    $btnPause30.SetBounds(12, 50, 95, 28)
    $grpStatus.Controls.Add($btnPause30)

    $btnPause2h = New-Object System.Windows.Forms.Button
    $btnPause2h.Text = 'Pause 2 h'
    $btnPause2h.SetBounds(113, 50, 95, 28)
    $grpStatus.Controls.Add($btnPause2h)

    $btnPauseManual = New-Object System.Windows.Forms.Button
    $btnPauseManual.Text = 'Pause until resumed'
    $btnPauseManual.SetBounds(214, 50, 130, 28)
    $grpStatus.Controls.Add($btnPauseManual)

    $btnResume = New-Object System.Windows.Forms.Button
    $btnResume.Text = 'Resume'
    $btnResume.SetBounds(350, 50, 72, 28)
    $grpStatus.Controls.Add($btnResume)

    $lblPauseNote = New-Object System.Windows.Forms.Label
    $lblPauseNote.SetBounds(12, 84, 410, 18)
    $lblPauseNote.Text = 'While paused, blocks are off and extra usage can be spent.'
    $lblPauseNote.ForeColor = [System.Drawing.Color]::DimGray
    $grpStatus.Controls.Add($lblPauseNote)

    # --- usage display ---
    $grpUsage = New-Object System.Windows.Forms.GroupBox
    $grpUsage.Text = 'Usage now'
    $grpUsage.SetBounds(12, 126, 436, 170)
    $form.Controls.Add($grpUsage)

    $usageRows = @()
    for ($i = 0; $i -lt 4; $i++) {
        $y = 22 + $i * 34
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.SetBounds(12, $y, 245, 16)
        $lbl.Visible = $false
        $grpUsage.Controls.Add($lbl)
        $bar = New-Object System.Windows.Forms.ProgressBar
        $bar.SetBounds(260, $y, 120, 16)
        $bar.Minimum = 0; $bar.Maximum = 100
        $bar.Visible = $false
        $grpUsage.Controls.Add($bar)
        $pct = New-Object System.Windows.Forms.Label
        $pct.SetBounds(386, $y, 44, 16)
        $pct.Visible = $false
        $grpUsage.Controls.Add($pct)
        $usageRows += ,@($lbl, $bar, $pct)
    }

    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = 'Refresh'
    $btnRefresh.SetBounds(348, 136, 74, 24)
    $grpUsage.Controls.Add($btnRefresh)

    $lblFetched = New-Object System.Windows.Forms.Label
    $lblFetched.SetBounds(12, 141, 330, 16)
    $lblFetched.ForeColor = [System.Drawing.Color]::DimGray
    $grpUsage.Controls.Add($lblFetched)

    # --- settings ---
    $grpSettings = New-Object System.Windows.Forms.GroupBox
    $grpSettings.Text = 'Settings (saved immediately)'
    $grpSettings.SetBounds(12, 304, 436, 138)
    $form.Controls.Add($grpSettings)

    $lblThreshold = New-Object System.Windows.Forms.Label
    $lblThreshold.Text = 'Block when any limit reaches (%):'
    $lblThreshold.SetBounds(12, 26, 220, 18)
    $grpSettings.Controls.Add($lblThreshold)

    $numThreshold = New-Object System.Windows.Forms.NumericUpDown
    $numThreshold.SetBounds(240, 23, 60, 22)
    $numThreshold.Minimum = 50; $numThreshold.Maximum = 100
    $numThreshold.Value = [decimal][Math]::Min(100, [Math]::Max(50, $cfg.threshold))
    $grpSettings.Controls.Add($numThreshold)

    $chkPacing = New-Object System.Windows.Forms.CheckBox
    $chkPacing.Text = 'Pace the weekly limit so it lasts the full week'
    $chkPacing.SetBounds(12, 56, 320, 20)
    $chkPacing.Checked = $cfg.pacingEnabled
    $grpSettings.Controls.Add($chkPacing)

    $lblPoints = New-Object System.Windows.Forms.Label
    $lblPoints.Text = 'Points of the weekly limit per day:'
    $lblPoints.SetBounds(30, 84, 205, 18)
    $grpSettings.Controls.Add($lblPoints)

    $numPointsPerDay = New-Object System.Windows.Forms.NumericUpDown
    $numPointsPerDay.SetBounds(240, 81, 60, 22)
    $numPointsPerDay.Minimum = 1; $numPointsPerDay.Maximum = 100
    $numPointsPerDay.DecimalPlaces = 1
    $numPointsPerDay.Increment = [decimal]0.5
    $numPointsPerDay.Value = [decimal][Math]::Min(100, [Math]::Max(1, $cfg.pointsPerDay))
    $grpSettings.Controls.Add($numPointsPerDay)

    $lblAllowedToday = New-Object System.Windows.Forms.Label
    $lblAllowedToday.SetBounds(30, 110, 390, 18)
    $lblAllowedToday.ForeColor = [System.Drawing.Color]::DimGray
    $grpSettings.Controls.Add($lblAllowedToday)

    $lblFooter = New-Object System.Windows.Forms.Label
    $lblFooter.SetBounds(12, 452, 436, 18)
    $lblFooter.Text = 'Minimizing or closing hides to tray. Right-click tray icon to Exit.'
    $lblFooter.ForeColor = [System.Drawing.Color]::DimGray
    $form.Controls.Add($lblFooter)

    # ---------- behaviour ----------
    function Update-StatusLabel {
        $nowEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        if ($script:pausedUntilEpoch -eq -1) {
            $lblStatus.Text = 'PAUSED until you press Resume'
            $lblStatus.ForeColor = [System.Drawing.Color]::Firebrick
        } elseif ($script:pausedUntilEpoch -gt $nowEpoch) {
            $until = [DateTimeOffset]::FromUnixTimeSeconds($script:pausedUntilEpoch).ToLocalTime().ToString('HH:mm')
            $lblStatus.Text = "PAUSED until $until"
            $lblStatus.ForeColor = [System.Drawing.Color]::Firebrick
        } else {
            if ($script:pausedUntilEpoch -ne 0) { $script:pausedUntilEpoch = [long]0; Save-Config }
            $lblStatus.Text = 'Active: Claude Code stops before extra usage is spent'
            $lblStatus.ForeColor = [System.Drawing.Color]::ForestGreen
        }

        if ($notifyIcon) {
            $statusText = if ($script:pausedUntilEpoch -eq -1) { 'PAUSED (manual)' } elseif ($script:pausedUntilEpoch -gt $nowEpoch) { 'PAUSED' } else { 'Active' }
            $text = "ClaudeCapper: $statusText"
            if ($text.Length -gt 63) { $text = $text.Substring(0, 63) }
            $notifyIcon.Text = $text
        }
    }

    function Update-AllowedToday {
        if (-not $chkPacing.Checked) { $lblAllowedToday.Text = ''; return }
        $weekly = $null
        if ($script:limits) { $weekly = $script:limits | Where-Object { $_.kind -eq 'weekly_all' } | Select-Object -First 1 }
        if ($weekly -and $weekly.resets_at) {
            $weekStart = [DateTimeOffset]::Parse($weekly.resets_at).AddDays(-7)
            $dayNumber = [Math]::Floor(([DateTimeOffset]::UtcNow - $weekStart).TotalDays) + 1
            if ($dayNumber -lt 1) { $dayNumber = 1 }
            if ($dayNumber -gt 7) { $dayNumber = 7 }
            $allowed = [Math]::Min([double]$numThreshold.Value, [double]$numPointsPerDay.Value * $dayNumber)
            $lblAllowedToday.Text = "Allowed so far (day $dayNumber of 7): $([Math]::Round($allowed,1))% of the weekly limit."
        } else {
            $lblAllowedToday.Text = 'Allowance is computed from the weekly reset time once usage loads.'
        }
    }

    function Refresh-Usage {
        try {
            $script:limits = Fetch-Usage
            $i = 0
            foreach ($limit in $script:limits) {
                if ($i -ge $usageRows.Count) { break }
                $row = $usageRows[$i]
                $resetText = ''
                if ($limit.resets_at) {
                    $resetText = ' (resets ' + [DateTimeOffset]::Parse($limit.resets_at).ToLocalTime().ToString('ddd HH:mm') + ')'
                }
                $row[0].Text = (Get-FriendlyName $limit.kind $limit.scope) + $resetText
                $row[1].Value = [Math]::Min(100, [Math]::Max(0, [int]$limit.percent))
                $row[2].Text = "$($limit.percent)%"
                $row[0].Visible = $true; $row[1].Visible = $true; $row[2].Visible = $true
                $i++
            }
            for (; $i -lt $usageRows.Count; $i++) {
                $usageRows[$i][0].Visible = $false; $usageRows[$i][1].Visible = $false; $usageRows[$i][2].Visible = $false
            }
            $lblFetched.Text = 'Updated ' + (Get-Date).ToString('HH:mm:ss')
        } catch {
            $lblFetched.Text = 'Could not load usage: ' + $_.Exception.Message
        }
        Update-AllowedToday
    }

    function Set-Pause([long]$untilEpoch) {
        $script:pausedUntilEpoch = $untilEpoch
        Save-Config
        Update-StatusLabel
    }

    $btnPause30.Add_Click({ Set-Pause ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 1800) })
    $btnPause2h.Add_Click({ Set-Pause ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 7200) })
    $btnPauseManual.Add_Click({ Set-Pause ([long](-1)) })
    $btnResume.Add_Click({ Set-Pause ([long]0) })
    $btnRefresh.Add_Click({ Refresh-Usage })

    $numThreshold.Add_ValueChanged({ if (-not $script:loading) { Save-Config; Update-AllowedToday } })
    $chkPacing.Add_CheckedChanged({
        if (-not $script:loading) { Save-Config }
        $numPointsPerDay.Enabled = $chkPacing.Checked
        $lblPoints.Enabled = $chkPacing.Checked
        Update-AllowedToday
    })
    $numPointsPerDay.Add_ValueChanged({ if (-not $script:loading) { Save-Config; Update-AllowedToday } })

    $form.Add_Resize({
        if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
            $form.Hide()
            $form.ShowInTaskbar = $false
        }
    })

    $form.Add_FormClosing({
        param($sender, $e)
        if (-not $script:isExiting -and $e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
            $e.Cancel = $true
            $form.Hide()
            $form.ShowInTaskbar = $false
        } else {
            if ($notifyIcon) {
                $notifyIcon.Visible = $false
                $notifyIcon.Dispose()
            }
        }
    })

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 60000
    $timer.Add_Tick({ Refresh-Usage; Update-StatusLabel })
    $timer.Start()

    $numPointsPerDay.Enabled = $chkPacing.Checked
    $lblPoints.Enabled = $chkPacing.Checked
    $script:loading = $false

    Update-StatusLabel
    Refresh-Usage

    [System.Windows.Forms.Application]::Run($form)
    $timer.Stop()
}
catch {
    $_ | Out-String | Set-Content $errorLog -Encoding utf8
    try { [System.Windows.Forms.MessageBox]::Show("ClaudeCapper failed to start. See gui-error.log.") } catch {}
    exit 1
}
