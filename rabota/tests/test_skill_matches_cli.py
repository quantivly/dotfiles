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

    def test_preflight_and_rank_are_never_invoked_as_separate_steps(self):
        # `rabota brief` runs preflight+rank+brief itself (#237); the only two mentions of
        # `rabota preflight` / `rabota rank` allowed in the cycle are the sentence that says not
        # to call them separately. A mutation that reintroduces a "1. Preflight. `rabota
        # preflight`" step raises this count and fails.
        cycle = _cycle_section()
        self.assertEqual(cycle.count("`rabota preflight`"), 1, cycle)
        self.assertEqual(cycle.count("`rabota rank`"), 1, cycle)

    def test_needs_empty_stops_the_cycle(self):
        cycle = _cycle_section()
        self.assertIn("needs` is empty", cycle)
        self.assertIn("stop", cycle.lower())

    def test_exit_3_still_stops_everything(self):
        cycle = _cycle_section()
        self.assertIn("Exit 3", cycle)

    def test_turn_2_sources_match_compute_needs(self):
        # brief.NEEDS_SOURCES is the exact set that can appear in `needs`; the skill's fetch
        # bullet must name all of them, or an agent following it would not know to fetch one.
        cycle = _cycle_section()
        for source in brief.NEEDS_SOURCES:
            self.assertIn(source, cycle, f"{source} (from brief.NEEDS_SOURCES) is not mentioned in the cycle")


if __name__ == "__main__":
    unittest.main()
