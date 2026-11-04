"""DO-874: ``rabota snooze <key> --until <when>`` stores one row per key, ``rabota unsnooze``
clears it, and ``--until`` is normalised to a UTC stamp the rank compares as text."""
import argparse, tempfile, unittest
from datetime import date, timedelta, timezone
from pathlib import Path

from rabota import context, errors
from rabota.commands import snooze as snooze_cmd
from rabota.runner import FakeRunner
from tests.test_cli import install_fixture_home, run_cli

FIX = Path(__file__).parent / "fixtures" / "config"
# A fixed zone, so "tomorrow" and a naive stamp never depend on the host the suite runs on.
PLUS_TWO = timezone(timedelta(hours=2))
TODAY = date(2026, 11, 4)


class ParseUntilTests(unittest.TestCase):
    def test_tomorrow_and_a_date_mean_the_start_of_that_day_in_the_zone(self):
        self.assertEqual(snooze_cmd.parse_until("tomorrow", TODAY, PLUS_TWO), "2026-11-04T22:00:00Z")
        self.assertEqual(snooze_cmd.parse_until(" Tomorrow ", TODAY, PLUS_TWO), "2026-11-04T22:00:00Z")
        self.assertEqual(snooze_cmd.parse_until("2026-11-10", TODAY, PLUS_TWO), "2026-11-09T22:00:00Z")

    def test_a_naive_datetime_is_in_the_zone_and_an_aware_one_keeps_its_offset(self):
        self.assertEqual(snooze_cmd.parse_until("2026-11-10T09:30", TODAY, PLUS_TWO), "2026-11-10T07:30:00Z")
        self.assertEqual(snooze_cmd.parse_until("2026-11-10T09:30:00Z", TODAY, PLUS_TWO), "2026-11-10T09:30:00Z")
        self.assertEqual(snooze_cmd.parse_until("2026-11-10T09:30:00+05:00", TODAY, PLUS_TWO), "2026-11-10T04:30:00Z")

    def test_anything_else_is_a_usage_error_naming_the_value(self):
        for bad in ("yesterday", "next week", "10/11/2026", "", "2026-13-01"):
            with self.assertRaises(errors.Usage) as cm:
                snooze_cmd.parse_until(bad, TODAY, PLUS_TWO)
            self.assertIn(repr(bad), str(cm.exception))


class SnoozeCmdTests(unittest.TestCase):
    def setUp(self):
        # The CLI usage rows drive `run_cli`; a fixture $HOME keeps a usage error that slipped past
        # argparse from touching the real state dir (the pin tests' rule).
        install_fixture_home(self)

    def ctx(self, dry_run=False):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        ns = argparse.Namespace(tenant="quantivly", state_dir=str(Path(tmp.name)), text=False, dry_run=dry_run)
        ctx = context.Context.from_namespace(ns, cfg_base=FIX, runner=FakeRunner([]), env={"PATH": "/bin"},
                                              cwd=Path("/"), today=TODAY)
        self.addCleanup(ctx.close)
        return ctx

    def test_snooze_persists_a_utc_stamp_and_a_second_snooze_replaces_the_first(self):
        ctx = self.ctx()
        out = snooze_cmd.run_snooze(ctx, "EX-1", "2999-01-10", PLUS_TWO)
        self.assertEqual((out["item_key"], out["until"]), ("EX-1", "2999-01-09T22:00:00Z"))
        self.assertRegex(out["ts"], r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
        snooze_cmd.run_snooze(ctx, "EX-1", "2999-02-01T00:00:00Z", PLUS_TWO)
        self.assertEqual([(r["item_key"], r["until"]) for r in ctx.store.snoozes("quantivly")],
                         [("EX-1", "2999-02-01T00:00:00Z")])

    def test_a_past_until_is_a_usage_error_and_writes_nothing(self):
        ctx = self.ctx()
        with self.assertRaises(errors.Usage) as cm:
            snooze_cmd.run_snooze(ctx, "EX-1", "2000-01-01", PLUS_TWO)
        self.assertIn("already past", str(cm.exception))
        self.assertEqual(ctx.store.snoozes("quantivly"), [])

    def test_unsnooze_clears_and_says_whether_there_was_one(self):
        ctx = self.ctx()
        snooze_cmd.run_snooze(ctx, "EX-1", "2999-01-10", PLUS_TWO)
        self.assertEqual(snooze_cmd.run_unsnooze(ctx, "EX-1"), {"item_key": "EX-1", "cleared": True})
        self.assertEqual(snooze_cmd.run_unsnooze(ctx, "EX-1"), {"item_key": "EX-1", "cleared": False})
        self.assertEqual(ctx.store.snoozes("quantivly"), [])

    def test_dry_run_writes_no_row_and_deletes_none(self):
        ctx = self.ctx(dry_run=True)
        out = snooze_cmd.run_snooze(ctx, "EX-1", "2999-01-10", PLUS_TWO)
        self.assertEqual(out, {"item_key": "EX-1", "until": "2999-01-09T22:00:00Z", "ts": None, "dry_run": snooze_cmd.DRY_RUN_NOTE})
        self.assertEqual(snooze_cmd.run_unsnooze(ctx, "EX-1"), {"item_key": "EX-1", "cleared": None, "dry_run": snooze_cmd.DRY_RUN_NOTE})
        self.assertEqual(ctx.store.snoozes("quantivly"), [])

    def test_cli_refuses_an_empty_key_before_any_store_is_touched(self):
        code, _out, err = run_cli(["--tenant", "quantivly", "snooze", " ", "--until", "tomorrow"])
        self.assertNotEqual(code, 0)
        self.assertIn("must not be empty", err)
        code, _out, err = run_cli(["--tenant", "quantivly", "unsnooze", ""])
        self.assertNotEqual(code, 0)
        self.assertIn("must not be empty", err)


if __name__ == "__main__":
    unittest.main()
