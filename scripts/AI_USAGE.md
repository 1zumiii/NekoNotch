# Local AI usage for the dashboard

Run `python3 scripts/install-ai-usage.py` on macOS. It copies the three scripts
into `~/Library/Application Support/RunCatIntegrations` (the folder the sandboxed
app is allowed to read), installs one LaunchAgent, `dev.izumi.boringnotch-ai-usage`,
that runs `ai-usage-sync.py` every 60 seconds, and registers `claude-statusline.py`
as the Claude Code status line in `~/.claude/settings.json` (a backup of the file
is kept beside it). The two earlier agents are removed and the files of the
earlier RunCat integration are moved into a `legacy` subfolder. Re-run the
installer after changing a script. Compressed Codex transcripts require `zstd`
on PATH or at `/opt/homebrew/bin/zstd`.

Nothing here reads credentials. The folder name is kept because the app's
sandbox entitlement names it.

## Files the app reads

| File | Written by | Card |
| --- | --- | --- |
| `claude-app-quota.json` | `ai-usage-sync.py`, from the desktop app's own `~/Library/Application Support/Claude/plan-usage-history.json` | Claude, App |
| `claude-cli-limits.json` | `claude-statusline.py` after every turn of a Claude Code session; `ai-usage-sync.py` as a fallback | Claude, CLI |
| `~/.codex/runcat-usage.json` | `ai-usage-sync.py`, from the newest main Codex session | Codex |
| `ai-token-stats.json` | `ai-usage-sync.py`, through `ai-token-stats.collect` | Claude Code tokens |

## Active and idle periods

Claude Code runs the status line script after each assistant message, with the
session JSON on stdin. The script writes the `rate_limits` block (5-hour and
7-day usage, reset times) to `claude-cli-limits.json` and prints the model,
context use and both limits for the terminal. While a session is active the
CLI card therefore follows the conversation; while none is, nothing runs.
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
  dates. Totals cover available transcripts, not account-wide billing history.
  Removing transcripts removes their usage on the next refresh. The adjacent
  cache stores hashed request identities, dates and token counts only.

Orange denotes Claude and violet denotes Codex. Mixed days blend their colors
in proportion to the two token counts. Hover over the card for provider totals,
scope, refresh time and read errors.

## Checks and removal

```sh
python3 -m unittest discover -s scripts -p 'test_*.py'
```

To remove the collector, run
`launchctl bootout gui/$(id -u)/dev.izumi.boringnotch-ai-usage`, delete its
plist from `~/Library/LaunchAgents`, and remove the `statusLine` entry from
`~/.claude/settings.json`.
