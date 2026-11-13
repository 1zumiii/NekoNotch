#!/usr/bin/env python3
"""Install the local AI usage collector for the current macOS user.

Copies the scripts into ~/Library/Application Support/NekoNotch (the folder the
sandboxed app may read), installs one LaunchAgent that runs the sync every
minute, registers claude-statusline.py as the Claude Code status line, and
retires the earlier agents.

Earlier versions used ~/Library/Application Support/RunCatIntegrations,
~/.codex/runcat-usage.json and the agent dev.izumi.boringnotch-ai-usage. Their
data moves to the new folder; a file that already exists there and is newer
is not overwritten, and the old copy stays where it was. Files the RunCat
integration left behind are moved into a `legacy` subfolder rather than
deleted. Running the installer again changes nothing.

The migration takes the home directory and the launchctl runner as arguments,
so the tests run it against a temporary home.
"""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import time

LABEL = "io.github.1zumiii.nekonotch.ai-usage"
OLD_LABELS = ("dev.izumi.runcat-app-sync", "dev.izumi.boringnotch-ai-token-stats",
              "dev.izumi.boringnotch-ai-usage")
ROOT = "Library/Application Support/NekoNotch"
OLD_ROOT = "Library/Application Support/RunCatIntegrations"
OLD_CODEX_OUTPUT = ".codex/runcat-usage.json"
SCRIPTS = ("ai-token-stats.py", "ai-usage-sync.py", "claude-statusline.py")
# What the collectors wrote into the old folder. The token cache holds the
# totals of transcripts that no longer exist, so it must not be lost.
DATA = ("ai-token-stats.json", "ai-token-cache.json", "ai-usage-state.json", "claude-app-quota.json",
        "claude-cli-limits.json", "ai-usage-error.log", "legacy")
# Leftovers of the RunCat integration, kept in `legacy`.
LEGACY = ("runcat-app-sync.py", "runcat-app-sync.py.bak", "runcat-hook.py", "claude-usage.json",
          "sync-state.json", "claude-code-stats.json", "claude-code-tx-state.json", "sync.log",
          "sync-error.log", "ai-token-stats-error.log")
# Temporary files of an interrupted atomic write, and other things safe to drop.
DISPOSABLE_PREFIXES = (".ai-usage-", ".ai-stats-", ".statusline-")
DISPOSABLE = (".DS_Store", "__pycache__")


def run_launchctl(*arguments, check=False):
    subprocess.run(["launchctl", *arguments], check=check,
                   stdout=None if check else subprocess.DEVNULL, stderr=None if check else subprocess.DEVNULL)


def move_to_legacy(root):
    legacy = root / "legacy"
    for name in LEGACY:
        path = root / name
        if path.exists():
            legacy.mkdir(exist_ok=True)
            shutil.move(str(path), str(legacy / name))
            print(f"Moved {name} to legacy/.")


def move_without_overwrite(source, target):
    """Moves source to target, folders file by file. A target that is at least
    as new as the source wins, and the source is then left in place."""
    if source.is_dir() and not source.is_symlink():
        target.mkdir(parents=True, exist_ok=True)
        for child in sorted(source.iterdir()):
            move_without_overwrite(child, target / child.name)
        if not any(source.iterdir()):
            source.rmdir()
        return
    if target.exists() and target.stat().st_mtime_ns >= source.stat().st_mtime_ns:
        print(f"Kept {target}; the older {source} was left in place.")
        return
    os.replace(source, target)


def migrate_old_root(old_root, root):
    if not old_root.is_dir():
        return
    move_to_legacy(old_root)
    for name in DATA:
        path = old_root / name
        if path.exists():
            move_without_overwrite(path, root / name)
    # The scripts are copied to the new folder afresh.
    for path in old_root.iterdir():
        if path.name in SCRIPTS or path.name in DISPOSABLE or path.name.startswith(DISPOSABLE_PREFIXES):
            shutil.rmtree(path) if path.is_dir() and not path.is_symlink() else path.unlink()
    remaining = sorted(path.name for path in old_root.iterdir())
    if remaining:
        print(f"Left {old_root} in place; it still holds {', '.join(remaining)}.")
    else:
        old_root.rmdir()
        print(f"Moved the collector data from {old_root} to {root}.")


def migrate_codex_output(old, new):
    if not old.exists():
        return
    if new.exists():
        old.unlink()
        print(f"Removed {old}; {new} is already in use.")
    else:
        shutil.move(str(old), str(new))
        print(f"Moved {old} to {new}.")


def retire_agents(agents, domain, launchctl):
    for old in OLD_LABELS:
        launchctl("bootout", domain + "/" + old)
        plist = agents / (old + ".plist")
        if plist.exists():
            plist.unlink()
            print(f"Removed LaunchAgent {old}.")


def install_agent(agents, domain, root, launchctl):
    agent = agents / (LABEL + ".plist")
    with agent.open("wb") as stream:
        plistlib.dump({"Label": LABEL, "ProgramArguments": ["/usr/bin/python3", str(root / "ai-usage-sync.py")],
                      "RunAtLoad": True, "StartInterval": 60, "ProcessType": "Background",
                      "EnvironmentVariables": {"PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                                               "PYTHONDONTWRITEBYTECODE": "1"},
                      "StandardErrorPath": str(root / "ai-usage-error.log")}, stream)
    launchctl("bootout", domain + "/" + LABEL)
    launchctl("bootstrap", domain, str(agent), check=True)
    print(f"Installed LaunchAgent {LABEL} (60-second refresh).")


def register_status_line(home, root):
    """Sets the status line when absent or when it runs this script. A command
    that names the old folder, however spelled, is pointed at the new one."""
    settings_path = home / ".claude/settings.json"
    command = f"/usr/bin/python3 '{root / 'claude-statusline.py'}'"
    # Without Claude Code (no ~/.claude), there is nothing to register with;
    # the other sources work without it.
    if not settings_path.parent.is_dir():
        print("Claude Code not found (~/.claude is missing); status line not configured.")
        return
    try:
        settings = json.loads(settings_path.read_text(encoding="utf-8")) if settings_path.exists() else {}
    except ValueError as error:
        raise SystemExit(f"{settings_path} is not valid JSON ({error}); status line not configured.")
    current = settings.get("statusLine") or {}
    current_command = str(current.get("command", ""))
    old_folder = "/" + Path(OLD_ROOT).name + "/"
    if old_folder in current_command:
        wanted = current_command.replace(old_folder, "/" + root.name + "/")
    elif not current or "claude-statusline.py" in current_command:
        wanted = command
    else:
        print(f"Claude Code already has a status line ({current.get('command')}); "
              f"to publish the limits, run `{command}` from it with the same stdin.")
        return
    if current.get("command") == wanted and current.get("type") == "command":
        print("Claude Code status line already registered.")
        return
    if settings_path.exists():
        shutil.copy2(settings_path, settings_path.with_name(f"settings.json.bak-{int(time.time())}"))
    settings["statusLine"] = {**current, "type": "command", "command": wanted}
    settings_path.write_text(json.dumps(settings, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print("Registered claude-statusline.py as the Claude Code status line.")


def main(home=None, launchctl=run_launchctl, source=None):
    home = Path(home or Path.home())
    source = Path(source or Path(__file__).resolve().parent)
    root = home / ROOT
    root.mkdir(parents=True, exist_ok=True)
    domain = "gui/" + str(os.getuid())
    agents = home / "Library/LaunchAgents"
    agents.mkdir(parents=True, exist_ok=True)

    # Stop the old agents first so nothing writes while the files move.
    retire_agents(agents, domain, launchctl)
    migrate_old_root(home / OLD_ROOT, root)
    migrate_codex_output(home / OLD_CODEX_OUTPUT, root / "codex-usage.json")
    move_to_legacy(root)
    for name in SCRIPTS:
        shutil.copy2(source / name, root / name)
    install_agent(agents, domain, root, launchctl)
    register_status_line(home, root)


if __name__ == "__main__":
    main()
