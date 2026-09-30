# Status Keeper

A small Windows tray app that keeps your online status (Teams, Slack, etc.) active by nudging the mouse cursor a tiny, configurable amount whenever you've genuinely been idle for too long. No installer, no dependencies — just run the `.exe`.

## Features

- **System tray app** — a small dot icon in the notification area. Left-click opens the settings window; right-click gives a quick menu.
- **Idle-aware nudging** — checks Windows' real last-input timestamp before doing anything. If you're actively typing or using the mouse, it does nothing at all; it only nudges once you've genuinely been idle for the configured interval.
- **Configurable interval** — 20 seconds up to 5 minutes (presets or a custom value), controlling both how often it checks and the idle threshold before it acts.
- **Configurable nudge distance** — a real physical distance, 1mm to 5cm, not an arbitrary pixel count. It reads your monitor's true physical size (not just its resolution or Windows' DPI-scaling setting) to convert accurately, and shows a live cm/pixel readout as you adjust it.
- **Snooze** — pause for 30 min / 1 hour / 2 hours from the tray menu, with automatic resume. The settings window shows the exact resume time while snoozed, so you don't forget you paused it.
- **Lock on lid close** — optionally locks the computer the moment the laptop lid closes, detected directly from the hardware lid-switch signal rather than relying on (and potentially fighting) Windows' own power-plan settings, which may be locked down by IT policy anyway.
- **Display brightness & volume** — the settings window lists every display it can control, with live sliders: the laptop's built-in screen (brightness, via Windows) and external monitors (brightness and, where the monitor supports it, speaker volume, via DDC/CI — the monitor's own control channel over the video cable). Sliders read the monitor's real current values each time the window opens. The tray menu also has quick brightness presets (25/50/75/100%) for all displays at once.
- **Laptop brightness keys control external monitors too** — optional. The laptop's Fn brightness keys are handled by firmware and only ever change the built-in screen; with this enabled, every change is mirrored as the same relative step (e.g. +5%) onto external monitors, so each keeps its own offset from the laptop screen.
- **Light/dark theme detection** — automatically matches Windows' current app theme, including the window's title bar.
- **Activity log** — a live, scrollable log of every nudge, skip, pause, and theme/lid event, viewable right inside the settings window (auto-refreshing) or as a plain text file.
- **Self-installing** — running the `.exe` from anywhere (Downloads, a USB stick, wherever) asks for one-time consent, then copies itself to `%LOCALAPPDATA%\StatusKeeper`, registers to start at login, and adds a proper entry to Windows Settings → Apps, with a working Uninstall button.
- **Code-signed** — the binary is signed with a code-signing certificate. See [Code signing](#code-signing) below for what that does and doesn't cover.

## Installation

1. Download `StatusKeeper.exe`.
2. Run it.
3. Approve the one-time install prompt.

That's it — it's now running in the tray and will start automatically every time you log in.

## Usage

- **Left-click the tray icon** to open the settings window: pause/resume, adjust interval and nudge distance, toggle lock-on-lid-close, adjust display brightness/volume, and view the activity log.
- **Right-click the tray icon** for quick actions: Pause/Resume, Snooze presets, Interval presets, Brightness presets, Uninstall, Quit.

### Display control notes

- External monitors need **DDC/CI** enabled in their own on-screen menu (it usually is by default). Monitors that don't answer simply don't get sliders.
- The monitor volume slider is the monitor's own speaker/headphone-jack volume, separate from the Windows volume. Your laptop's volume keys keep controlling the Windows volume as usual.
- Brightness-key linking only works while the laptop screen is on: with the lid closed (external monitor only), Windows has no built-in brightness for the keys to change.
- Anything else that changes the laptop screen's brightness (e.g. battery saver dimming) is mirrored too while linking is on.
- After docking/undocking, click **Re-detect** (or reopen the window).

## Uninstalling

Either:
- Right-click the tray icon → **Uninstall**, or
- Windows Settings → Apps → Installed apps → **Status Keeper** → Uninstall

Both remove the auto-start entry and the Apps & Features registration. The installed files remain at `%LOCALAPPDATA%\StatusKeeper` in case you want logs/config back — delete that folder manually for a completely clean removal.

## Configuration files

All state lives in `%LOCALAPPDATA%\StatusKeeper\`:

| File | Contents |
|---|---|
| `interval.txt` | Nudge interval, in seconds |
| `distance.txt` | Nudge distance, in millimeters |
| `lidlock.txt` | `1` or `0` — lock-on-lid-close enabled |
| `linkbrightness.txt` | `1` or `0` — laptop brightness keys also adjust external monitors |
| `status-keeper.log` | Full activity log |

These are managed through the settings window — you shouldn't normally need to edit them by hand.

## Building from source

Requires the [`ps2exe`](https://www.powershellgallery.com/packages/ps2exe) PowerShell module:

```powershell
Install-Module ps2exe -Scope CurrentUser

Invoke-ps2exe -inputFile "StatusKeeper.ps1" -outputFile "StatusKeeper.exe" `
    -iconFile "icon.ico" -noConsole -STA `
    -title "Status Keeper" -product "Status Keeper" -version "1.2.0.0" `
    -description "Keeps your online status active" -company "Status Keeper"
```

### Code signing

The released `.exe` is signed with a self-signed code-signing certificate (`StatusKeeperCodeSigning.cer` in this repo is its public key). Signing removes "Unknown Publisher" warnings **only on machines that already trust this specific certificate** — it does not make the binary trusted on an arbitrary machine, since self-signed certificates aren't backed by a public Certificate Authority.

To trust it on a machine you own:

```powershell
$cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2("StatusKeeperCodeSigning.cer")
$store = New-Object System.Security.Cryptography.X509Certificates.X509Store("Root", "CurrentUser")
$store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
$store.Add($cert)
$store.Close()
```

For distribution to other people, a certificate from a public CA (DigiCert, Sectigo, etc.) is required — that's a paid, identity-verified process outside the scope of this project.

## Privacy

Status Keeper makes **zero network calls**. Nothing it does — cursor nudges, logging, config — ever leaves your machine.
