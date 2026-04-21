# Claude Usage Bar

A lightweight macOS menu bar app to monitor your Claude Max subscription usage in real-time.

![Claude Usage Bar Screenshot](assets/screenshot.png)

## Features

- **Menu bar indicator** showing current session usage percentage
- **Detailed popover** with all usage metrics:
  - Session (5h) usage with reset countdown
  - Weekly limits for all models
  - Sonnet-only usage
  - Claude Design usage
- **Notch overlay** — hover the top of the screen to reveal a floating pill with session %, progress bar, and reset countdown. Sits right under the Mac notch (works on non-notched Macs too). Opt-in from Settings.
- **Auto-refresh** every 5 minutes
- **Secure storage** of credentials in macOS Keychain
- **Launch at startup** support via LaunchAgent

## Requirements

- macOS 12.0+ (Monterey or later)
- A Claude Max subscription
- Xcode Command Line Tools (for building)

## Installation

### Option 1: Build from source

```bash
git clone https://github.com/LouisMasson/ClaudeUsageBar.git
cd ClaudeUsageBar
swift build -c release
```

The executable will be at `.build/release/ClaudeUsageBar`

### Option 2: Open in Xcode

```bash
cd ClaudeUsageBar
open Package.swift
```

Then press `Cmd+R` to build and run.

## Configuration

On first launch, a configuration window will appear. You need to provide:

### 1. Organization ID

1. Go to [claude.ai/settings/usage](https://claude.ai/settings/usage)
2. Open DevTools (`Cmd+Option+I`)
3. Go to **Network** tab, filter by **XHR/Fetch**
4. Refresh the page
5. Look for a request to `/api/organizations/.../usage`
6. Copy the UUID from the URL (e.g., `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`)

### 2. Session Cookie

1. In the same request, go to **Headers** tab
2. Find **Request Headers** > **Cookie**
3. Copy only the `sessionKey=sk-ant-sid01-...` part

## Usage

- **Click** on the menu bar icon to see detailed usage
- **Refresh button** to manually update data
- **Gear icon** to open settings
- **X icon** to quit the app

## Notch overlay

A floating pill can appear under the Mac notch when the cursor enters a hot zone at the top of the screen — showing session %, a color-coded progress bar, and the reset countdown without having to click the menu bar icon.

1. Open **Settings** (gear icon in the popover)
2. Toggle **"Overlay sous l'encoche"** on, save
3. Move the cursor near the notch — the pill fades in; move away, it fades out

Implementation: a non-activating `NSPanel` positioned under `safeAreaInsets.top`, driven by a global mouse monitor. Doesn't steal focus. Disabled by default, persisted in `UserDefaults`. Also works on Macs without a notch (hot zone = top-center of the main screen).

## Launch at Startup

The app includes a LaunchAgent for automatic startup. To enable:

```bash
cp ~/Library/LaunchAgents/com.louismasson.ClaudeUsageBar.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.louismasson.ClaudeUsageBar.plist
```

## Project Structure

```
ClaudeUsageBar/
├── Package.swift              # Swift Package Manager config
├── README.md
├── claude-usage               # Helper script to start/stop
└── ClaudeUsageBar/
    ├── Info.plist
    └── Sources/
        ├── ClaudeUsageBarApp.swift    # App entry point
        ├── StatusBarController.swift   # Menu bar controller
        ├── PopoverView.swift           # SwiftUI views
        ├── UsageData.swift             # Data models
        ├── ClaudeAPIService.swift      # API client
        ├── KeychainHelper.swift        # Secure storage
        ├── NotchOverlayController.swift # Notch hover overlay (panel + mouse monitor)
        └── NotchOverlayView.swift       # SwiftUI pill rendered in the overlay
```

## Privacy & Security

- Credentials are stored securely in macOS Keychain
- No data is sent to third parties
- The app only communicates with `claude.ai`
- Session cookies expire after ~30 days and need to be refreshed

## License

MIT License - Feel free to use and modify.

---

Built with Swift and SwiftUI.
