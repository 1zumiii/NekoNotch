#!/usr/bin/env python3
"""Claude Code status line that also publishes the plan limits for the notch.

Claude Code runs this script after every assistant message, with the session
JSON on stdin. The `rate_limits` block (5-hour and 7-day usage, reset times)
is written to claude-cli-limits.json for the dashboard's Claude card, so the
card follows each turn while a session is active and nothing runs while no
session is. Only those percentages and times leave this process; the prompt,
the transcript path and the rest of the session data are not stored.

The printed line shows the model, context use and both limits.
"""
import json
import math
import os
import sys
import tempfile
import time
from pathlib import Path

OUTPUT = Path.home() / "Library/Application Support/NekoNotch/claude-cli-limits.json"


def number(value):
    return (isinstance(value, (int, float)) and not isinstance(value, bool)
            and math.isfinite(value))


def limits(session, now=None):
    """The file content for the notch, or None when the session has no limits yet."""
    rate_limits = session.get("rate_limits")
    if not isinstance(rate_limits, dict):
        return None
    windows = {}
    for key in ("five_hour", "seven_day"):
        window = rate_limits.get(key)
        if not isinstance(window, dict):
            continue
        used = window.get("used_percentage")
        if not number(used) or not 0 <= used <= 100:
            continue
        resets = window.get("resets_at")
        windows[key] = {"used": float(used), "resets_at": float(resets) if number(resets) else None}
    if not windows:
        return None
    return {"t": now if now is not None else time.time(), **windows}


def atomic_json(path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".statusline-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(payload, stream, indent=2)
            stream.write("\n")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def percent(value):
    return f"{value:.0f}%" if number(value) else "–"


def colored(text, used):
    if not number(used):
        return text
    code = "31" if used >= 90 else "33" if used >= 70 else "32"
    return f"\033[{code}m{text}\033[0m"


def status_text(session):
    parts = []
    context = (session.get("context_window") or {}).get("used_percentage")
    if number(context):
        parts.append(colored(f"ctx {percent(context)}", context))
    rate_limits = session.get("rate_limits") or {}
    for key, title in (("five_hour", "5h"), ("seven_day", "7d")):
        used = (rate_limits.get(key) or {}).get("used_percentage")
        if number(used):
            parts.append(colored(f"{title} {percent(used)}", used))
    model = (session.get("model") or {}).get("display_name")
    text = " · ".join(parts)
    return f"[{model}] {text}".strip() if model else text


def main():
    try:
        session = json.load(sys.stdin)
        if not isinstance(session, dict):
            session = {}
    except ValueError:
        session = {}
    try:
        payload = limits(session)
        if payload is not None:
            atomic_json(OUTPUT, payload)
    except OSError as error:
        print(f"claude-statusline: {error}", file=sys.stderr)
    print(status_text(session))


if __name__ == "__main__":
    main()
