import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from datetime import datetime, timezone

spec = importlib.util.spec_from_file_location("stats", Path(__file__).with_name("ai-token-stats.py"))
stats = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stats)


def codex(total, last, stamp="2026-11-12T10:00:00Z"):
    return {"timestamp": stamp, "type": "event_msg", "payload": {"type": "token_count", "info": {
        "total_token_usage": {"total_tokens": total, "cached_input_tokens": 20},
        "last_token_usage": {"total_tokens": last}}}}


def claude(tokens, entrypoint="cli"):
    return {"timestamp": "2026-11-12T10:00:00Z", "type": "assistant", "entrypoint": entrypoint,
            "requestId": "request", "message": {"id": "message", "usage": {
                "input_tokens": 10, "output_tokens": tokens, "cache_read_input_tokens": 20,
                "cache_creation_input_tokens": 30}}}


def lines(events):
    return [json.dumps(event).encode() + b"\n" for event in events]


class StatsTests(unittest.TestCase):
    def test_app_quota_export_preserves_source_time_and_strips_other_fields(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            source = home / "Library/Application Support/Claude/plan-usage-history.json"
            source.parent.mkdir(parents=True)
            source.write_text(json.dumps({"version": 2, "samples": [
                {"t": 1000, "org": "private", "u": {"fh": 98, "sd": 21}},
                {"t": 500, "u": {"fh": 5, "sd": 6}}]}))
            output = home / "export.json"
            output.write_text("invalid previous export")
            stats.export_app_quota(home, output)
            expected = {"version": 2, "samples": [{"t": 1000, "u": {"fh": 98, "sd": 21}}]}
            self.assertEqual(json.loads(output.read_text()), expected)
            source.write_text("partial input")
            stats.export_app_quota(home, output)
            self.assertEqual(json.loads(output.read_text()), expected)

    def test_claude_stream_blocks_and_client_overlap_count_once(self):
        records = stats.parse_lines(lines([claude(5), claude(10), claude(10, "claude-desktop")]), "claude")
        self.assertEqual(list(records.values()), [["claude", "2026-11-12", 70]])

    def test_codex_inherited_counter_repeats_and_reset(self):
        events = [codex(1000, 50), codex(1000, 50), codex(1100, 100, "2026-11-12T11:00:00Z"),
                  codex(20, 20, "2026-11-12T12:00:00Z")]
        self.assertEqual(sum(v[2] for v in stats.parse_lines(lines(events), "codex").values()), 170)

    def test_utc_dates_and_invalid_numbers(self):
        self.assertEqual(stats.day_key("2026-11-12T01:00:00+08:00"), "2026-11-11")
        self.assertIsNone(stats.day_key("bad"))
        for value in [-1, float("nan"), float("inf"), "100", True]:
            self.assertEqual(stats.number(value), 0)

    def test_seven_day_window_excludes_older_records(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            path = home / ".codex/sessions/a.jsonl"
            path.parent.mkdir(parents=True)
            path.write_bytes(b"".join(lines([codex(10, 10, "2026-11-05T23:59:59Z"),
                                            codex(30, 20, "2026-11-06T00:00:00Z")])) )
            result = stats.collect(home, home / "output/stats.json", datetime(2026, 11, 12, tzinfo=timezone.utc))
            self.assertEqual(result["total"], 30)
            self.assertEqual(result["last7"], 20)

    def test_collection_deduplicates_archives_and_refreshes_cache(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            session = home / ".codex/sessions/a.jsonl"
            archive = home / ".codex/archived_sessions/a.jsonl"
            claude_path = home / ".claude/projects/a.jsonl"
            for path in [session, archive, claude_path]:
                path.parent.mkdir(parents=True, exist_ok=True)
            session.write_bytes(b"".join(lines([codex(1000, 50)])))
            archive.write_bytes(session.read_bytes())
            claude_path.write_bytes(b"".join(lines([claude(10)])))
            output = home / "output/stats.json"
            now = datetime(2026, 11, 12, tzinfo=timezone.utc)
            first = stats.collect(home, output, now)
            self.assertEqual(first["total"], 120)
            self.assertEqual(first["last7"], 120)
            self.assertEqual(first["totals"], {"codex": 50, "claude": 70})
            self.assertEqual(first, stats.collect(home, output, now))
            with session.open("ab") as stream:
                stream.write(b"".join(lines([codex(1100, 100, "2026-11-12T11:00:00Z")])))
                stream.write(b'{"partial":')
            self.assertEqual(stats.collect(home, output, now)["total"], 220)


if __name__ == "__main__":
    unittest.main()
