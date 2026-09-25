"""Parses ``claude/skills/rabota/SKILL.md`` and asserts it agrees with the CLI it documents
(DO-716). Precedent: DO-710's brief-and-validator row — a guard like this is worthless unless
it can actually fail, so each assertion here is written to catch a specific regression, not to
restate the prose.
"""
import re
import unittest
from pathlib import Path

from rabota.commands import brief, ingest

SKILL = Path(__file__).parents[2] / "claude" / "skills" / "rabota" / "SKILL.md"


def _cycle_section() -> str:
    text = SKILL.read_text()
    start = text.index("## The cycle")
    end = text.index("## Inbox session")
    return text[start:end]


class SkillMatchesCliTests(unittest.TestCase):
    """Would have caught: the skill reverting to the pre-#237/#236/#238 five-step sequence."""

    def test_ingest_is_called_once_naming_every_needs_source(self):
        # One multi-source `ingest --file SOURCE=PATH` call, not one per source (#236). A
        # mutation that reintroduces `rabota ingest <source> --file …` three times fails this:
        # either the source= form disappears, or `rabota ingest` is invoked more than once.
        cycle = _cycle_section()
        calls = re.findall(r"`rabota ingest[^`]*`", cycle)
        self.assertEqual(len(calls), 1, f"expected exactly one `rabota ingest …` call, found {calls}")
        for source in ingest.ALLOWED:
            self.assertIn(f"{source}=", calls[0], f"ingest call is missing {source}=…")

    def test_preflight_is_never_a_step_of_its_own(self):
        # `rabota brief` runs preflight itself (#237). Counting mentions was too brittle to keep --
        # turn 2 legitimately gained a `rabota rank` call -- so this asserts the thing that actually
        # matters: no numbered or bulleted step is headed "Preflight" or "Rank". A mutation that
        # reintroduces "1. **Preflight.** `rabota preflight`" fails here.
        cycle = _cycle_section()
        self.assertNotRegex(cycle, r"(?mi)^\s*(?:\d+\.|-)\s*\*\*(?:Preflight|Rank)\b")

    def test_turn_2_ranks_before_its_final_brief(self):
        # `brief` ranks only when the day's sequence.json is MISSING, so after an ingest it would
        # re-print the pre-fetch ranking and label it `no change` -- the fetch wasted, silently
        # (review finding). Turn 2's final call therefore ranks first. Driven, not assumed: see
        # test_brief for `sequence.json` not being regenerated on a second same-day call.
        self.assertIn("`rabota rank && rabota --text brief --max-lines 11`", _cycle_section())

    def test_needs_empty_stops_and_needs_non_empty_prints_nothing_yet(self):
        # Both halves: the empty case must stop, and the non-empty case must NOT print turn 1's
        # lines, or the reader gets two screens and the second says `no change`.
        cycle = _cycle_section()
        self.assertRegex(cycle, r"(?s)`needs` empty.*?stop here")   # (?s): the sentence wraps
        self.assertRegex(cycle, r"`needs` non-empty: print nothing yet")

    def test_exit_3_stops_everything_and_says_so(self):
        # Review finding: asserting only that "Exit 3" appears passed a mutation that inverted the
        # invariant -- "a failed identity pin ... is retried; continue to turn 2 anyway" kept the
        # string and the whole guard stayed green. The words that carry the rule are asserted now.
        cycle = _cycle_section()
        self.assertIn("Exit 3", cycle)
        self.assertIn("never worked around", cycle)
        self.assertNotRegex(cycle, r"(?i)identity pin[^.]*(retr|continue|ignore|work around it)")

    def test_turn_2_sources_match_compute_needs(self):
        # brief.NEEDS_SOURCES is the exact set that can appear in `needs`; the skill's fetch
        # bullet must name all of them, or an agent following it would not know to fetch one.
        cycle = _cycle_section()
        for source in brief.NEEDS_SOURCES:
            self.assertIn(source, cycle, f"{source} (from brief.NEEDS_SOURCES) is not mentioned in the cycle")


if __name__ == "__main__":
    unittest.main()
