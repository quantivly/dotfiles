import argparse, tempfile, unittest
from datetime import datetime, timezone
from pathlib import Path

from rabota import context, errors
from rabota.sources.fireflies import FirefliesClient, normalize_date, parse_action_items

FIX = Path(__file__).parent / "fixtures" / "config"

REAL_SHAPE = """**Alex Russo**
Verify alignment of calendar edit modal with existing design system and report findings (00:14)

**Wesley Mendes**
Continue testing on the staging environment (07:20)

**Unassigned**
Follow up with design about icon set (12:03)
"""


class ParseActionItemsTests(unittest.TestCase):
    """Driven from the DO-744 shape in the brief: `**Speaker**` header, one item per line, an
    optional trailing `(MM:SS)`, and an `**Unassigned**` header for unattributed items. Every
    malformed input below is a claim from the brief ("handle ... by degrading to something
    honest rather than raising") and is tested on its own, not just alongside the happy path.
    """

    def test_the_observed_shape_parses_into_speaker_item_timestamp(self):
        items = parse_action_items(REAL_SHAPE)
        self.assertEqual(items, [
            {"speaker": "Alex Russo",
             "item": "Verify alignment of calendar edit modal with existing design system and report findings",
             "timestamp": "00:14"},
            {"speaker": "Wesley Mendes", "item": "Continue testing on the staging environment", "timestamp": "07:20"},
            {"speaker": None, "item": "Follow up with design about icon set", "timestamp": "12:03"},
        ])

    def test_none_degrades_to_empty_list(self):
        self.assertEqual(parse_action_items(None), [])

    def test_empty_string_degrades_to_empty_list(self):
        self.assertEqual(parse_action_items(""), [])

    def test_whitespace_only_string_degrades_to_empty_list(self):
        self.assertEqual(parse_action_items("   \n  \n "), [])

    def test_no_headers_at_all_keeps_the_items_with_no_speaker(self):
        # Honest degrade: we cannot attribute a speaker the text never named, so `speaker` stays
        # `None` for every line rather than the parser inventing or raising over one.
        text = "Ping @benoit about the review policy (03:00)\nFile the follow-up issue"
        items = parse_action_items(text)
        self.assertEqual(items, [
            {"speaker": None, "item": "Ping @benoit about the review policy", "timestamp": "03:00"},
            {"speaker": None, "item": "File the follow-up issue", "timestamp": None},
        ])

    def test_header_with_no_items_contributes_nothing_and_does_not_crash(self):
        text = "**Alex Russo**\n\n**Wesley Mendes**\nContinue testing (07:20)\n"
        items = parse_action_items(text)
        self.assertEqual(items, [{"speaker": "Wesley Mendes", "item": "Continue testing", "timestamp": "07:20"}])

    def test_trailing_header_with_no_items_at_all_is_an_empty_list(self):
        items = parse_action_items("**Alex Russo**\n")
        self.assertEqual(items, [])

    def test_item_with_no_timestamp_keeps_the_full_text_and_a_none_timestamp(self):
        items = parse_action_items("**Alex Russo**\nJust do the thing, no time given\n")
        self.assertEqual(items, [{"speaker": "Alex Russo", "item": "Just do the thing, no time given", "timestamp": None}])

    def test_header_with_a_trailing_colon_does_not_leak_it_into_the_speaker_name(self):
        # Minor finding, DO-746 fix round: `**Alex:**` must parse to speaker "Alex", not "Alex:".
        items = parse_action_items("**Alex Russo:**\nDo the thing (00:14)\n")
        self.assertEqual(items[0]["speaker"], "Alex Russo")

    def test_a_wrapped_two_line_item_is_a_known_pinned_limitation(self):
        # F3 from the DO-746 fix-round brief: a long item wrapped onto a second markdown line (no
        # blank line between) is parsed as two garbled items, and the first loses its timestamp.
        # Documented as a known limit rather than "fixed" by joining consecutive lines: nothing in
        # this string distinguishes a wrapped continuation from two genuinely separate one-line
        # items that each carry no timestamp of their own (see the module docstring and
        # test_item_with_no_timestamp_keeps_the_full_text_and_a_none_timestamp above) -- a join
        # that guesses wrong would silently merge two unrelated commitments into one, which this
        # test pins as worse than the current, honest split.
        text = ("**Alex Russo**\n"
                "Verify alignment of calendar edit modal with existing design system and report\n"
                "findings (00:14)\n")
        items = parse_action_items(text)
        self.assertEqual(items, [
            {"speaker": "Alex Russo",
             "item": "Verify alignment of calendar edit modal with existing design system and report",
             "timestamp": None},
            {"speaker": "Alex Russo", "item": "findings", "timestamp": "00:14"},
        ])


class FirefliesClientFromContextTests(unittest.TestCase):
    def ctx(self, env=None):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        ns = argparse.Namespace(tenant="quantivly", state_dir=str(Path(tmp.name)), text=False, dry_run=False)
        ctx = context.Context.from_namespace(ns, cfg_base=FIX, env=(env or {"PATH": "/bin"}), cwd=Path("/"))
        self.addCleanup(ctx.close)
        return ctx

    def test_missing_default_env_var_refuses_by_name_not_by_crash(self):
        # Hazard 1/2 from the brief: no tenant field required, defaults to FIREFLIES_API_KEY, and
        # a missing key is a named `errors.Refused` (a `RabotaError`) -- never an unhandled crash --
        # exactly `linear.LinearClient.from_context`'s precedent for an unset `linear_key_env`.
        ctx = self.ctx()
        with self.assertRaises(errors.Refused) as cm:
            FirefliesClient.from_context(ctx)
        self.assertIn("FIREFLIES_API_KEY", str(cm.exception))

    def test_key_present_under_the_default_env_var_name_builds_a_client(self):
        ctx = self.ctx(env={"PATH": "/bin", "FIREFLIES_API_KEY": "x" * 20})
        client = FirefliesClient.from_context(ctx)
        self.assertIsInstance(client, FirefliesClient)


class FakePost:
    def __init__(self, replies):
        self.replies, self.calls = list(replies), []

    def __call__(self, body):
        self.calls.append(body)
        return self.replies.pop(0)


class FirefliesClientQueryTests(unittest.TestCase):
    def test_recent_transcripts_parses_each_summarys_action_items(self):
        reply = {"data": {"transcripts": [
            {"id": "t1", "title": "Trenser sync review", "date": "2026-09-02",
             "summary": {"action_items": "**Zvi Baratz**\nDo the thing (16:52)\n"}},
        ]}}
        client = FirefliesClient("k" * 20, post=FakePost([reply]))
        out = client.recent_transcripts(datetime(2026, 9, 1, tzinfo=timezone.utc))
        self.assertEqual(out, [{"id": "t1", "title": "Trenser sync review", "date": "2026-09-02T00:00:00Z",
                                "action_items": [{"speaker": "Zvi Baratz", "item": "Do the thing", "timestamp": "16:52"}]}])

    def test_query_errors_raise_rabota_error_naming_the_message(self):
        client = FirefliesClient("k" * 20, post=FakePost([{"errors": [{"message": "bad key"}]}]))
        with self.assertRaises(errors.RabotaError) as cm:
            client.recent_transcripts(datetime(2026, 9, 1, tzinfo=timezone.utc))
        self.assertIn("bad key", str(cm.exception))

    def test_missing_summary_or_action_items_degrades_to_an_empty_list_not_a_crash(self):
        reply = {"data": {"transcripts": [{"id": "t1", "title": "x", "date": "d", "summary": None}]}}
        client = FirefliesClient("k" * 20, post=FakePost([reply]))
        out = client.recent_transcripts(datetime(2026, 9, 1, tzinfo=timezone.utc))
        self.assertEqual(out[0]["action_items"], [])
        self.assertIsNone(out[0]["date"])  # "d" is garbage, not an epoch and not ISO -- None, never raw

    def test_recent_transcripts_normalizes_an_epoch_millisecond_date(self):
        reply = {"data": {"transcripts": [
            {"id": "t1", "title": "x", "date": 1790273700000, "summary": None}]}}
        client = FirefliesClient("k" * 20, post=FakePost([reply]))
        out = client.recent_transcripts(datetime(2026, 9, 1, tzinfo=timezone.utc))
        # Verified independently: `date -u -d @1790273700` and `datetime.utcfromtimestamp` both
        # give 18:15:00, not 17:35:00 -- see the verdict for this discrepancy against the brief.
        self.assertEqual(out[0]["date"], "2026-09-24T18:15:00Z")


class NormalizeDateTests(unittest.TestCase):
    """One row per input shape (DO-749): epoch milliseconds, epoch seconds, a numeric string of
    each, an ISO string (date-only and full datetime, with and without a timezone), and
    everything that must degrade to ``None`` rather than pass the raw value through.
    """

    def test_epoch_milliseconds_int(self):
        self.assertEqual(normalize_date(1790273700000), "2026-09-24T18:15:00Z")

    def test_epoch_milliseconds_numeric_string(self):
        self.assertEqual(normalize_date("1790273700000"), "2026-09-24T18:15:00Z")

    def test_epoch_seconds_int_is_told_apart_from_milliseconds(self):
        # Hazard 1: the same instant, in seconds, must not be misread as 1970 (n // 1000 == 1790273).
        self.assertEqual(normalize_date(1790273700), "2026-09-24T18:15:00Z")

    def test_epoch_seconds_numeric_string(self):
        self.assertEqual(normalize_date("1790273700"), "2026-09-24T18:15:00Z")

    def test_iso_datetime_string_with_z_is_reformatted_to_the_same_form(self):
        self.assertEqual(normalize_date("2026-09-24T18:15:00Z"), "2026-09-24T18:15:00Z")

    def test_iso_date_only_string_gets_a_midnight_utc_time(self):
        self.assertEqual(normalize_date("2026-09-02"), "2026-09-02T00:00:00Z")

    def test_iso_string_with_a_non_utc_offset_is_converted_to_utc(self):
        self.assertEqual(normalize_date("2026-09-24T14:15:00-04:00"), "2026-09-24T18:15:00Z")

    def test_none_becomes_none(self):
        self.assertIsNone(normalize_date(None))

    def test_unparseable_garbage_string_becomes_none_not_the_raw_value(self):
        self.assertIsNone(normalize_date("not a date"))

    def test_absurd_integer_out_of_datetimes_range_becomes_none(self):
        self.assertIsNone(normalize_date(10**30))

    def test_a_bool_is_not_treated_as_an_epoch_int(self):
        # bool is a subclass of int in Python; True/False are not dates Fireflies would send,
        # but a naive `isinstance(x, int)` check would silently treat True as epoch 1.
        self.assertIsNone(normalize_date(True))


if __name__ == "__main__":
    unittest.main()
