<h1 align="center">Boring Notch · Izumi Edition</h1>

<p align="center"><a href="README.md">简体中文</a> · English</p>

<p align="center">
  A personal fork of <a href="https://github.com/TheBoredTeam/boring.notch">Boring Notch</a>, with notifications, a dashboard, and an app mixer in the notch.<br>
  The original upstream documentation is kept in <a href="README.upstream.md">README.upstream.md</a>.
</p>

---

## About this fork

This fork is based on [TheBoredTeam/boring.notch](https://github.com/TheBoredTeam/boring.notch) `v2.8-rc.2`. I've added features I wanted for daily use and fixed issues I ran into on macOS 26 and 27.

- The default branch is `custom-main`. Updates are merged from upstream; this fork does not push changes or submit PRs upstream.
- In-app updates (Sparkle) are disabled to prevent official builds from overwriting the custom changes. The About page shows `Izumi Edition ✨ 1.1.0`. To pick up upstream updates, merge them into `custom-main` and rebuild.
- Daily use and testing are mainly on macOS 27. The app keeps upstream's macOS 14+ requirement. The mixer's Core Audio process taps require macOS 14.2 or later.

## Added features

### Notification handling

Notifications can appear directly in the notch. You can also turn off an app's system banners and keep its notifications in the notch only.

- Banner capture: reads system notification banners through Accessibility, moves them off-screen, and displays them in the notch.
- Automatic expansion: opens the notch when a notification arrives, without needing to move the pointer over it. Display time is adjustable from 2 to 30 seconds, after which the notch closes automatically.
- App filtering: shows notifications from all apps or only the apps you select.
- Excluded apps: apps on this list are not shown in the notch, and their system banners are left alone. Apps that sent notifications recently are listed in settings so they can be added directly. macOS background agents (such as Background Items) share one name and icon.
- Icon only: for the chosen apps, a notification shows only the app's icon on the left of the closed notch, in place of the album art while music plays. A small dot on the icon marks it as a notification.
- Click to open: clicking a notification read from a banner presses the system banner itself, so the app opens the right conversation or item.
- Database reading: reads the Notification Center database directly and requires Full Disk Access. With this enabled, an app's notifications still appear in the notch when its system banners are disabled, avoiding a brief flash of the system banner.
- Source app preview: when an app with banners disabled sends a notification, its icon appears first. About 5 seconds later, the system writes the body to the database, and the text is filled in at the same position. The early signal comes from `usernoted` log entries indicating that the notification has been stored.
- Time-sensitive notifications: notifications marked as time-sensitive or critical in the database get a rotating rainbow border along the sides and bottom, and stay visible for twice as long. Ordinary notifications wait in the queue until they close. Classification uses the database record's `intrp` field. The passive level has been verified with real notifications; the time-sensitive and critical levels are inferred from the system's level definitions and have not yet been verified with real notifications.
- Service status: the top of the notification settings page shows the status of the background helper, banner capture, database reader, and early signal source, along with the time of the latest event. If notifications aren't appearing, check these statuses or click “Restart Service.”
- Test notifications: select a real system notification, an ordinary notification, or a time-sensitive notification from the dropdown, then send it.

App icon lookup also covers `/System/Applications/Utilities`. The app-name-to-Bundle-ID index is now built in the background, avoiding a 1–2 second pause during lookup.

### Notification history and Focus

- Notifications tab: a new tab in the notch lists the last 50 notifications, newest first, with app, time, title, and body. Click one to open its app, hover to remove it, or clear everything from the left panel. A red dot on the tab icon marks notifications not yet seen.
- Privacy: the history is kept in memory only, never written to disk, and cleared when the app quits. Turning off “Keep a history” in the notification settings also hides the tab.
- Focus: while a Focus is on, the system shows no banners but still writes notifications to the database. The default, “Follow the Focus”, shows in the notch only what the system lets through: notifications that still get a banner, and time-sensitive ones. The rest go to the history with a moon mark. The alternatives are “Show all notifications” and “Show none”.
- The Focus state is read from `~/Library/DoNotDisturb/DB` and requires Full Disk Access. A Focus turned on by hand is detected; one that starts on a schedule is not.

### Dashboard

The dashboard uses a 12 × 4 grid. You can adjust each card's position and size in settings, such as 4×4 or 6×2. Layouts saved by older versions are converted once.

- Claude and Codex usage: reads snapshots written by the collector scripts under `scripts/`; see `scripts/AI_USAGE.md` for installation. The Claude card switches between the App and CLI accounts: the App quota comes from the desktop app's own records, and the CLI quota is written by the Claude Code status line script after every turn, with no polling while no session runs. The sample time is shown under the title, and older data is labeled.
- Claude Code: reads `ai-token-stats.json` from the same folder and shows total tokens and a heat map of daily use over the last weeks.
- Storage: displays disk usage with a ring chart and text, spaced evenly within the card.
- Battery usage: ranks apps by the energy their processes have used since they started. The sandbox does not allow reading other processes, so the XPC helper does it, and only while the card is shown.
- System: shows CPU load, memory used (counted as Activity Monitor does), and network download and upload speed, sampled every 2 seconds only while the card is shown. Network speed counts only Wi-Fi and Ethernet interfaces, so VPN traffic is not counted twice.

All cards share the same card and gauge components. Content that does not fit a card's cells is clipped instead of covering the cards next to it.

### Mixer

The mixer provides per-app volume control similar to SoundSource, using Core Audio process taps.

- Adjust the volume of each app playing audio, with mute and solo controls.
- Adjust left/right balance or switch to mono.
- Choose an output device for each app.
- View live level meters, calculated only while the page is visible. With the mixer enabled and the page hidden, CPU usage is about 0.2%–0.3% of a single core.

When no apps are playing audio, a single-line message appears in the center of the page. On first use, follow the prompt to grant the system audio recording permission.

### Clipboard area

The Shelf tab includes a temporary clipboard area. Items are arranged vertically, with one line per item and an ellipsis for overflow. You can clear all items at once or disable the area in settings.

### Battery and charging alerts

- Low-battery alerts support multiple thresholds. The defaults are 20%, 10%, and 5%, selectable in settings. Alerts do not pop up repeatedly.
- Charging alerts use a centered, rounded panel. Disconnecting power triggers a single alert, and status text is available in Chinese.
- Battery line: an optional thin charge line under the closed notch, outside its outline so the hardware notch cannot hide it. While charging, a pulse sweeps along it from left to right; at 20% or less it glows red; a dark rim outside the line keeps it visible over light windows. Buttons in settings preview the low and charging looks.

### Music waveform

The new multicolor waveform option uses Core Animation for its looping animation, keeping CPU usage low. A slider controls the speed of the color changes; setting it to 0 keeps the colors still.

Audio levels are quantized to pixel steps before being published. FFT computation stops when no components are using the audio data.

## Fixes and improvements

- Notification handling on macOS 27: the system now places all banners in a full-screen window, which the previous height-based filter ignored. Detection now looks for banner elements and distinguishes live banners from entries in the Notification Center sidebar. Opening Notification Center no longer moves the wrong window or repeatedly displays notifications.
- Notification body updates: when two notifications arrived in succession, the second could replace the first icon placeholder, and the first notification's body would then be discarded as a duplicate. This is fixed.
- Gap below the notch: the macOS 27 menu bar is 1–2 pt taller than the notch. The notch height now follows the menu bar.
- OSD settings: added the missing page title so it no longer keeps the previous page's title.
- Calendar: the event list loads once when the notch opens. A skeleton view remains until the calendar data settles, and this waiting period is no longer cut short.
- Notification dismissal: fixed notifications staying open after automatic expansion because the pointer was incorrectly detected as hovering. The notification view also remains visible until the notch finishes closing.
- Helper startup: cleans up orphaned `log stream` processes left behind after a forced termination.
- Helper services: the helper's notification services restart after sleep, a dropped connection, or a stale banner watcher. The early signal ignores badge-only requests that carry no text.
- Closing the notch: the notch closes when the user dismisses a notification, even with the pointer over it. A notch opened by a file drag closes once the drag ends and the pointer is not on it.
- Energy: the charging pulse and the time-sensitive rainbow outline are played by Core Animation, so the main process stays nearly idle while they run. The mixer polls Core Audio only while its page is open or apps are re-routed; the notification database is read on file events with a slow fallback; the clipboard is checked once a second.
- Simplified Chinese: filled in most previously untranslated text. Custom features also have Chinese translations.

## Build and install

Requires macOS 15.6+ and Xcode 26+.

```bash
git clone https://github.com/1zumiii/BoringNotch-Custom.git
cd BoringNotch-Custom
git checkout custom-main
open boringNotch.xcodeproj
```

Open the project in Xcode and run it. To preserve Accessibility and Full Disk Access permissions across rebuilds, re-sign each build with a fixed code-signing requirement:

```bash
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Release \
  -derivedDataPath build CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO build

codesign --force --sign - --preserve-metadata=entitlements,flags,runtime \
  -r='designated => identifier "theboringteam.boringnotch"' \
  "build/Build/Products/Release/Boring Notch.app"
```

**Sign only the outer app bundle. Do not add `--deep`.** It breaks the XPC helper's signature and causes notification handling to report missing Accessibility permission.

## Permissions

| Permission | Used for |
| --- | --- |
| Accessibility | Reading system notification banners and moving them off-screen |
| Full Disk Access | Reading the notification database for notifications with banners disabled, source app previews, and time-sensitive notification detection; reading the Focus state |
| System audio recording | Controlling per-app volume and reading audio levels |
| Calendar, Reminders, Camera, and others | Existing upstream features |

## Where the custom code lives

| Location | Contents |
| --- | --- |
| `boringNotch/managers/SystemNotificationManager.swift` | Notification display, queue, placeholders, and priorities |
| `boringNotch/managers/NotificationDatabaseWatcher.swift` | Notification database reader |
| `boringNotch/managers/NotificationHistory.swift`, `components/Notch/NotificationHistoryView.swift` | Notification history and the Notifications tab |
| `boringNotch/managers/FocusStatusMonitor.swift` | Focus state reader |
| `BoringNotchXPCHelper/NotificationWatcher.swift`, `EarlyNotificationSource.swift` | Banner capture and early signals, running in the XPC helper |
| `boringNotch/components/Dashboard/`, `components/Usage/` | Dashboard and usage cards |
| `boringNotch/components/Mixer/`, `managers/AudioCaptureManager.swift` | Mixer and audio capture |
| `boringNotch/models/BatteryAlertTracker.swift` | Battery alerts |
| `boringNotch/components/Notch/NotchShape.swift` | Battery line and charging pulse |
| `boringNotch/CustomBuild.swift` | Disabling updates and setting the custom version |

## Credits and license

Thanks to [Boring Notch](https://github.com/TheBoredTeam/boring.notch) and its contributors, and to the authors of dependencies including [MediaRemoteAdapter](https://github.com/ungive/mediaremote-adapter) and [NotchDrop](https://github.com/Lakr233/NotchDrop). The icon is by [@maxtron95](https://github.com/maxtron95).

This fork keeps the upstream license. See [LICENSE](LICENSE) and [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES).
