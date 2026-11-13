#!/usr/bin/env python3
"""Refreshes the local AI usage files the notch dashboard reads.

A LaunchAgent runs it once a minute. Each run is cheap when nothing changed:
every source is compared by file signature before anything is parsed.

- Claude App quota: the latest sample of the desktop app's own history, exported
  into the folder the sandboxed app may read (claude-app-quota.json).
- Claude CLI limits: normally written by claude-statusline.py after every turn
  of a Claude Code session, so they follow the conversation. This script only
  asks `claude -p /stats` itself when that file is missing or older than
  CLI_FALLBACK_SECONDS, which covers usage from other machines while no local
  session runs.
- Codex: the last token count and rate limits of the newest main session,
  written to codex-usage.json beside the other outputs.
- Token statistics: ai-token-stats.collect, for the Claude Code card.

Nothing here reads credentials; the CLI signs in by itself.
"""
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parent
HOME = Path.home()
STATE = ROOT / "ai-usage-state.json"
CODEX_OUTPUT = ROOT / "codex-usage.json"
CLI_LIMITS = ROOT / "claude-cli-limits.json"
APP_QUOTA = ROOT / "claude-app-quota.json"
TOKEN_STATS = ROOT / "ai-token-stats.json"
CLI_FALLBACK_SECONDS = 30 * 60

MONTHS = {m: i for i, m in enumerate(
    ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"], 1)}
LIVE_LINE = re.compile(r"^Current (session|week)(?: \(([^)]*)\))?: (\d+(?:\.\d+)?)% used(?: · resets (.+))?$")
RESET = re.compile(r"(?:(\w{3}) (\d{1,2}) at )?(\d{1,2})(?::(\d{2}))?\s*(am|pm)(?: \(([^)]+)\))?", re.I)


def atomic_json(path, payload, indent=2):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".ai-usage-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(payload, stream, ensure_ascii=False, indent=indent)
            stream.write("\n")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def signature(path):
    stat = path.stat()
    return [str(path), stat.st_mtime_ns, stat.st_size]


def load_stats_module():
    spec = importlib.util.spec_from_file_location("ai_token_stats", ROOT / "ai-token-stats.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# MARK: Claude CLI fallback

def parse_reset(text, now=None):
    """Epoch seconds for text like 'Oct 20 at 2am (Australia/Sydney)', or None."""
    match = RESET.search(text or "")
    if not match:
        return None
    month, day, hour, minute, meridiem, zone = match.groups()
    try:
        tz = ZoneInfo(zone) if zone else datetime.now().astimezone().tzinfo
    except Exception:
        return None
    now = (now or datetime.now(timezone.utc)).astimezone(tz)
    hour = int(hour) % 12 + (12 if meridiem.lower() == "pm" else 0)
    moment = now.replace(hour=hour, minute=int(minute or 0), second=0, microsecond=0)
    if month and day:
        number = MONTHS.get(month.lower())
        if number is None:
            return None
        moment = moment.replace(month=number, day=int(day))
        if moment < now - timedelta(days=30):
            moment = moment.replace(year=moment.year + 1)
    elif moment <= now:
        moment += timedelta(days=1)
    return moment.timestamp()


def parse_stats(stdout, now=None):
    """The limits file content from the text `claude -p /stats` prints, or None."""
    windows = {}
    for line in stdout.splitlines():
        match = LIVE_LINE.match(line.strip())
        if not match:
            continue
        kind, qualifier, used, resets = match.groups()
        key = "five_hour" if kind == "session" else ("seven_day" if (qualifier or "").lower().startswith("all") else None)
        if key and key not in windows:
            windows[key] = {"used": float(used), "resets_at": parse_reset(resets, now)}
    if not windows:
        return None
    return {"t": time.time(), **windows}


def fetch_cli_limits():
    binary = shutil.which("claude") or str(HOME / ".local/bin/claude")
    if not os.path.exists(binary):
        return None
    result = subprocess.run(
        [binary, "-p", "--no-session-persistence", "/stats"],
        capture_output=True, text=True, timeout=45, cwd=str(ROOT),
        env={**os.environ, "NO_COLOR": "1",
             "PATH": f"{HOME}/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"},
    )
    return parse_stats(result.stdout)


def cli_limits_age(now=None):
    """Seconds since the limits file was written, by its own sample time."""
    try:
        sample = json.loads(CLI_LIMITS.read_text(encoding="utf-8")).get("t")
    except (OSError, ValueError, AttributeError):
        return None
    if not isinstance(sample, (int, float)):
        return None
    return (now if now is not None else time.time()) - sample


def sync_cli_limits(state, now=None, fetch=fetch_cli_limits):
    now = now if now is not None else time.time()
    age = cli_limits_age(now)
    if age is not None and age < CLI_FALLBACK_SECONDS:
        return False
    # The attempt time is remembered so a failing CLI is not retried every minute.
    if now - state.get("cliFallbackAt", 0) < CLI_FALLBACK_SECONDS:
        return False
    state["cliFallbackAt"] = now
    limits = fetch()
    if limits is None:
        return False
    atomic_json(CLI_LIMITS, limits)
    return True


# MARK: Codex

def codex_session():
    candidates = []
    for path in (HOME / ".codex/sessions").glob("*/*/*/*.jsonl"):
        try:
            candidates.append((path.stat().st_mtime_ns, path))
        except OSError:
            continue
    for _, path in sorted(candidates, reverse=True)[:30]:
        try:
            with path.open(encoding="utf-8") as stream:
                event = json.loads(stream.readline())
            if event.get("type") != "session_meta":
                continue
            # Subagents have independent contexts; the main chat stays on the card.
            source = event.get("payload", {}).get("source")
            if isinstance(source, dict) and "subagent" in source:
                continue
            return path
        except (OSError, ValueError):
            continue
    return None


def percentage_metric(title, used):
    if not isinstance(used, (int, float)) or isinstance(used, bool):
        return None
    clamped = max(0.0, min(float(used), 100.0))
    formatted = f"{clamped:.1f}".rstrip("0").rstrip(".")
    return {"title": title, "formattedValue": f"{formatted}%", "normalizedValue": round(clamped / 100, 4)}


def window_title(minutes):
    if not isinstance(minutes, (int, float)) or isinstance(minutes, bool):
        return None
    if minutes % 1440 == 0:
        return f"{minutes / 1440:g}d"
    if minutes % 60 == 0:
        return f"{minutes / 60:g}h"
    return f"{minutes:g}m"


def codex_snapshot(lines):
    """The Codex card content from a transcript's lines, or None without a token count."""
    model = "Codex"
    token_count = None
    for line in lines:
        try:
            event = json.loads(line)
        except (ValueError, TypeError):
            continue
        payload = event.get("payload") or {}
        if event.get("type") == "turn_context":
            model = payload.get("model") or model
        elif payload.get("type") == "token_count":
            token_count = payload
    if token_count is None:
        return None
    metrics = [{"title": "Model", "formattedValue": model}]
    info = token_count.get("info") or {}
    used = (info.get("last_token_usage") or {}).get("total_tokens")
    window = info.get("model_context_window")
    context = None
    if isinstance(used, (int, float)) and isinstance(window, (int, float)) and window > 0:
        context = percentage_metric("Context", used / window * 100)
        metrics.append(context)
    titles = set()
    for key in ("primary", "secondary"):
        limit = (token_count.get("rate_limits") or {}).get(key) or {}
        title = window_title(limit.get("window_minutes"))
        metric = percentage_metric(title, limit.get("used_percent")) if title else None
        if metric is not None and title not in titles:
            metrics.append(metric)
            titles.add(title)
    snapshot = {"title": "Codex", "symbol": "camera.aperture", "metrics": metrics,
                "lastUpdatedDate": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
    if context is not None:
        snapshot["metricsBarValue"] = context["formattedValue"]
    return snapshot


def sync_codex(state):
    transcript = codex_session()
    if transcript is None:
        return
    current = signature(transcript)
    if state.get("codex") == current and CODEX_OUTPUT.exists():
        return
    with transcript.open(encoding="utf-8") as stream:
        snapshot = codex_snapshot(stream)
    if snapshot is not None:
        atomic_json(CODEX_OUTPUT, snapshot, indent=None)
    state["codex"] = current


# MARK: Main

def main():
    try:
        state = json.loads(STATE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        state = {}
    previous = dict(state)
    stats = load_stats_module()
    jobs = (
        ("Claude App quota", lambda: stats.export_app_quota(HOME, APP_QUOTA)),
        ("Claude CLI limits", lambda: sync_cli_limits(state)),
        ("Codex", lambda: sync_codex(state)),
        ("token stats", lambda: stats.collect(HOME, TOKEN_STATS)),
    )
    for name, job in jobs:
        try:
            job()
        except Exception as error:
            print(f"ai-usage-sync {name}: {error}", file=sys.stderr)
    if state != previous:
        atomic_json(STATE, state)


if __name__ == "__main__":
    main()
