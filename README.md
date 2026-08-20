# ClaudeCapper: Claude Code usage tracker and capper

Tracks your Claude Code plan usage and caps it before the included limits run out, so no extra usage credits are spent. Built because team plan members cannot turn off extra usage themselves. Windows only for now.

## Parts

- `check-usage.ps1`: the check that Claude Code hooks run automatically.
- `config.json`: all settings. Edited by the GUI; can also be edited by hand.
- `ClaudeCapper.exe`: the control panel, a standalone Windows executable (download from Releases, or build from `src/UsageStopperGui.cs`). Place it in the same folder as `check-usage.ps1`.
- `usage-stopper-gui.ps1`: the same control panel as a PowerShell script, for running without the exe.

## How it works

`check-usage.ps1` reads the OAuth token Claude Code stores in `~/.claude/.credentials.json` and calls Anthropic's usage endpoint (`https://api.anthropic.com/api/oauth/usage`), the same one the `/usage` command uses. It checks every limit the API reports: the 5-hour session limit, the weekly all-models limit, and any weekly per-model limit.

Two hooks in the user-level `~/.claude/settings.json` run the script, so they apply to Claude Code everywhere on the machine, including the VS Code extension:

- `UserPromptSubmit`: checked when a new message is sent.
- `PreToolUse`: checked before every tool call, so a long turn already running is also halted.

If a rule trips, the script exits with code 2, Claude Code blocks the action, and the message names the limit and its reset time. The API result is cached for 60 seconds in `%LOCALAPPDATA%`, so the per-tool-call cost is one local process spawn, not a network request. Config changes apply on the next check with nothing to restart.

## Setup

1. Put this folder anywhere, e.g. `C:\tools\claudecapper`.
2. Add the two hooks to `~/.claude/settings.json`, pointing at your copy of `check-usage.ps1`:

```json
"hooks": {
  "UserPromptSubmit": [
    { "hooks": [ { "type": "command", "command": "powershell.exe",
        "args": ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "C:\\tools\\claudecapper\\check-usage.ps1"],
        "timeout": 30, "statusMessage": "Checking Claude usage limits" } ] }
  ],
  "PreToolUse": [
    { "matcher": "*", "hooks": [ { "type": "command", "command": "powershell.exe",
        "args": ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "C:\\tools\\claudecapper\\check-usage.ps1"],
        "timeout": 30, "statusMessage": "Checking Claude usage limits" } ] }
  ]
}
```

3. Run `ClaudeCapper.exe` to see usage and adjust settings.

## Rules

1. **Threshold** (default 90): block when any limit reaches this percent. Below 100 so a request in flight cannot tip into extra usage.
2. **Daily pacing** (off by default): spreads the weekly limit over the week. You set how many percentage points of the weekly limit may be used per day; the allowance for day N of the week is N times that figure, so unused allowance carries forward. The default of 14.3 points per day spreads 100% evenly over 7 days. Blocks when weekly usage runs ahead of the allowance.
3. **Pause**: from the GUI, pause for 30 minutes, 2 hours, or until you press Resume. While paused nothing is blocked and extra usage can be spent. Timed pauses end on their own.

## The GUI

Run `ClaudeCapper.exe` (or `usage-stopper-gui.ps1`). It shows live usage bars with reset times (refreshed every minute), the pause controls, and the two rules above. Every change is saved to `config.json` immediately.

When minimized or closed, ClaudeCapper stays running in the Windows system tray / notification area to keep monitoring usage in the background. Left-click or double-click the tray icon to restore the window, or right-click the tray icon to pause/resume or Exit.

The exe is unsigned, so Windows SmartScreen may show an "unknown publisher" warning on first run; choose "More info" then "Run anyway", or build it yourself from source with the compiler that ships with Windows:

```
C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /target:winexe /win32icon:assets\icon.ico /out:ClaudeCapper.exe /r:System.Web.Extensions.dll src\UsageStopperGui.cs
```

## Limitations

- If the usage check itself fails (offline, token mid-refresh, API change), the script allows the action and prints a warning. It never locks you out because of its own failure.
- The endpoint is the one Claude Code uses internally but is not publicly documented, so its response shape could change.
- This governs Claude Code on the machine it is installed on. Usage from claude.ai in the browser counts against the same limits but cannot be blocked by a local hook.

## macOS

Not supported yet. The hook concept carries over, but on macOS Claude Code stores credentials in the Keychain rather than a file, and the control panel would need a native rebuild. A `.dmg` release is future work.

## Removal

Delete the `UserPromptSubmit` and `PreToolUse` entries from the `hooks` block in `~/.claude/settings.json` (or review them with the `/hooks` command inside Claude Code).

## Credits and license

ClaudeCapper is created and maintained by [Yasir Mo](https://github.com/yasir-mo).

Licensed under the [Apache License 2.0](LICENSE). Redistributions must retain the copyright notice and the [NOTICE](NOTICE) file crediting the author. ClaudeCapper is a community tool and is not affiliated with or endorsed by Anthropic; Claude is a trademark of Anthropic, PBC.
