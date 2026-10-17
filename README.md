# Clawd for Mac

A native macOS menu bar companion for Claude Code, built with Swift, SwiftUI,
and AppKit. The floating panel shows usage limits, live sessions, and a small
pixel Clawd. Requires macOS 14 or later and Claude Code installed and signed in.

<p>
  <img src="docs/demo.png" width="340" alt="Clawd widget in demo mode: usage limits, the sky and Clawd">
</p>

## Build and run

Install Apple's Command Line Tools (`xcode-select --install`) with Swift 6 or
newer. No external packages or full Xcode installation are needed.

```sh
cd clawd-usage-macwidget
./scripts/build-app.sh
open dist/Clawd.app
```

For a preview with sample data and **no CLI or network calls**, quit any running
copy first, then:

```sh
open dist/Clawd.app --args --demo
```

`./scripts/build-app.sh --snapshot` also captures compact and expanded demo
previews in `dist/`, then quits. It requires a logged-in macOS desktop session.

Drag the header to reposition the widget. Click its menu bar percentage to
show/hide it; right-click for refresh, settings, and quit. Click Clawd for a
heart and one of the Claude Code animations; right-click him or the sky to
preview each mood, a time of day or a kind of weather (the current choice is
checked). “Auto” restores live behavior. The same works from the command line,
e.g. `--demo --sky night --weather 95` (a WMO weather code), also with
`--snapshot`. Hover
the usage row for the weather, wind and sunrise/sunset times.
Click the sessions line to list the live sessions; the window grows to fit
(a long list scrolls).

The weather city is set in Settings: type three or more letters and pick
the place from the list (Open-Meteo's geocoding, searched after a pause in
typing, each text asked once per run). Leave it empty to find the location by
IP; exact coordinates are under “Coordinates”.

Move the app to Applications before enabling **Launch at login** in Settings.
The build script ad-hoc signs the local app. Distribution to other computers
requires a Developer ID signature and notarization; these are not configured.
Set `CODE_SIGN_IDENTITY` to use your signing identity when building.

## Data and compatibility

Claude executable discovery checks `~/.local/bin/claude`, Homebrew locations,
and the inherited PATH; Settings can override it. The app invokes the executable
directly, never through a shell. It uses Claude's existing login and does not
read or store credentials.

Session files come from `~/.claude/sessions/*.json`.

The last usage report is stored at:

```
~/Library/Application Support/ClawdMac/last-usage.json
```

Preferences and window position use the `dev.clawd.mac` defaults domain. Demo
mode uses separate preferences and never writes the real usage report. The app
runs as the current user, outside App Sandbox, with no elevated helper.

## Development

```sh
swift build
swift run ClawdChecks
swift run ClawdMac --demo
```

- `Sources/ClawdCore`: portable usage parser, data models, mood/health rules.
- `Sources/ClawdMac`: AppKit lifecycle, SwiftUI views, polling and persistence.
- `Tests/ClawdCoreTests`: parser compatibility, dates, mood priority, storage format.

`swift run ClawdChecks` works with Command Line Tools alone. `swift test` runs the
same checks through XCTest when a full Xcode installation is selected.

Manual smoke check: start demo, drag the header, hide/show through the menu bar,
expand details, inspect all mascot moods, toggle pin/all-Spaces, open settings,
quit and relaunch. For live data, verify login and CLI path, refresh, then test
an invalid executable path to check that old values survive and an error appears.

## License

MIT © 2026 Maksim Kozhukh, see `LICENSE`.
Source: <https://github.com/mkozhukh/clawd-usage-macwidget>.

Based on [clawd-usage-winwidget](https://github.com/Enhed/clawd-usage-winwidget)
by Venger Sergey (MIT). The Clawd sprite geometry, mascot behaviour, and sky and
weather rules are ported from it; its notice is in `THIRD_PARTY_NOTICES`.

Not affiliated with Anthropic. Clawd and Claude belong to Anthropic.
