#!/usr/bin/env python3
"""Install the local AI usage collector for the current macOS user.

Copies the scripts into ~/Library/Application Support/RunCatIntegrations (the
folder the sandboxed app may read), installs one LaunchAgent that runs the sync
every minute, registers claude-statusline.py as the Claude Code status line,
and retires the two earlier agents. Files the earlier integration left behind
are moved into a `legacy` subfolder rather than deleted.
"""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import time

home = Path.home()
root = home / "Library/Application Support/RunCatIntegrations"
root.mkdir(parents=True, exist_ok=True)
source = Path(__file__).resolve().parent
for name in ("ai-token-stats.py", "ai-usage-sync.py", "claude-statusline.py"):
    shutil.copy2(source / name, root / name)

domain = "gui/" + str(os.getuid())
agents = home / "Library/LaunchAgents"
agents.mkdir(parents=True, exist_ok=True)
for old in ("dev.izumi.runcat-app-sync", "dev.izumi.boringnotch-ai-token-stats"):
    subprocess.run(["launchctl", "bootout", domain + "/" + old], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    plist = agents / (old + ".plist")
    if plist.exists():
        plist.unlink()
        print(f"Removed LaunchAgent {old}.")

legacy = root / "legacy"
for name in ("runcat-app-sync.py", "runcat-app-sync.py.bak", "runcat-hook.py", "claude-usage.json",
             "sync-state.json", "claude-code-stats.json", "claude-code-tx-state.json", "sync.log",
             "sync-error.log", "ai-token-stats-error.log"):
    path = root / name
    if path.exists():
        legacy.mkdir(exist_ok=True)
        shutil.move(str(path), str(legacy / name))
        print(f"Moved {name} to legacy/.")

label = "dev.izumi.boringnotch-ai-usage"
agent = agents / (label + ".plist")
with agent.open("wb") as stream:
    plistlib.dump({"Label": label, "ProgramArguments": ["/usr/bin/python3", str(root / "ai-usage-sync.py")],
                  "RunAtLoad": True, "StartInterval": 60, "ProcessType": "Background",
                  "EnvironmentVariables": {"PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                                           "PYTHONDONTWRITEBYTECODE": "1"},
                  "StandardErrorPath": str(root / "ai-usage-error.log")}, stream)
subprocess.run(["launchctl", "bootout", domain + "/" + label], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
subprocess.run(["launchctl", "bootstrap", domain, str(agent)], check=True)
print(f"Installed LaunchAgent {label} (60-second refresh).")

# Status line: set when absent, or when it already points at this script.
settings_path = home / ".claude/settings.json"
command = f"/usr/bin/python3 '{root / 'claude-statusline.py'}'"
try:
    settings = json.loads(settings_path.read_text(encoding="utf-8")) if settings_path.exists() else {}
except ValueError as error:
    raise SystemExit(f"{settings_path} is not valid JSON ({error}); status line not configured.")
current = settings.get("statusLine") or {}
if not current or "claude-statusline.py" in str(current.get("command", "")):
    if current.get("command") != command or current.get("type") != "command":
        if settings_path.exists():
            shutil.copy2(settings_path, settings_path.with_name(f"settings.json.bak-{int(time.time())}"))
        settings["statusLine"] = {"type": "command", "command": command}
        settings_path.parent.mkdir(parents=True, exist_ok=True)
        settings_path.write_text(json.dumps(settings, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        print("Registered claude-statusline.py as the Claude Code status line.")
    else:
        print("Claude Code status line already registered.")
else:
    print(f"Claude Code already has a status line ({current.get('command')}); "
          f"to publish the limits, run `{command}` from it with the same stdin.")
