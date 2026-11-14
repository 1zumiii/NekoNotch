# Changelog

## 1.2.0

### Added

- The piano cat goes into warp with a transition: a red "!" flashes three times over its head, it flies through a blue ring and the sky goes to warp as it passes. The ring falls behind, faster and faster, behind the notch and out past the far wing. The cat stops singing until warp has begun.
- The piano cat stops hard out of warp: it braces for an instant, then sits back with its keyboard leaning up and pressed a little shorter, forelegs braced and tail flung forward, while its rainbow flicks up and the streaks break into stars that slide to a stop in three steps.
- The sky behind the cat has a third layer of faint dust, stars of varying brightness in white, pale yellow and pale blue, and now and then a shooting star.
- A switch, off by default, makes the notes follow the volume: more of them the louder the music. Off, they rise at a steady pace.
- When the main thread stops answering for more than 1.5 seconds, the app records where it is stuck in `Library/Logs/MainThreadStalls.log` in its container.

### Changed

- The notes come at random intervals, angles and sway, leaning back and forward in turn, and notes leaning the same way never overlap.
- The cat and the stars reach their top speeds at the warp threshold instead of at full load, so the whole range shows before warp. The defaults are 3x for the cat, whose short legs look frantic any faster, and 5.5x for the stars.
- Near stars no longer drift by side by side, and twinkling stars come in at least three seconds apart.
- The AI usage collector has new names: its folder is `~/Library/Application Support/NekoNotch` instead of `RunCatIntegrations`, the Codex file is `codex-usage.json` in that folder instead of `~/.codex/runcat-usage.json`, and the LaunchAgent is `io.github.1zumiii.nekonotch.ai-usage`. The app reads only the new locations and no longer needs access to `~/.codex`. If you installed the collector before, run `python3 scripts/install-ai-usage.py` again after updating: it moves the existing data, token cache included, retires the old agent and updates the Claude Code status line.

### Fixed

- The XPC helper requires the app to be signed with the same certificate as itself. Without a Team ID it used to check only the app's identifier, which anyone can sign with.
- The media key tap runs on a thread of its own, so a busy main thread no longer holds up clicks and keys across the system. Unit test runs no longer start the app's services, which had stalled clicks for a few seconds while they ran.
- If macOS changes how it stores notification records, the service status says the database cannot be read and names who is affected, instead of dropping every record without a word.
- Twinkling stars no longer twinkle faster under load and at warp.
- Notes no longer come out in step after a pause in the media.

### Removed

- The move of an app installed as `boringNotch.app` to `NekoNotch.app` at launch, which went through the XPC helper.

## 1.1.1

### Added

- The starry wing left of the notch makes way for app menus: when it covers the last of an app's menus, it folds away as the pointer comes over it and comes back once the pointer has left the menu bar and no menu is open. It can be turned off in the rainbow cat settings.

### Changed

- Releases are signed with a fixed self-signed certificate instead of ad hoc, so macOS keeps the permissions it has granted across updates. Updating from 1.1.0 still needs them granted once more.

### Fixed

- Full-screen scrolling notifications: with the rainbow cat on, the line under the notch is as wide as the row above it, so the text comes in at the right edge instead of leaving a gap there. Long text starts clear of the rounded corner and stops a little short of the right edge.
- swiftui-introspect is updated to 26.2.0; the earlier update changed only the resolved packages, so builds kept using 26.1.0.

## 1.1.0

The first version as NekoNotch, based on Boring Notch `v2.8-rc.2`.

### Added

- Rainbow cat and starry sky on the closed notch, with speed-up and warp following CPU load, and a singing cat with floating notes while media plays.
- System monitor panel opened from the cat: CPU, memory and network with a 60-second history, storage, battery health and the apps using the most energy, with the same settings button as the home view.
- Notifications in the notch: banner takeover, Notification Center database reading, time-sensitive notifications with a rainbow outline, per-app rules, full-screen scrolling, click-through to the source app and a service status page.
- Notifications tab with the last 50 notifications, and Focus awareness.
- Dashboard on a 12 × 4 grid with Claude and Codex quota cards and an AI token usage heat map.
- Mixer with per-app volume, mute, solo, balance, mono, output device and scenes, built on Core Audio process taps.
- Text clipboard area in the Shelf, multi-threshold low-battery alerts, a battery line under the notch and a multicolor waveform.
- Update check against this repository's latest GitHub release, replacing Sparkle.

### Fixed and improved

- Notification handling on macOS 27: the system now places all banners in one full-screen window, which the previous height-based filter ignored. Detection now looks for banner elements and tells live banners apart from entries in the Notification Center sidebar. Opening Notification Center no longer moves the wrong window or shows notifications again.
- Notification text: when two notifications arrived in quick succession, the second could take over the first one's icon placeholder, and the first one's text was then dropped as a duplicate.
- Gap below the notch: the macOS 27 menu bar is 1–2 pt taller than the notch, and the notch height now follows the menu bar.
- OSD settings: the page now has its own title instead of keeping the previous page's.
- Calendar: the event list loads once when the notch opens, with a skeleton view until the data settles.
- Notification dismissal: notifications no longer stay open after opening the notch on their own because the pointer was wrongly seen as hovering, and the notification view stays until the notch finishes closing.
- Helper startup: orphaned `log stream` processes left by a forced quit are cleaned up.
- Helper services: the helper's notification services restart after sleep, a dropped connection or a stale banner watcher. The early signal ignores badge-only requests that carry no text.
- Closing the notch: the notch closes when a notification is dismissed even with the pointer over it, and a notch opened by a file drag closes once the drag ends away from it.
- Energy: the charging pulse and the rainbow outline run on Core Animation. The mixer polls Core Audio only while its page is open or apps are re-routed; the notification database is read on file events with a slow fallback.
- App icons are also looked up in `/System/Applications/Utilities`, and the app name index is built in the background, removing a 1–2 second stall.
- Simplified Chinese: most untranslated text is filled in, and all new features are translated.
