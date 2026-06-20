# ClaudeCapper
# Copyright 2026 Yasir Mo (https://github.com/yasir-mo). Apache License 2.0.
# Blocks Claude Code (via hooks) when 5-hour or weekly usage reaches the configured
# threshold, so no extra usage credits are consumed. Settings live in config.json
# next to this script and are edited with usage-stopper-gui.ps1.
# Exit 0 = allow, exit 2 = block (Claude Code hook convention).

param(
    [int]$CacheSeconds = 60    # reuse the last API result for this many seconds
)

$ErrorActionPreference = 'Stop'

function Get-FriendlyName([string]$kind, $scope) {
    switch ($kind) {
        'session'       { return '5-hour session limit' }
        'weekly_all'    { return 'weekly limit (all models)' }
        'weekly_scoped' {
            $model = $null
            if ($scope -and $scope.model) { $model = $scope.model.display_name }
            if ($model) { return "weekly $model limit" } else { return 'weekly model limit' }
        }
        default         { return "$kind limit" }
    }
}

try {
    # ---- configuration (defaults, overridden by config.json) ----
    $threshold = 90
    $pausedUntilEpoch = 0
    $pacingEnabled = $false
    $pointsPerDay = 14.3

    $toolDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $configFile = Join-Path $toolDir 'config.json'
    if (Test-Path $configFile) {
        try {
            $cfg = Get-Content $configFile -Raw | ConvertFrom-Json
            if ($null -ne $cfg.threshold)            { $threshold = [double]$cfg.threshold }
            if ($null -ne $cfg.pausedUntilEpoch)     { $pausedUntilEpoch = [long]$cfg.pausedUntilEpoch }
            if ($null -ne $cfg.pacing) {
                if ($null -ne $cfg.pacing.enabled)      { $pacingEnabled = [bool]$cfg.pacing.enabled }
                if ($null -ne $cfg.pacing.pointsPerDay) { $pointsPerDay = [double]$cfg.pacing.pointsPerDay }
            }
        } catch {}
    }

    $nowEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    # ---- pause: -1 = paused until manually resumed, >now = timed pause ----
    if ($pausedUntilEpoch -eq -1 -or $pausedUntilEpoch -gt $nowEpoch) { exit 0 }

    # ---- fetch usage (cached) ----
    $cacheFile = Join-Path $env:LOCALAPPDATA 'ClaudeCapper.cache.json'
    $limits = $null
    if (Test-Path $cacheFile) {
        try {
            $cache = Get-Content $cacheFile -Raw | ConvertFrom-Json
            if (($nowEpoch - [long]$cache.fetchedEpoch) -lt $CacheSeconds) { $limits = $cache.limits }
        } catch {}
    }
    if ($null -eq $limits) {
        $credPath = Join-Path $env:USERPROFILE '.claude\.credentials.json'
        $token = (Get-Content $credPath -Raw | ConvertFrom-Json).claudeAiOauth.accessToken
        $resp = Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/usage' -TimeoutSec 10 -Headers @{
            'Authorization'  = "Bearer $token"
            'anthropic-beta' = 'oauth-2025-04-20'
        }
        $limits = $resp.limits
        if ($null -eq $limits) { throw 'usage response contained no limits field' }
        @{ fetchedEpoch = $nowEpoch; limits = $limits } | ConvertTo-Json -Depth 6 | Set-Content $cacheFile -Encoding utf8
    }

    $nowUtc = [DateTimeOffset]::UtcNow

    foreach ($limit in $limits) {
        $name = Get-FriendlyName $limit.kind $limit.scope
        $resetText = ''
        if ($limit.resets_at) {
            $resetLocal = [DateTimeOffset]::Parse($limit.resets_at).ToLocalTime().ToString('ddd HH:mm')
            $resetText = " Resets $resetLocal."
        }

        # ---- hard threshold ----
        if ($limit.percent -ge $threshold) {
            [Console]::Error.WriteLine("BLOCKED by ClaudeCapper: $name is at $($limit.percent)% (threshold $threshold%). Stopping so no extra usage credits are spent.$resetText Open the ClaudeCapper app to pause this block deliberately.")
            exit 2
        }

        # ---- daily pacing of weekly limits: allowance = pointsPerDay x day number ----
        if ($pacingEnabled -and $limit.group -eq 'weekly' -and $limit.resets_at) {
            $weekStart = [DateTimeOffset]::Parse($limit.resets_at).AddDays(-7)
            $dayNumber = [Math]::Floor(($nowUtc - $weekStart).TotalDays) + 1
            if ($dayNumber -lt 1) { $dayNumber = 1 }
            if ($dayNumber -gt 7) { $dayNumber = 7 }
            $allowed = [Math]::Min($threshold, $pointsPerDay * $dayNumber)
            if ($limit.percent -ge $allowed) {
                [Console]::Error.WriteLine("BLOCKED by ClaudeCapper (daily pacing): $name is at $($limit.percent)%, past today's allowance of $([Math]::Round($allowed,1))% (day $dayNumber of 7 at $pointsPerDay points/day).$resetText Open the ClaudeCapper app to pause or adjust pacing.")
                exit 2
            }
        }
    }
    exit 0
}
catch {
    # Fail open: never lock the user out because the check itself failed.
    [Console]::Error.WriteLine("ClaudeCapper: check failed, allowing. ($($_.Exception.Message))")
    exit 0
}

