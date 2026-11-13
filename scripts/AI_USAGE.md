# Local AI usage for the dashboard

Run `python3 scripts/install-ai-usage.py` on macOS. It copies the three scripts
into `~/Library/Application Support/NekoNotch` (the folder the sandboxed app is
allowed to read), installs one LaunchAgent, `io.github.1zumiii.nekonotch.ai-usage`,
that runs `ai-usage-sync.py` every 60 seconds, and registers `claude-statusline.py`
as the Claude Code status line in `~/.claude/settings.json` (a backup of the file
is kept beside it). Without Claude Code, the status line is skipped. Each source
is optional: a missing Claude App, Claude Code or Codex leaves its card empty
and does not stop the others. Re-run the installer after changing a script; a
second run changes nothing. Compressed Codex transcripts require `zstd` on PATH
or at `/opt/homebrew/bin/zstd`.

Nothing here reads credentials. The folder name is fixed by the app's sandbox
entitlement, which allows reading only this folder.

## Updating from an earlier installation

Earlier versions used `~/Library/Application Support/RunCatIntegrations`,
`~/.codex/runcat-usage.json` and the LaunchAgent `dev.izumi.boringnotch-ai-usage`.
The app now reads only the new locations, so if you installed the collector
before, run the installer again after you update the app. The installer:

- stops and deletes the old LaunchAgent, and the two agents before it;
- moves the outputs, the token cache and the `legacy` subfolder into the new
  folder. A file that already exists there and is newer is kept, and the old
  copy stays where it was. The old folder is deleted when it is empty and
  otherwise left in place;
- moves `~/.codex/runcat-usage.json` to `codex-usage.json` in the new folder,
  or deletes it if that file already exists;
- points a status line command that names the old folder at the new one.

The token cache keeps the totals of deleted transcripts, so it is moved, never
rebuilt. Files of the earlier RunCat integration are moved into the `legacy`
subfolder.

## Files the app reads

| File | Written by | Card |
| --- | --- | --- |
| `claude-app-quota.json` | `ai-usage-sync.py`, from the desktop app's own `~/Library/Application Support/Claude/plan-usage-history.json` | Claude, App |
| `claude-cli-limits.json` | `claude-statusline.py` after every turn of a Claude Code session; `ai-usage-sync.py` as a fallback | Claude, CLI |
| `codex-usage.json` | `ai-usage-sync.py`, from the newest main Codex session | Codex |
| `ai-token-stats.json` | `ai-usage-sync.py`, through `ai-token-stats.collect` | AI Tokens (Claude and Codex) |

## Active and idle periods

Claude Code runs the status line script after each assistant message, with the
session JSON on stdin. The script writes the `rate_limits` block (5-hour and
7-day usage, reset times) to `claude-cli-limits.json` and prints the model,
context use and both limits for the terminal. While a session is active the
CLI card therefore follows the conversation. Between sessions, the collector
can still perform the fallback refresh described below.
`rate_limits` appears only for claude.ai subscribers and only after the first
API response of a session, so the file is left alone until then.

The sync script asks `claude -p --no-session-persistence /stats` itself only
when the limits file is missing or its sample is older than 30 minutes
(`CLI_FALLBACK_SECONDS`), which covers usage from other machines while no local
session runs. A failed attempt is not retried for the same interval.

The App quota changes only when the desktop app writes a new sample; the
export keeps the sample's own time. The Codex card is rebuilt only when the
newest session transcript changes. Token statistics are recomputed only when a
transcript's size or modification time changed since the last run or the UTC
day changed; otherwise the previous result stands and the cache is not parsed.

## Claude quota card

The Claude card has a persistent App / CLI selector, stored in
`claudeQuotaClient`. The accounts are read separately and a missing sample never
selects the other account. A sample older than 15 minutes, or a CLI sample whose
reset time has passed, is labeled as older data; its percentage is retained
rather than replaced by a zero. Hovering shows the selected client and sample time.

Decoder checks, from the repository root:

```sh
swiftc boringNotch/components/Usage/UsageStore.swift scripts/test-claude-quota.swift -o /tmp/test-claude-quota
/tmp/test-claude-quota
```

## Token statistics

- Claude combines App and CLI records under `~/.claude/projects`. Repeated
  streaming blocks and copied messages are deduplicated by request/message ID.
  Input, output, cache reads and cache writes are included. Ordinary Claude chats
  without local token records are excluded; quota percentages are not tokens.
- Codex combines `~/.codex/sessions` and `~/.codex/archived_sessions`, including
  `.jsonl.zst` files. Cumulative counter deltas exclude duplicate events. The
  first event uses its last-request count to avoid counting inherited counters.
  Cache and reasoning counts are already included in `total_tokens`.
- Dates use UTC. The last-seven-days figure includes today and the six preceding
  dates. Totals cover local transcripts, not account-wide billing history.
- Claude Code deletes transcripts after its retention period (30 days by
  default), and Codex moves or compresses old ones. The cache keeps the records
  of a vanished transcript, so the totals never go backwards; a moved copy is
  deduplicated. The cache stores hashed request identities, dates and token
  counts only, plus each Claude transcript's undeduplicated tokens per UTC day
  and model.
- Usage from Claude transcripts deleted before the cache was in place is
  estimated from Claude Code's `~/.claude/stats-cache.json`, which keeps daily
  tokens per model by UTC day but counts every streamed line of a request.
  Where it holds more than the known transcripts counted the same way, the
  difference is scaled by the overall deduplicated-to-undeduplicated ratio and
  added to that day. The card's tooltip shows how much of the total is
  estimated. Deleted Codex sessions are not recovered.

Orange denotes Claude and violet denotes Codex. Mixed days blend their colors
in proportion to the two token counts. Hover over the card for provider totals,
scope, refresh time and read errors.

## Checks and removal

```sh
python3 -m unittest discover -s scripts -p 'test_*.py'
```

To remove the collector, run
`launchctl bootout gui/$(id -u)/io.github.1zumiii.nekonotch.ai-usage`, delete its
plist from `~/Library/LaunchAgents`, and remove the `statusLine` entry from
`~/.claude/settings.json`. The collected data is in
`~/Library/Application Support/NekoNotch`.
