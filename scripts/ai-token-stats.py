#!/usr/bin/env python3
"""Local transcript usage only. Never reads credentials or sends network requests.

Run by ai-usage-sync.py once a minute. The cache contains only usage
metadata, never prompts or responses, and keeps the records of transcripts that
have since been deleted. Calendar days are UTC. Usage of Claude Code sessions
deleted before the cache existed is estimated from Claude Code's own
~/.claude/stats-cache.json, see backfill().
"""
import hashlib
import json
import math
from collections import Counter
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from datetime import datetime, timedelta, timezone

SOURCES = ("codex", "claude")
TOKEN_KEYS = ("input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens")


def number(value):
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and value >= 0 else 0


def day_key(stamp):
    try:
        return datetime.fromisoformat(stamp.replace("Z", "+00:00")).astimezone(timezone.utc).date().isoformat()
    except (ValueError, TypeError, AttributeError):
        return None


def parse_lines(lines, kind, raw=None):
    """Deduplicated usage records. For Claude, `raw` (a Counter) also receives
    every line's tokens without deduplication, by "day|model": the way Claude
    Code's stats-cache.json counts them, so the two can be compared."""
    records = {}
    previous = None
    for line in lines:
        if b'"usage"' not in line and b'"token_count"' not in line:
            continue
        try:
            event = json.loads(line)
        except (ValueError, UnicodeDecodeError):
            continue
        stamp = event.get("timestamp")
        day = day_key(stamp)
        if not day:
            continue
        if kind == "codex":
            payload = event.get("payload") or {}
            if event.get("type") != "event_msg" or payload.get("type") != "token_count":
                continue
            info = payload.get("info") or {}
            total = info.get("total_token_usage") or {}
            last = info.get("last_token_usage") or {}
            if "total_tokens" not in total or "total_tokens" not in last:
                continue
            current = number(total["total_tokens"])
            # The first event can inherit counters from a resumed/forked chat.
            # Cache/reasoning tokens are already included in total_tokens.
            tokens = number(last["total_tokens"]) if previous is None or current < previous else current - previous
            previous = current
            if not tokens:
                continue
            identity = json.dumps([stamp, total, last], sort_keys=True)
            source = "codex"
        else:
            if event.get("type") != "assistant":
                continue
            message = event.get("message") or {}
            usage = message.get("usage")
            if not isinstance(usage, dict) or not message.get("id"):
                continue
            source = "claude"
            tokens = sum(number(usage.get(k)) for k in TOKEN_KEYS)
            if raw is not None and tokens:
                raw[f"{day}|{message.get('model')}"] += tokens
            identity = str(event.get("requestId", "")) + ":" + message["id"]
        key = hashlib.sha256(identity.encode()).hexdigest()
        old = records.get(key)
        # Streaming blocks repeat the same request; retain the largest snapshot.
        if old is None or tokens > old[2]:
            records[key] = [source, day, tokens]
    return records


def read_records(path, kind):
    """Returns (records, raw); raw is empty for Codex."""
    raw = Counter()
    if path.suffix == ".zst":
        binary = shutil.which("zstd") or "/opt/homebrew/bin/zstd"
        with subprocess.Popen([binary, "-dc", str(path)], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL) as process:
            records = parse_lines(process.stdout, kind, raw)
            if process.wait() != 0:
                raise OSError("Unable to decompress transcript")
            return records, dict(raw)
    with path.open("rb") as stream:
        return parse_lines(stream, kind, raw), dict(raw)


def backfill(history, files, unique, today):
    """Estimated Claude tokens per UTC day for sessions whose transcripts are
    gone and were never cached.

    stats-cache.json keeps Claude Code's daily tokens per model, by UTC day,
    summing every transcript line without deduplicating streamed blocks.
    Wherever it holds more than the transcripts we know of (counted the same
    way), the difference is usage of deleted sessions; it is scaled by our
    overall deduplicated/raw ratio to match the rest of the numbers."""
    rows = history.get("dailyModelTokens") if isinstance(history, dict) else None
    if not isinstance(rows, list):
        return {}
    known = Counter()
    for entry in files.values():
        known.update(entry.get("raw") or {})
    deduplicated = sum(v[2] for v in unique.values() if v[0] == "claude")
    counted = sum(known.values())
    if not counted:
        return {}
    ratio = min(1, deduplicated / counted)
    estimates = {}
    for row in rows:
        if not isinstance(row, dict) or not isinstance(row.get("date"), str) or row["date"] > today:
            continue
        models = row.get("tokensByModel")
        if not isinstance(models, dict):
            continue
        day = row["date"]
        missing = sum(max(0, number(t) - known.get(f"{day}|{model}", 0)) for model, t in models.items())
        if missing:
            estimates[day] = round(missing * ratio)
    return estimates


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(dir=path.parent, prefix=".ai-stats-")
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, separators=(",", ":"))
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def export_app_quota(home, output):
    """Export only the latest App quota sample into the sandbox-readable folder."""
    try:
        history = json.loads((home / "Library/Application Support/Claude/plan-usage-history.json").read_text())
        version = history.get("version")
        if version not in (1, 2):
            return
        samples = [s for s in history.get("samples", []) if isinstance(s, dict)
                   and isinstance(s.get("t"), (int, float)) and not isinstance(s["t"], bool)
                   and math.isfinite(s["t"])]
        if not samples:
            return
        latest = max(samples, key=lambda s: s["t"])
        usage = latest.get("u", {}) if version == 2 else latest
        values = {k: usage[k] for k in ("fh", "sd") if isinstance(usage.get(k), (int, float))
                  and not isinstance(usage[k], bool) and math.isfinite(usage[k]) and 0 <= usage[k] <= 100}
        if not values:
            return
        snapshot = {"version": 2, "samples": [{"t": latest["t"], "u": values}]}
    except (OSError, ValueError, TypeError, AttributeError):
        return
    try:
        if json.loads(output.read_text()) == snapshot:
            return
    except (OSError, ValueError):
        pass
    atomic_json(output, snapshot)


def collect(home, output, now=None):
    now = now or datetime.now(timezone.utc)
    cache_path = output.parent / "ai-token-cache.json"
    roots = [(home / ".codex/sessions", "codex"), (home / ".codex/archived_sessions", "codex"),
             (home / ".claude/projects", "claude")]
    signatures = {}
    for root, kind in roots:
        for path in root.rglob("*.jsonl*"):
            if path.name.endswith(".jsonl") or path.name.endswith(".jsonl.zst"):
                try:
                    stat = path.stat()
                    signatures[str(path)] = ([stat.st_size, stat.st_mtime_ns], kind)
                except OSError:
                    signatures[str(path)] = (None, kind)
    # Unchanged transcripts on the same UTC day: the previous result stands,
    # and the cache is not even parsed.
    history_path = home / ".claude/stats-cache.json"
    try:
        stat = history_path.stat()
        history_signature = [stat.st_size, stat.st_mtime_ns]
    except OSError:
        history_signature = None
    digest = hashlib.sha256(json.dumps([sorted((p, s) for p, (s, _) in signatures.items()),
                                        history_signature]).encode()).hexdigest()
    try:
        previous = json.loads(output.read_text())
        if previous.get("sourceDigest") == digest and previous.get("updated", "")[:10] == now.date().isoformat():
            return previous
    except (OSError, ValueError, AttributeError):
        pass
    try:
        cache = json.loads(cache_path.read_text())
    except (OSError, ValueError):
        cache = {}
    files = {}
    errors = 0
    for name, (signature, kind) in signatures.items():
        try:
            if signature is None:
                raise OSError("unreadable")
            old = cache.get(name, {})
            if old.get("signature") == signature and "raw" in old:
                files[name] = old
            else:
                records, raw = read_records(Path(name), kind)
                files[name] = {"signature": signature, "records": records, "raw": raw}
        except (OSError, ValueError):
            errors += 1
            if name in cache:
                files[name] = cache[name]
    # Claude Code deletes transcripts after its retention period, and Codex
    # moves or compresses them. Records of a vanished file stay in the cache,
    # so the totals never go backwards; a moved copy is deduplicated below.
    for name, entry in cache.items():
        if name not in files:
            files[name] = {**entry, "signature": None, "gone": True}
    unique = {}
    for entry in files.values():
        for key, value in entry["records"].items():
            if key not in unique or value[2] > unique[key][2]:
                unique[key] = value
    days = {}
    totals = dict.fromkeys(SOURCES, 0)
    for source, day, tokens in unique.values():
        if day > now.date().isoformat():
            continue
        totals[source] += tokens
        daily = days.setdefault(day, dict.fromkeys(SOURCES, 0))
        daily[source] += tokens
    try:
        history = json.loads(history_path.read_text())
    except (OSError, ValueError):
        history = None
    estimates = backfill(history, files, unique, now.date().isoformat())
    for day, tokens in estimates.items():
        totals["claude"] += tokens
        days.setdefault(day, dict.fromkeys(SOURCES, 0))["claude"] += tokens
    cutoff = (now.date() - timedelta(days=6)).isoformat()
    snapshot = {"total": sum(totals.values()), "last7": sum(sum(v.values()) for d, v in days.items() if d >= cutoff),
                "days": days, "totals": totals, "estimated": sum(estimates.values()),
                "updated": now.isoformat(), "readErrors": errors, "sourceDigest": digest}
    if files != cache:
        atomic_json(cache_path, files)
    atomic_json(output, snapshot)
    return snapshot


if __name__ == "__main__":
    home = Path.home()
    export_app_quota(home, home / "Library/Application Support/NekoNotch/claude-app-quota.json")
    collect(home, home / "Library/Application Support/NekoNotch/ai-token-stats.json")
