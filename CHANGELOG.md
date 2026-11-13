# Changelog

## 1.1.0

The first version as NekoNotch, based on Boring Notch `v2.8-rc.2`.

### Added

- Rainbow cat and starry sky on the closed notch, with speed-up and warp following CPU load, and a singing cat with floating notes while media plays.
- System monitor panel opened from the cat: CPU, memory and network with a 60-second history, storage, battery health and the apps using the most energy.
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
