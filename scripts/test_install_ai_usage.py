import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("install_ai_usage", Path(__file__).with_name("install-ai-usage.py"))
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)

OLD = "Library/Application Support/RunCatIntegrations"
NEW = "Library/Application Support/NekoNotch"
OLD_LABEL = "dev.izumi.boringnotch-ai-usage"


def write(path, text, mtime=None):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    if mtime is not None:
        os.utime(path, (mtime, mtime))


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.home = Path(self.directory.name)
        self.calls = []

    def tearDown(self):
        self.directory.cleanup()

    def launchctl(self, *arguments, check=False):
        self.calls.append(arguments)

    def install(self):
        with contextlib.redirect_stdout(io.StringIO()):
            installer.main(self.home, launchctl=self.launchctl)

    def old_layout(self):
        old = self.home / OLD
        for name in installer.SCRIPTS:
            write(old / name, "old script")
        for name in ("ai-token-stats.json", "ai-token-cache.json", "ai-usage-state.json",
                     "claude-app-quota.json", "claude-cli-limits.json", "ai-usage-error.log"):
            write(old / name, "old " + name)
        write(old / "legacy/runcat-hook.py", "hook")
        write(old / "sync.log", "log")
        write(old / ".ai-usage-abc123", "partial")
        write(self.home / ".codex/runcat-usage.json", "codex")
        write(self.home / f"Library/LaunchAgents/{OLD_LABEL}.plist", "plist")
        command = f"/usr/bin/python3 '{old / 'claude-statusline.py'}'"
        write(self.home / ".claude/settings.json",
              json.dumps({"theme": "dark", "statusLine": {"type": "command", "command": command}}))

    def settings(self):
        return json.loads((self.home / ".claude/settings.json").read_text())

    def backups(self):
        return sorted((self.home / ".claude").glob("settings.json.bak-*"))

    def snapshot(self):
        return {str(path.relative_to(self.home)): path.read_bytes()
                for path in sorted(self.home.rglob("*")) if path.is_file()}

    def test_old_layout_moves_to_the_new_folder(self):
        self.old_layout()
        self.install()
        new = self.home / NEW
        self.assertFalse((self.home / OLD).exists())
        for name in ("ai-token-stats.json", "ai-token-cache.json", "ai-usage-state.json",
                     "claude-app-quota.json", "claude-cli-limits.json", "ai-usage-error.log"):
            self.assertEqual((new / name).read_text(), "old " + name)
        self.assertEqual((new / "legacy/runcat-hook.py").read_text(), "hook")
        self.assertEqual((new / "legacy/sync.log").read_text(), "log")
        for name in installer.SCRIPTS:
            self.assertNotEqual((new / name).read_text(), "old script")
        self.assertFalse((self.home / ".codex/runcat-usage.json").exists())
        self.assertEqual((new / "codex-usage.json").read_text(), "codex")

        agents = self.home / "Library/LaunchAgents"
        self.assertFalse((agents / f"{OLD_LABEL}.plist").exists())
        with (agents / "io.github.1zumiii.nekonotch.ai-usage.plist").open("rb") as stream:
            agent = plistlib.load(stream)
        self.assertEqual(agent["Label"], "io.github.1zumiii.nekonotch.ai-usage")
        self.assertEqual(agent["ProgramArguments"][1], str(new / "ai-usage-sync.py"))
        domain = "gui/" + str(os.getuid())
        self.assertIn(("bootout", f"{domain}/{OLD_LABEL}"), self.calls)
        self.assertEqual(self.calls[-1][0], "bootstrap")

        settings = self.settings()
        self.assertEqual(settings["theme"], "dark")
        self.assertEqual(settings["statusLine"],
                         {"type": "command", "command": f"/usr/bin/python3 '{new / 'claude-statusline.py'}'"})
        self.assertEqual(len(self.backups()), 1)

    def test_running_twice_changes_nothing(self):
        self.old_layout()
        self.install()
        before = self.snapshot()
        self.install()
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(len(self.backups()), 1)

    def test_newer_files_in_the_new_folder_are_not_overwritten(self):
        self.old_layout()
        old, new = self.home / OLD, self.home / NEW
        write(old / "claude-cli-limits.json", "old limits", mtime=1_000_000)
        write(new / "claude-cli-limits.json", "new limits", mtime=2_000_000)
        write(old / "ai-token-cache.json", "newer cache", mtime=3_000_000)
        write(new / "ai-token-cache.json", "older cache", mtime=1_000_000)
        write(new / "codex-usage.json", "new codex")
        self.install()
        self.assertEqual((new / "claude-cli-limits.json").read_text(), "new limits")
        self.assertEqual((new / "ai-token-cache.json").read_text(), "newer cache")
        self.assertEqual((new / "codex-usage.json").read_text(), "new codex")
        self.assertFalse((self.home / ".codex/runcat-usage.json").exists())
        # The older copy is not deleted, so the old folder stays.
        self.assertEqual(sorted(path.name for path in old.iterdir()), ["claude-cli-limits.json"])
        self.install()
        self.assertEqual((new / "claude-cli-limits.json").read_text(), "new limits")
        self.assertTrue((old / "claude-cli-limits.json").exists())

    def test_unknown_files_keep_the_old_folder(self):
        self.old_layout()
        write(self.home / OLD / "notes.txt", "mine")
        self.install()
        old = self.home / OLD
        self.assertEqual(sorted(path.name for path in old.iterdir()), ["notes.txt"])
        self.assertTrue((self.home / NEW / "ai-token-cache.json").exists())

    def test_a_status_line_wrapper_keeps_its_command(self):
        command = "sh -c 'python3 ~/Library/Application\\ Support/RunCatIntegrations/claude-statusline.py | cat'"
        write(self.home / ".claude/settings.json",
              json.dumps({"statusLine": {"type": "command", "command": command, "padding": 0}}))
        self.install()
        self.assertEqual(self.settings()["statusLine"], {
            "type": "command", "padding": 0,
            "command": "sh -c 'python3 ~/Library/Application\\ Support/NekoNotch/claude-statusline.py | cat'"})

    def test_an_unrelated_status_line_is_left_alone(self):
        settings = {"statusLine": {"type": "command", "command": "my-status-line"}}
        write(self.home / ".claude/settings.json", json.dumps(settings))
        self.install()
        self.assertEqual(self.settings(), settings)
        self.assertEqual(self.backups(), [])

    def test_without_claude_code_no_settings_are_created(self):
        self.install()
        self.assertFalse((self.home / ".claude").exists())
        self.assertTrue((self.home / NEW / "ai-usage-sync.py").exists())


if __name__ == "__main__":
    unittest.main()
