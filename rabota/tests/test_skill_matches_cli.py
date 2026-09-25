"""Parses ``claude/skills/rabota/SKILL.md`` and asserts it agrees with the CLI it documents
(DO-716). Precedent: DO-710's brief-and-validator row — a guard like this is worthless unless
it can actually fail, so each assertion here is written to catch a specific regression, not to
restate the prose.
"""
import re
import unittest
from pathlib import Path

from rabota.commands import brief

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
        #
        # Checked against `brief.NEEDS_SOURCES`, not `ingest.ALLOWED`: the two were equal until
        # DO-746 moved Fireflies out of NEEDS_SOURCES into `sync.FETCHED_SOURCES` while leaving it
        # in `ingest.ALLOWED` (a manual/session ingest of it is still a legal, separate call this
        # cycle just doesn't make). This row exists to check the ingest call this cycle actually
        # builds from `needs`, so it has to key off the same set `needs` is drawn from — keying off
        # `ingest.ALLOWED` instead would have kept demanding a stale `fireflies=…` in the one call
        # this skill still makes, the moment the two sets first disagreed.
        cycle = _cycle_section()
        calls = re.findall(r"`rabota ingest[^`]*`", cycle)
        self.assertEqual(len(calls), 1, f"expected exactly one `rabota ingest …` call, found {calls}")
        for source in brief.NEEDS_SOURCES:
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
        #
        # AMENDED in the DO-746 fix round 2 (finding D): the exact string this asserted grew
        # `--classified fireflies` -- the explicit acknowledgement that actually marks Fireflies
        # items classified (see `commands.brief.run_brief`'s `classified` parameter). Without it
        # this row would demand the skill keep an under-specified call that classifies nothing;
        # it fails against pre-fix-round-2 code and against a reverted skill line alike.
        self.assertIn("`rabota rank && rabota --text brief --max-lines 11 --classified fireflies`",
                      _cycle_section())

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
        #
        # This row only asserts PRESENCE of every current member, never absence of a former one --
        # so on its own it would not have caught DO-746 leaving a stale "fetch Fireflies in-session"
        # instruction behind after Fireflies left NEEDS_SOURCES (hazard 3 in that brief: "a guard
        # that silently passes on a stale mention"). It still cannot catch that class of drift; the
        # explicit check below is what actually would.
        cycle = _cycle_section()
        for source in brief.NEEDS_SOURCES:
            self.assertIn(source, cycle, f"{source} (from brief.NEEDS_SOURCES) is not mentioned in the cycle")

    def test_fireflies_is_named_as_classified_not_fetched(self):
        # DO-746: Fireflies moved from brief.NEEDS_SOURCES to sync.FETCHED_SOURCES -- it is fetched
        # server-side by the timer, like Linear and GitHub, and neither of those is named in this
        # section either. A stale "fetch Fireflies" instruction here would cost an agent a
        # round-trip for nothing (original brief's hazard 3).
        #
        # AMENDED in the DO-746 fix round (finding F1): before that round this row asserted
        # "fireflies" appears nowhere in the cycle at all -- true then, because nothing read its
        # snapshot. F1's fix makes `compute_needs` hand unclassified Fireflies items to turn 2
        # through `needs` itself (a `fetched: true` entry, no query), so the skill now has to name
        # it -- as something turn 2 classifies, never as something it fetches. The old assertion
        # would fail against the fixed code (it must mention "fireflies" now); this replacement
        # still catches the original regression, a reintroduced "fetch Fireflies" instruction.
        # Whitespace-collapsed so this checks prose-level adjacency, not accidental line-wrap
        # placement in the markdown source.
        cycle = re.sub(r"\s+", " ", _cycle_section())
        self.assertIn("fireflies", cycle.lower())
        # The correct instruction says Fireflies needs NO fetch -- "no fetch" must sit right next
        # to it. What must never appear is a reverted imperative to fetch it, e.g. "fetch Fireflies"
        # or "Fireflies: fetch ... query" (the original brief's hazard 3 shape) -- a literal
        # "fetch"/"fireflies" adjacency with no "no" between them.
        self.assertRegex(cycle, r"(?i)fireflies\)[^.]*\bno fetch\b")
        self.assertNotIn("fetch fireflies", cycle.lower())
        self.assertNotIn("fireflies: fetch", cycle.lower())


if __name__ == "__main__":
    unittest.main()
