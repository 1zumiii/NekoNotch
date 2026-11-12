import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from datetime import datetime, timezone


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), Path(__file__).with_name(name))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


sync = load("ai-usage-sync.py")
statusline = load("claude-statusline.py")

SESSION = {"model": {"display_name": "Fable 5.1"}, "context_window": {"used_percentage": 34.2},
           "rate_limits": {"five_hour": {"used_percentage": 5, "resets_at": 1794514800},
                           "seven_day": {"used_percentage": 22.5, "resets_at": 1794801540}}}


class StatusLineTests(unittest.TestCase):
    def test_limits_follow_the_session_and_keep_the_notch_format(self):
        self.assertEqual(statusline.limits(SESSION, now=1000), {
            "t": 1000, "five_hour": {"used": 5.0, "resets_at": 1794514800.0},
            "seven_day": {"used": 22.5, "resets_at": 1794801540.0}})

    def test_sessions_without_limits_write_nothing(self):
        self.assertIsNone(statusline.limits({}))
        self.assertIsNone(statusline.limits({"rate_limits": {"five_hour": {"used_percentage": "5"}}}))
        self.assertIsNone(statusline.limits({"rate_limits": {"five_hour": {"used_percentage": True}}}))
        self.assertIsNone(statusline.limits({"rate_limits": {"five_hour": {"used_percentage": 101}}}))

    def test_a_window_without_reset_time_is_still_reported(self):
        limits = statusline.limits({"rate_limits": {"seven_day": {"used_percentage": 40}}}, now=1)
        self.assertEqual(limits, {"t": 1, "seven_day": {"used": 40.0, "resets_at": None}})

    def test_text_shows_model_context_and_limits(self):
        text = statusline.status_text(SESSION)
        self.assertTrue(text.startswith("[Fable 5.1] "))
        for part in ("ctx 34%", "5h 5%", "7d 22%"):
            self.assertIn(part, text)
        self.assertEqual(statusline.status_text({}), "")


class CliFallbackTests(unittest.TestCase):
    def test_stats_output_parses_both_windows(self):
        now = datetime(2026, 11, 12, 12, 0, tzinfo=timezone.utc)
        text = ("Current session: 35% used · resets 2pm (UTC)\n"
                "Current week (all models): 67.5% used · resets Nov 19 at 1am (UTC)\n"
                "Current week (Opus): 10% used\n")
        limits = sync.parse_stats(text, now)
        self.assertEqual(limits["five_hour"], {"used": 35.0, "resets_at": datetime(2026, 11, 12, 14, tzinfo=timezone.utc).timestamp()})
        self.assertEqual(limits["seven_day"], {"used": 67.5, "resets_at": datetime(2026, 11, 19, 1, tzinfo=timezone.utc).timestamp()})
        self.assertIsNone(sync.parse_stats("nothing here"))

    def test_fallback_runs_only_for_a_missing_or_old_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            sync.CLI_LIMITS = Path(temporary) / "claude-cli-limits.json"
            calls = []

            def fetch():
                calls.append(1)
                return {"t": 5000, "five_hour": {"used": 1.0, "resets_at": None}}

            state = {}
            self.assertTrue(sync.sync_cli_limits(state, now=5000, fetch=fetch))
            self.assertEqual(json.loads(sync.CLI_LIMITS.read_text())["t"], 5000)
            # Fresh from the status line: no spawn.
            sync.CLI_LIMITS.write_text(json.dumps({"t": 6000}))
            self.assertFalse(sync.sync_cli_limits(state, now=6000 + sync.CLI_FALLBACK_SECONDS - 1, fetch=fetch))
            self.assertEqual(len(calls), 1)
            # Old enough, but the previous attempt was recent.
            state = {"cliFallbackAt": 9000}
            self.assertFalse(sync.sync_cli_limits(state, now=9000 + 60, fetch=fetch))
            self.assertEqual(len(calls), 1)
            # Old enough and no recent attempt.
            self.assertTrue(sync.sync_cli_limits({}, now=6000 + sync.CLI_FALLBACK_SECONDS, fetch=fetch))
            self.assertEqual(len(calls), 2)


class CodexTests(unittest.TestCase):
    def test_snapshot_uses_the_last_token_count_and_model(self):
        lines = [json.dumps(e) for e in [
            {"type": "turn_context", "payload": {"model": "gpt-5-codex"}},
            {"type": "event_msg", "payload": {"type": "token_count", "info": {
                "last_token_usage": {"total_tokens": 10}, "model_context_window": 100}}},
            {"type": "event_msg", "payload": {"type": "token_count", "info": {
                "last_token_usage": {"total_tokens": 25}, "model_context_window": 100},
                "rate_limits": {"primary": {"window_minutes": 300, "used_percent": 12.34},
                                "secondary": {"window_minutes": 10080, "used_percent": 56}}}},
        ]]
        snapshot = sync.codex_snapshot(lines)
        self.assertEqual(snapshot["title"], "Codex")
        self.assertEqual(snapshot["metricsBarValue"], "25%")
        self.assertEqual([m["title"] for m in snapshot["metrics"]], ["Model", "Context", "5h", "7d"])
        self.assertEqual(snapshot["metrics"][0]["formattedValue"], "gpt-5-codex")
        self.assertEqual(snapshot["metrics"][2]["formattedValue"], "12.3%")
        self.assertEqual(snapshot["metrics"][3]["normalizedValue"], 0.56)

    def test_no_token_count_means_no_snapshot(self):
        self.assertIsNone(sync.codex_snapshot(['{"type":"turn_context","payload":{}}', "not json"]))


if __name__ == "__main__":
    unittest.main()
