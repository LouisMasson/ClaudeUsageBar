# AI Usage Monitor

A lightweight native macOS menu bar app for monitoring AI usage, developer activity and personal infrastructure from one place.

[Website](https://claudeusagebar.louismasson.me) · [Download the latest release](https://github.com/LouisMasson/ClaudeUsageBar/releases/latest)

![AI Usage Monitor](assets/screenshot.png)

## Features

- Claude usage for the current 5-hour session and weekly limits
- Codex limits and local token activity
- OpenRouter credits and activity analytics
- Optional Cline Pass usage limits
- Collapsible menu bar sections with persistent visibility preferences
- GitHub activity summary for the last 30 days
- Website analytics through a compatible Plausible-backed status API
- VPS health, availability and local seven-day history
- Explainable anomaly detection for VPS health and AI usage, with a seven-day incident journal
- Native dark and light mode support
- Credentials stored in macOS Keychain
- Low-frequency background refreshes with caching
- Optional launch at login and notch overlay

## Requirements

- macOS 12 or later
- Xcode Command Line Tools when building from source
- Credentials only for the services you want to enable

All integrations are optional. The app can be used with only Claude, Codex, GitHub, OpenRouter or a configured VPS endpoint.

## Installation

Download the latest DMG from [GitHub Releases](https://github.com/LouisMasson/ClaudeUsageBar/releases/latest), or build locally:

```bash
git clone https://github.com/LouisMasson/ClaudeUsageBar.git
cd ClaudeUsageBar
swift build -c release
```

The executable is created at `.build/release/ClaudeUsageBar`.

To create a signed local app bundle and DMG:

```bash
VERSION=1.0.0 bash make_app.sh
```

## Configuration

Open the settings panel from the menu bar icon. Available integrations include:

- **Claude**: Claude Code OAuth, with a claude.ai session fallback
- **Codex**: automatically detected from the local Codex installation
- **OpenRouter**: API key for credits and an optional management key for activity
- **Cline Pass**: optional session cookie
- **GitHub**: automatically reuses GitHub CLI authentication, or accepts a personal token
- **VPS and websites**: read-only bearer token for a compatible `/api/menu-status` endpoint

The GitHub and dashboard analytics requests are cached for 15 minutes. Regular usage refreshes run every five minutes, while VPS health uses a lightweight two-minute refresh.

## Verification

```bash
swift build --disable-sandbox
.build/debug/ClaudeUsageBar --self-test
.build/debug/ClaudeUsageBar --github-live-test
```

The GitHub live test requires an authenticated GitHub CLI session.

## Privacy and security

- Credentials are stored together in one macOS Keychain item
- A single consolidated Keychain item minimizes permission prompts
- Tokens and cookies are never written to logs or committed to the repository
- The app communicates directly with the configured service APIs
- GitHub CLI authentication is reused in memory and is not copied into the app Keychain
- The VPS integration performs authenticated status reads and can only write the validated anomaly profile (`calm`, `balanced` or `sensitive`) plus the two anomaly enablement switches

## Project structure

```text
ClaudeUsageBar/Sources/
├── StatusBarController.swift
├── PopoverView.swift
├── DashboardView.swift
├── UsageData.swift
├── GitHubActivityService.swift
├── OpenRouterAPIService.swift
├── CodexUsageService.swift
├── VPSMonitoring.swift
└── KeychainHelper.swift
```

## License

MIT — feel free to use, modify and contribute.
