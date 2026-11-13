# Contributing

Thanks for helping with NekoNotch. Bug reports, ideas and pull requests are all welcome.

## Reporting bugs and requesting features

Open an issue with the [bug report](https://github.com/1zumiii/NekoNotch/issues/new?template=bug-report.yml) or [feature request](https://github.com/1zumiii/NekoNotch/issues/new?template=feature-request.yml) form. "Report a bug" on the app's About page opens the bug report form with the app and macOS versions filled in.

Please search the existing issues first. For a large change, open an issue to discuss it before you start.

## Branches

- `custom-main` is the default branch. Base your work on it and target it with your pull request.
- NekoNotch is independent of [Boring Notch](https://github.com/TheBoredTeam/boring.notch). Fixes from upstream are cherry-picked one commit at a time, never merged wholesale.

## Building

Requires macOS 15.6 or later and Xcode 26 or later. The README's [Build from source](README.en.md#build-from-source) section explains how to sign with a local certificate so that macOS keeps the app's permissions across rebuilds.

Before you open a pull request, make sure the Release build and the tests pass:

```bash
python3 -m unittest discover -s scripts -p "test_*.py"
xcodebuild build -project boringNotch.xcodeproj -scheme boringNotch -configuration Release
xcodebuild test -project boringNotch.xcodeproj -scheme boringNotch -destination "platform=macOS"
```

CI runs the same steps on every pull request.

## Pull requests

- Give the pull request a descriptive title and explain what changed and why.
- Add a screenshot or a screen recording for anything visible on the notch.
- Link the issue it fixes with "Closes #123".
- Keep long-running animations on Core Animation (layers, `CABasicAnimation`, emitters) rather than SwiftUI timers, so the app stays near idle while they play.

## Code style

- Follow the conventions of the surrounding code. Type names are UpperCamelCase and functions and variables lowerCamelCase; a file is named after the main type it contains.
- Comment the reason behind non-obvious code, not what it does.
- Avoid force unwrapping (`!`), force casts (`as!`) and `try!` in new code. Where one is truly safe, say why in a comment.
- Log with `os.Logger` through `helpers/Log.swift`, not `print()`.
- Managers publish state and events (for example through `NotchUIEventBus`); only the coordinator and presenter layer decides what the UI shows.
- New files carry the same header comment as their neighbors. Files derived from third-party code state their license, with an SPDX identifier where practical.

## Where things are

| Location | Contents |
| --- | --- |
| `boringNotch/managers/SystemNotificationManager.swift` | Notification display, queue, placeholders and priorities |
| `boringNotch/managers/NotificationDatabaseWatcher.swift` | Notification database reader |
| `boringNotch/managers/NotificationHistory.swift`, `components/Notch/NotificationHistoryView.swift` | Notification history and the Notifications tab |
| `boringNotch/managers/FocusStatusMonitor.swift` | Focus state reader |
| `BoringNotchXPCHelper/NotificationWatcher.swift`, `EarlyNotificationSource.swift` | Banner capture and early signals, running in the XPC helper |
| `boringNotch/components/Dashboard/`, `components/Usage/` | Dashboard and usage cards |
| `boringNotch/components/Mixer/`, `managers/AudioCaptureManager.swift` | Mixer and audio capture |
| `boringNotch/models/BatteryAlertTracker.swift` | Battery alerts |
| `boringNotch/components/Notch/NotchShape.swift` | Battery line and charging pulse |
| `boringNotch/components/LiveActivities/RainbowCat/` | Rainbow cat, starry sky and system monitor |
| `boringNotch/components/Settings/UpdateChecker.swift` | Update check against the latest GitHub release |
| `scripts/` | Claude and Codex usage collectors and their tests |

## Releases

Releases are built by `.github/workflows/release.yml` when a `v*` tag is pushed. The tag must match `MARKETING_VERSION` in the project (a suffix such as `-rc1` is allowed and makes the release a prerelease). The workflow creates a draft release with the zipped app and its SHA-256 checksum; add the notes from [CHANGELOG.md](CHANGELOG.md) and publish it.

## License

By contributing, you agree that your contributions are licensed under the project's license, GPL-3.0.
