"""DO-716 move 4: ``reconcile.build_tracked_index`` — the tracked-side facts reconcile's six
classes ask for, built from ``sources/linear.json``/``sources/github.json`` with no new fetch.
"""
import argparse
import json
import tempfile
import unittest
from datetime import date, datetime, timezone
from pathlib import Path

from rabota import context, reconcile, snapshots
from rabota.runner import FakeRunner, Result

FIX = Path(__file__).parent / "fixtures" / "config"
NOW = datetime(2026, 9, 16, 9, 0, tzinfo=timezone.utc)


def _ctx(tenant="quantivly"):
    tmp = tempfile.TemporaryDirectory()
    ns = argparse.Namespace(tenant=tenant, state_dir=str(Path(tmp.name)), text=False, dry_run=False)
    ctx = context.Context.from_namespace(ns, cfg_base=FIX, runner=FakeRunner([]), env={"PATH": "/bin"},
                                         cwd=Path("/"), today=date(2026, 9, 16))
    return tmp, ctx


LINEAR_SNAP = {
    "ok": True, "error": None, "fetched_at": "2026-09-16T08:45:00Z",
    "viewer": {"id": "v1", "name": "zvi"},
    "issues": [
        {"identifier": "HUB-5812", "title": "gate the sre-ui view header editor", "url": "https://linear.app/hub-5812",
         "state": {"name": "In Review", "type": "started"}, "priorityLabel": "P2", "dueDate": "2026-09-04",
         "updatedAt": "2026-08-29T00:00:00Z", "blockedBy": [], "blocks": []},
        {"identifier": "ENG-1958", "title": "cleanup", "url": "https://linear.app/eng-1958",
         "state": {"name": "Backlog", "type": "backlog"}, "priorityLabel": "P1", "dueDate": "2026-09-08",
         "updatedAt": "2026-09-06T00:00:00Z", "blockedBy": ["ENG-1900"], "blocks": []},
    ],
    "notifications": [{"id": "n1", "title": "should never appear in the index"}],
}
GITHUB_SNAP = {
    "ok": True, "error": None, "fetched_at": "2026-09-16T08:45:00Z", "login": "work-login",
    "review_requests": [{"repo": "quantivly/hub", "number": 999, "title": "should never appear in the index"}],
    "own_prs": [
        {"repo": "sre-customers-library", "number": 369, "url": "https://github.com/x/369", "title": "fix",
         "isDraft": False, "mergeable": "MERGEABLE", "reviewDecision": "APPROVED", "approved_by": ["benoit"],
         "headRefName": "zvi/fix", "baseRefName": "main"},
        {"repo": "auto-conf", "number": 461, "url": "https://github.com/x/461", "title": "lint fix",
         "isDraft": False, "mergeable": "BEHIND", "reviewDecision": "REVIEW_REQUIRED", "approved_by": [],
         "headRefName": "zvi/lint", "baseRefName": "main"},
    ],
    "merged_recent": [{"repo": "auto-conf", "number": 450, "url": "https://github.com/x/450", "mergedAt": "2026-09-10T00:00:00Z"}],
}


class TrackedIndexShapeTests(unittest.TestCase):
    def setUp(self):
        self.tmp, self.ctx = _ctx()
        self.addCleanup(self.tmp.cleanup)

    def test_linear_side_carries_state_relations_and_no_description_or_notifications(self):
        snapshots.write(self.ctx.state_dir, "linear", dict(LINEAR_SNAP))
        idx = reconcile.build_tracked_index(self.ctx, NOW)
        self.assertTrue(idx["linear"]["ok"])
        self.assertIsNone(idx["linear"]["reason"])
        by_key = {i["key"]: i for i in idx["linear"]["issues"]}
        self.assertEqual(by_key["HUB-5812"]["state_type"], "started")
        self.assertEqual(by_key["ENG-1958"]["blocked_by"], ["ENG-1900"])
        dumped = json.dumps(idx)
        self.assertNotIn("should never appear", dumped)

    def test_github_side_carries_review_decision_mergeable_and_merged_recent_no_review_requests(self):
        snapshots.write(self.ctx.state_dir, "github", dict(GITHUB_SNAP))
        idx = reconcile.build_tracked_index(self.ctx, NOW)
        self.assertTrue(idx["github"]["ok"])
        by_key = {p["key"]: p for p in idx["github"]["own_prs"]}
        self.assertEqual(by_key["sre-customers-library#369"]["review_decision"], "APPROVED")
        self.assertEqual(by_key["auto-conf#461"]["mergeable"], "BEHIND")
        self.assertEqual({m["key"] for m in idx["github"]["merged_recent"]}, {"auto-conf#450"})
        dumped = json.dumps(idx)
        self.assertNotIn("should never appear", dumped)

    def test_never_synced_source_is_empty_with_a_reason_not_an_exception(self):
        idx = reconcile.build_tracked_index(self.ctx, NOW)
        self.assertEqual(idx["linear"], {"ok": False, "reason": "never synced", "issues": []})
        self.assertEqual(idx["github"], {"ok": False, "reason": "never synced", "own_prs": [], "merged_recent": []})

    def test_unreadable_snapshot_is_empty_with_a_reason(self):
        path = self.ctx.state_dir / "sources" / "linear.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("not json")
        idx = reconcile.build_tracked_index(self.ctx, NOW)
        self.assertFalse(idx["linear"]["ok"])
        self.assertIn("unreadable", idx["linear"]["reason"])
        self.assertEqual(idx["linear"]["issues"], [])

    def test_wrong_shape_snapshot_is_empty_with_a_reason(self):
        snapshots.write(self.ctx.state_dir, "github", {"ok": True, "error": None, "own_prs": "not-a-list", "merged_recent": []})
        idx = reconcile.build_tracked_index(self.ctx, NOW)
        self.assertFalse(idx["github"]["ok"])
        self.assertIn("unreadable", idx["github"]["reason"])

    def test_recorded_sync_failure_is_returned_with_the_error_as_reason(self):
        snapshots.write(self.ctx.state_dir, "linear", {"ok": False, "error": "HTTP 401", "issues": [],
                                                        "fetched_at": "2026-09-16T08:59:00Z"})
        idx = reconcile.build_tracked_index(self.ctx, NOW)
        self.assertFalse(idx["linear"]["ok"])
        self.assertEqual(idx["linear"]["reason"], "HTTP 401")

    def test_stale_snapshot_is_returned_with_data_intact_plus_a_staleness_reason(self):
        # The "brief must still print" precedent (#237): stale data is still the best the CLI has,
        # so it comes back with the issues/PRs present, not suppressed.
        stale = dict(LINEAR_SNAP); stale["fetched_at"] = "2026-09-16T07:00:00Z"   # 120 min before NOW
        snapshots.write(self.ctx.state_dir, "linear", stale)
        idx = reconcile.build_tracked_index(self.ctx, NOW)
        self.assertTrue(idx["linear"]["ok"])
        self.assertEqual(idx["linear"]["reason"], "stale (120 min old)")
        self.assertEqual(len(idx["linear"]["issues"]), 2)

    def test_a_source_the_tenant_does_not_use_is_reported_not_read(self):
        tmp, ctx = _ctx("toysim")
        self.addCleanup(tmp.cleanup)
        idx = reconcile.build_tracked_index(ctx, NOW)
        self.assertEqual(idx["linear"], {"ok": False, "skipped": True,
                                          "reason": "tenant does not use this source", "issues": []})
        # Review finding: a skipped source must be distinguishable from a real failure by a caller
        # that checks `ok` alone, which is the cheap and obvious check. `preflight` already marks
        # this case `skipped`; the flag is what keeps the two agreeing.
        self.assertTrue(idx["linear"]["skipped"])
        tmp2, ctx2 = _ctx("quantivly")
        self.addCleanup(tmp2.cleanup)
        self.assertNotIn("skipped", reconcile.build_tracked_index(ctx2, NOW)["linear"])

    def test_ok_means_trustworthy_not_merely_copied_from_the_snapshot(self):
        """Review finding: `ok` was copied straight from the snapshot, so a side came back
        `ok: True` while its own `reason` said the timestamp was unreadable, and a `fetched_at` in
        the future came back with no reason at all. A caller that checks `ok` alone -- the cheap and
        obvious check -- was misled in both cases."""
        for label, fetched_at, expect_ok in (("unreadable timestamp", "not-a-date", False),
                                              ("future timestamp", "2099-01-01T00:00:00Z", False),
                                              ("merely stale", "2026-09-16T06:00:00Z", True),
                                              ("fresh", "2026-09-16T08:55:00Z", True)):
            with self.subTest(label=label):
                tmp, ctx = _ctx("quantivly")
                self.addCleanup(tmp.cleanup)
                snapshots.write(ctx.state_dir, "linear",
                                {"ok": True, "error": None, "issues": [], "fetched_at": fetched_at})
                side = reconcile.build_tracked_index(ctx, NOW)["linear"]
                self.assertEqual(side["ok"], expect_ok, side)
                if not expect_ok:
                    self.assertIsNotNone(side["reason"], side)

    def test_snapshot_health_names_only_what_cannot_be_relied_on(self):
        """Review finding: `--text` never noticed an unreadable `sources/linear.json` once the day's
        `sequence.json` existed -- only JSON mode's `tracked` revalidated it -- so the brief could
        rank on a corrupt snapshot and say nothing at all about it."""
        tmp, ctx = _ctx("quantivly")
        self.addCleanup(tmp.cleanup)
        (ctx.state_dir / "sources").mkdir(parents=True, exist_ok=True)
        (ctx.state_dir / "sources" / "linear.json").write_text("{oops")
        snapshots.write(ctx.state_dir, "github", {"ok": True, "error": None, "own_prs": [],
                                                   "merged_recent": [], "fetched_at": "2026-09-16T08:55:00Z"})
        health = reconcile.snapshot_health(ctx, NOW)
        self.assertEqual([h["source"] for h in health], ["linear"])
        self.assertIn("unreadable", health[0]["reason"])
        # A source the tenant does not use is not a health problem. toysim lists github only, so
        # `linear` must be absent here -- while github, which it does use and has never synced, is
        # correctly reported. That pair is the distinction the `skipped` flag exists to make.
        tmp2, ctx2 = _ctx("toysim")
        self.addCleanup(tmp2.cleanup)
        toysim = [h["source"] for h in reconcile.snapshot_health(ctx2, NOW)]
        self.assertNotIn("linear", toysim)
        self.assertIn("github", toysim)

    def test_the_staleness_rule_has_exactly_one_definition(self):
        """Review finding: `commands.brief` and `reconcile` each defined `STALE_AFTER_MIN = 60`,
        tied together only by a comment saying they were the same number. Halving one left the whole
        suite green, so a comment was doing an import's job."""
        from rabota import snapshots as snap_mod
        from rabota.commands import brief as brief_mod
        self.assertIs(reconcile.STALE_AFTER_MIN, snap_mod.STALE_AFTER_MIN)
        self.assertIs(brief_mod.STALE_AFTER_MIN, snap_mod.STALE_AFTER_MIN)
        src = (Path(reconcile.__file__).parent / "reconcile.py").read_text()
        brief_src = (Path(reconcile.__file__).parent / "commands" / "brief.py").read_text()
        for name, text in (("reconcile.py", src), ("commands/brief.py", brief_src)):
            self.assertNotRegex(text, r"(?m)^STALE_AFTER_MIN\s*=\s*\d+", f"{name} restates the number")


class TrackedIndexSizeTests(unittest.TestCase):
    """Measured, not assumed: a realistic tenant's index against the lane-artifact 4096-byte
    discipline (``max_verdict_bytes``, ``2026-09-16-rabota-v2-design.md`` line 232) cited as the
    reference point for "small" in the brief — not a bar this change claims to clear.

    DO-735 re-measurement: adding ``pr_links`` (25 issues, 3 carrying one PR attachment each — one
    open, one merged, one unresolvable against ``own_prs``/``merged_recent``, the rest an explicit
    empty list — see ``reconcile.py``'s module docstring) moved the previous ~9.7 KB baseline to
    ~10 KB / ~269 bytes-per-item. That is the honest number, not a compatibility guard: dropping
    notifications and ``review_requests`` (never selected at all — see the fixtures below, which
    include them) is what keeps it there rather than the ~23 KB re-reading both raw snapshots
    whole would cost.

    F2 re-measurement (review of DO-735): carrying a PR's ``title`` into ``pr_links`` and
    ``merged_recent`` moves this same fixture from ~10.2 KB to **10573 bytes / ~278 bytes-per-item**
    — +48 bytes per resolved ``pr_links`` entry (a matched title, ``"a realistically sized PR title
    here"``), +15 bytes for the one that stays unresolved (``title: null``), and +48 bytes per
    ``merged_recent`` row (all 5 in this fixture now carry one). ``own_prs`` already carried
    ``title`` before this change, so its rows cost nothing extra. That is roughly +351 bytes total
    for a 38-item fixture with 3 PR links and 5 merges — cheap here because only a minority of
    issues carry a resolvable PR link at all; a tenant whose PRs are *mostly* resolved against
    ``own_prs``/``merged_recent`` pays closer to the full +48 bytes on every ``pr_links`` entry.
    """

    def test_a_realistic_tenants_index_measures_about_10kb_not_4kb(self):
        tmp, ctx = _ctx()
        self.addCleanup(tmp.cleanup)
        issues = [{"identifier": f"HUB-{5000 + n}", "title": "a realistically sized issue title here",
                   "url": f"https://linear.app/hub-{5000 + n}", "state": {"name": "In Progress", "type": "started"},
                   "priorityLabel": "P2", "dueDate": "2026-09-20", "updatedAt": "2026-09-15T00:00:00Z",
                   "blockedBy": [], "blocks": [], "attachments": []} for n in range(25)]
        # A realistic minority of issues actually carry a linked PR — one whose state resolves via
        # own_prs (open), one via merged_recent (merged), and one that resolves to neither (a
        # colleague's PR, or one outside this tenant's own_prs/merged_recent scope) and so stays
        # "unknown" rather than being guessed at.
        issues[0]["attachments"] = [{"url": "https://github.com/quantivly/hub/pull/1000", "sourceType": "github"}]
        issues[1]["attachments"] = [{"url": "https://github.com/quantivly/hub/pull/900", "sourceType": "github"}]
        issues[2]["attachments"] = [{"url": "https://github.com/quantivly/other/pull/42", "sourceType": "github"}]
        notifications = [{"id": f"n{n}", "title": "a notification the index must never carry"} for n in range(10)]
        own_prs = [{"repo": "quantivly/hub", "number": 1000 + n, "url": f"https://github.com/quantivly/hub/pull/{1000 + n}",
                    "title": "a realistically sized PR title here", "isDraft": False, "mergeable": "MERGEABLE",
                    "reviewDecision": "APPROVED", "approved_by": ["benoit"]} for n in range(8)]
        review_requests = [{"repo": "quantivly/hub", "number": n, "title": "a review request the index must never carry"}
                           for n in range(6)]
        merged = [{"repo": "quantivly/hub", "number": 900 + n, "url": f"https://github.com/quantivly/hub/pull/{900 + n}",
                   "title": "a realistically sized PR title here", "mergedAt": "2026-09-10T00:00:00Z"} for n in range(5)]
        snapshots.write(ctx.state_dir, "linear", {"ok": True, "error": None, "viewer": {}, "issues": issues,
                                                   "notifications": notifications})
        snapshots.write(ctx.state_dir, "github", {"ok": True, "error": None, "login": "x",
                                                   "review_requests": review_requests, "own_prs": own_prs,
                                                   "merged_recent": merged})
        idx = reconcile.build_tracked_index(ctx, NOW)
        dumped = json.dumps(idx)
        size = len(dumped.encode())
        # The honest claim: over the 4 KB reference point for a busy tenant, never carrying the
        # fields dropped on purpose (notifications, review_requests — see the module docstring).
        self.assertGreater(size, 4096, "this tenant scope should exceed the 4 KB reference point")
        # Review finding (pre-DO-735): a band of 4096..10240 passed a per-item regression -- adding
        # one field to every issue moved the total 9422 -> 9797 and still passed. The budget is per
        # item now, so a field added to every record has to be justified against a number that
        # notices. DO-735 moved it again, deliberately, to ~269 bytes/item / ~10 KB total; F2
        # (carrying `title`, review of DO-735) moved it again to ~278 bytes/item / 10573 bytes for
        # this fixture -- see the class docstring for the per-field cost that adds up to.
        items = len(issues) + len(own_prs) + len(merged)
        per_item = size / items
        self.assertLess(per_item, 285, f"{per_item:.0f} bytes/item: the index grew per record ({size} total)")
        self.assertLess(size, 10752, f"tracked index grew past the ~10 KB DO-735 baseline: {size} bytes")
        self.assertNotIn("a notification the index must never carry", dumped)
        self.assertNotIn("a review request the index must never carry", dumped)


class TrackedIndexLiveScaleTests(unittest.TestCase):
    """DO-751: measured, not assumed, at the scale the brief names — @zvi's real tenant has ~908
    open (assigned-or-created) Linear issues. ``TrackedIndexSizeTests`` above measures a 25-issue
    fixture; this measures ``build_tracked_index`` at 908 issues (110 carrying one PR attachment
    each), 20 open PRs of @zvi's, 100 merged — the scale ``commands.brief.run_brief`` stopped
    returning this index at (DO-751), because it is this test's number, not the 25-issue one, that
    a real morning pays.
    """

    def _live_scale_fixture(self, ctx):
        n_issues, n_attach, n_own, n_merged = 908, 110, 20, 100
        issues = [{"identifier": f"HUB-{5000 + n}", "title": "a realistically sized issue title here",
                   "url": f"https://linear.app/hub-{5000 + n}", "state": {"name": "In Progress", "type": "started"},
                   "priorityLabel": "P2", "dueDate": "2026-09-20", "updatedAt": "2026-09-15T00:00:00Z",
                   "blockedBy": [], "blocks": [], "attachments": []} for n in range(n_issues)]
        for i in range(n_attach):
            # A realistic split across the three PR-link outcomes: resolves open, resolves
            # merged, or resolves to neither (stays "unknown") -- see reconcile.py's docstring.
            bucket = i % 3
            if bucket == 0:
                url = f"https://github.com/quantivly/hub/pull/{1000 + i}"
            elif bucket == 1:
                url = f"https://github.com/quantivly/hub/pull/{900 + i}"
            else:
                url = f"https://github.com/quantivly/other/pull/{i}"
            issues[i]["attachments"] = [{"url": url, "sourceType": "github"}]
        own_prs = [{"repo": "quantivly/hub", "number": 1000 + n, "url": f"https://github.com/quantivly/hub/pull/{1000 + n}",
                    "title": "a realistically sized PR title here", "isDraft": False, "mergeable": "MERGEABLE",
                    "reviewDecision": "APPROVED", "approved_by": ["benoit"]} for n in range(n_own)]
        merged = [{"repo": "quantivly/hub", "number": 900 + n, "url": f"https://github.com/quantivly/hub/pull/{900 + n}",
                   "title": "a realistically sized PR title here", "mergedAt": "2026-09-10T00:00:00Z"} for n in range(n_merged)]
        notifications = [{"id": f"n{n}", "title": "a notification the index must never carry"} for n in range(30)]
        review_requests = [{"repo": "quantivly/hub", "number": n, "title": "a review request the index must never carry"}
                           for n in range(15)]
        snapshots.write(ctx.state_dir, "linear", {"ok": True, "error": None, "viewer": {}, "issues": issues,
                                                   "notifications": notifications})
        snapshots.write(ctx.state_dir, "github", {"ok": True, "error": None, "login": "x",
                                                   "review_requests": review_requests, "own_prs": own_prs,
                                                   "merged_recent": merged})
        return issues, own_prs, merged

    def test_build_tracked_index_at_live_scale_measures_hundreds_of_kb(self):
        tmp, ctx = _ctx()
        self.addCleanup(tmp.cleanup)
        issues, own_prs, merged = self._live_scale_fixture(ctx)
        idx = reconcile.build_tracked_index(ctx, NOW)
        dumped = json.dumps(idx)
        size = len(dumped.encode())
        items = len(issues) + len(own_prs) + len(merged)
        # The honest number this test exists to pin down: at @zvi's real scale the whole-tenant
        # index is not "a bit over the 4 KB reference point" (the 25-issue fixture's framing) but
        # two orders of magnitude over it -- this is what commands.brief.run_brief stopped
        # returning in turn 1's JSON reply (DO-751), never something this module claims to shrink
        # further while it still projects every issue in the tenant.
        self.assertGreater(size, 200_000, f"only {size} bytes at 908 issues -- re-measure before trusting this row")
        self.assertLess(size, 400_000, f"{size} bytes: grew enough past the measured ~300 KB to recheck the maths")
        print(f"DO-751 live-scale measurement: {size} bytes total, {size / items:.0f} bytes/item, "
              f"{items} items ({len(issues)} issues, {len(own_prs)} own_prs, {len(merged)} merged)")

    def test_lookup_tracked_at_live_scale_costs_bytes_proportional_to_the_keys_asked_for(self):
        # The claim `rabota tracked` exists to make true: unlike `build_tracked_index`, its cost is
        # the number of SUBJECTS a caller names, not the tenant's issue count -- measured here by
        # asking for a handful of keys against the same 908-issue tenant above and confirming the
        # reply stays small regardless of tenant size.
        tmp, ctx = _ctx()
        self.addCleanup(tmp.cleanup)
        self._live_scale_fixture(ctx)
        keys = ["HUB-5000", "HUB-5001", "HUB-5002", "quantivly/hub#1000", "quantivly/hub#900", "HUB-9999"]
        out = reconcile.lookup_tracked(ctx, keys, NOW)
        size = len(json.dumps(out).encode())
        self.assertLess(size, 4096, f"{size} bytes for {len(keys)} keys: no longer proportional to the ask")
        self.assertEqual(len(out["results"]), len(keys))


class GoldenClassSupportTests(unittest.TestCase):
    """Class by class against ``tests/fixtures/reconcile/golden.json``: does the index carry what
    that golden entry needed to be decided? Two of the six classes never touch the tracked side at
    all (they are verified against the connector artifact itself); of the four that do, one has a
    real gap this test names rather than hides.
    """

    def setUp(self):
        self.tmp, self.ctx = _ctx()
        self.addCleanup(self.tmp.cleanup)

    # -- question-owed (g01, g02) / spoken-already-done (g11): N/A -- reconcile.md says these are
    # verified against the connector artifact (a Slack ts, a transcript id), never against the
    # tracked side, so no index field is claimed to support them.

    def test_tracked_satisfied_g03_decided_from_own_prs_review_decision(self):
        # golden g03: sre-customers-library#369, reviewDecision APPROVED, someone else approved.
        snapshots.write(self.ctx.state_dir, "github", {
            "ok": True, "error": None, "login": "x", "review_requests": [],
            "own_prs": [{"repo": "sre-customers-library", "number": 369, "url": "u", "title": "t",
                        "isDraft": False, "mergeable": "CLEAN", "reviewDecision": "APPROVED",
                        "approved_by": ["benoit"]}],
            "merged_recent": []})
        idx = reconcile.build_tracked_index(self.ctx, NOW)
        pr = next(p for p in idx["github"]["own_prs"] if p["key"] == "sre-customers-library#369")
        self.assertEqual(pr["review_decision"], "APPROVED")
        self.assertEqual(pr["approved_by"], ["benoit"])

    def test_tracked_satisfied_g10_decided_from_merged_recent(self):
        # golden g10: "the nine PR reviews and the #461 merge from run 1 are real and off the queue."
        snapshots.write(self.ctx.state_dir, "github", {
            "ok": True, "error": None, "login": "x", "review_requests": [], "own_prs": [],
            "merged_recent": [{"repo": "auto-conf", "number": 461, "url": "u", "mergedAt": "2026-09-05T00:00:00Z"}]})
        idx = reconcile.build_tracked_index(self.ctx, NOW)
        self.assertIn("auto-conf#461", {m["key"] for m in idx["github"]["merged_recent"]})

    def test_promised_untracked_g08_g09_the_index_is_the_haystack_that_finds_nothing(self):
        # golden g08/g09 are untracked BY DEFINITION: no Linear issue or PR behind them. The index
        # cannot prove universal absence (a title match is heuristic, and the model still judges),
        # but it must at least give the haystack to search rather than nothing -- confirmed here by
        # checking the two commitments' distinctive keywords appear in no tracked title/key.
        snapshots.write(self.ctx.state_dir, "linear", {"ok": True, "error": None, "viewer": {}, "issues": [
            {"identifier": "HUB-1", "title": "unrelated issue", "url": "u", "state": {"name": "Todo", "type": "unstarted"},
             "priorityLabel": "P2", "dueDate": None, "updatedAt": "t", "blockedBy": [], "blocks": []}],
            "notifications": []})
        snapshots.write(self.ctx.state_dir, "github", {"ok": True, "error": None, "login": "x",
                                                        "review_requests": [], "own_prs": [], "merged_recent": []})
        idx = reconcile.build_tracked_index(self.ctx, NOW)
        haystack = " ".join(i["title"] for i in idx["linear"]["issues"]).lower()
        for keyword in ("slot optimization", "code-review medium"):
            self.assertNotIn(keyword, haystack)

    def test_state_contradiction_g05_decided_from_priority_label(self):
        # golden g05: CORE-561/562/563 read "P0" but priorityLabel is actually "No priority" --
        # priority=0 is Linear's "no priority" sentinel, not P0. Decidable because priority_label
        # (the human string), not the numeric `priority`, is what the index carries.
        snapshots.write(self.ctx.state_dir, "linear", {"ok": True, "error": None, "viewer": {}, "issues": [
            {"identifier": "CORE-561", "title": "t", "url": "u", "state": {"name": "Backlog", "type": "backlog"},
             "priorityLabel": "No priority", "dueDate": None, "updatedAt": "t", "blockedBy": [], "blocks": []}],
            "notifications": []})
        idx = reconcile.build_tracked_index(self.ctx, NOW)
        self.assertEqual(idx["linear"]["issues"][0]["priority_label"], "No priority")

    def test_state_contradiction_g06_pre_attachment_snapshot_is_unknown_not_no_pr(self):
        # golden g06 (2026-09-03): recorded "no sre-ui PR exists" from a snapshot shaped exactly
        # like this fixture -- no `attachments` key on the raw issue at all, because it predates
        # DO-735. `pr_links` must read that as `None` ("unknown"), never as `[]` ("checked: no PR
        # linked") -- conflating the two is exactly how g06's wrong "no PR exists" claim happened,
        # corrected three days later by g07.
        snapshots.write(self.ctx.state_dir, "linear", {"ok": True, "error": None, "viewer": {}, "issues": [
            {"identifier": "HUB-5812", "title": "gate the sre-ui view header editor", "url": "u",
             "state": {"name": "In Review", "type": "started"}, "priorityLabel": "P2", "dueDate": "2026-09-04",
             "updatedAt": "2026-08-29T00:00:00Z", "blockedBy": [], "blocks": []}], "notifications": []})
        snapshots.write(self.ctx.state_dir, "github", {"ok": True, "error": None, "login": "x",
                                                        "review_requests": [], "own_prs": [], "merged_recent": []})
        idx = reconcile.build_tracked_index(self.ctx, NOW)
        issue = idx["linear"]["issues"][0]
        self.assertIsNone(issue["pr_links"])

    def test_state_contradiction_g07_a_misleading_attachment_reads_as_linked_and_merged(self):
        # golden g07 (2026-09-06): HUB-5812 carries exactly one attachment, sre-core#1473 -- titled
        # HUB-5693 (a DIFFERENT issue), authored by @zvi, merged 2026-08-31. With `attachments`
        # synced, `pr_links` surfaces it as linked (never "no PR"); its `key` is ALWAYS
        # `owner/repo#n` so it can never name a Linear issue at all (F2, review of DO-735) -- the
        # signal that this PR belongs to a different piece of work is its carried `title`
        # ("HUB-5693" rather than HUB-5812), resolved from `merged_recent` (own_prs/merged_recent
        # are scoped to @zvi, and this PR was authored by @zvi, so cross-referencing resolves it
        # without a live GitHub search).
        snapshots.write(self.ctx.state_dir, "linear", {"ok": True, "error": None, "viewer": {}, "issues": [
            {"identifier": "HUB-5812", "title": "gate the sre-ui view header editor", "url": "u",
             "state": {"name": "In Review", "type": "started"}, "priorityLabel": "P2", "dueDate": "2026-09-04",
             "updatedAt": "2026-08-29T00:00:00Z", "blockedBy": [], "blocks": [],
             "attachments": [{"url": "https://github.com/quantivly/sre-core/pull/1473", "sourceType": "github"}]}],
            "notifications": []})
        snapshots.write(self.ctx.state_dir, "github", {"ok": True, "error": None, "login": "x",
                                                        "review_requests": [], "own_prs": [],
                                                        "merged_recent": [{"repo": "quantivly/sre-core", "number": 1473,
                                                                           "url": "u", "title": "HUB-5693",
                                                                           "mergedAt": "2026-08-31T00:00:00Z"}]})
        idx = reconcile.build_tracked_index(self.ctx, NOW)
        issue = idx["linear"]["issues"][0]
        self.assertEqual(issue["pr_links"], [{"key": "quantivly/sre-core#1473",
                                               "url": "https://github.com/quantivly/sre-core/pull/1473",
                                               "state": "merged", "title": "HUB-5693"}])

    def test_pr_link_state_open_when_in_own_prs(self):
        snapshots.write(self.ctx.state_dir, "linear", {"ok": True, "error": None, "viewer": {}, "issues": [
            {"identifier": "HUB-1", "title": "t", "url": "u", "state": {"name": "In Review", "type": "started"},
             "priorityLabel": "P2", "dueDate": None, "updatedAt": "t", "blockedBy": [], "blocks": [],
             "attachments": [{"url": "https://github.com/quantivly/hub/pull/9", "sourceType": "github"}]}],
            "notifications": []})
        snapshots.write(self.ctx.state_dir, "github", {"ok": True, "error": None, "login": "x", "review_requests": [],
                                                        "own_prs": [{"repo": "quantivly/hub", "number": 9, "url": "u",
                                                                     "title": "t", "isDraft": False, "mergeable": "MERGEABLE",
                                                                     "reviewDecision": "APPROVED", "approved_by": []}],
                                                        "merged_recent": []})
        idx = reconcile.build_tracked_index(self.ctx, NOW)
        self.assertEqual(idx["linear"]["issues"][0]["pr_links"][0]["state"], "open")
        self.assertEqual(idx["linear"]["issues"][0]["pr_links"][0]["title"], "t")

    def test_pr_link_state_unknown_when_no_pr_exists_or_a_colleagues_pr_is_linked(self):
        # A PR outside own_prs/merged_recent's scope -- a colleague's open PR, one closed without
        # merging, or one merged outside the merged_recent window -- must not be guessed at; it
        # stays "unknown", the fallback the brief requires when a state cannot be relied on.
        snapshots.write(self.ctx.state_dir, "linear", {"ok": True, "error": None, "viewer": {}, "issues": [
            {"identifier": "HUB-1", "title": "t", "url": "u", "state": {"name": "In Review", "type": "started"},
             "priorityLabel": "P2", "dueDate": None, "updatedAt": "t", "blockedBy": [], "blocks": [],
             "attachments": [{"url": "https://github.com/quantivly/hub/pull/9", "sourceType": "github"}]}],
            "notifications": []})
        snapshots.write(self.ctx.state_dir, "github", {"ok": True, "error": None, "login": "x",
                                                        "review_requests": [], "own_prs": [], "merged_recent": []})
        idx = reconcile.build_tracked_index(self.ctx, NOW)
        self.assertEqual(idx["linear"]["issues"][0]["pr_links"][0]["state"], "unknown")
        self.assertIsNone(idx["linear"]["issues"][0]["pr_links"][0]["title"])

    def test_no_pr_linked_is_an_empty_list_once_attachments_are_synced(self):
        snapshots.write(self.ctx.state_dir, "linear", {"ok": True, "error": None, "viewer": {}, "issues": [
            {"identifier": "HUB-1", "title": "t", "url": "u", "state": {"name": "In Review", "type": "started"},
             "priorityLabel": "P2", "dueDate": None, "updatedAt": "t", "blockedBy": [], "blocks": [], "attachments": []}],
            "notifications": []})
        snapshots.write(self.ctx.state_dir, "github", {"ok": True, "error": None, "login": "x",
                                                        "review_requests": [], "own_prs": [], "merged_recent": []})
        idx = reconcile.build_tracked_index(self.ctx, NOW)
        self.assertEqual(idx["linear"]["issues"][0]["pr_links"], [])

    def test_a_pr_link_is_recognized_whatever_its_source_type(self):
        # F1 (review of DO-735): `sourceType` used to gate matching, but Linear's own live tenant
        # has GitHub `/pull/` attachment URLs whose `sourceType` reads `api` or `oauthClient`, not
        # `github` -- those issues read as `pr_links: []`, "no PR linked", which is false. The URL
        # regex already anchors on `github.com/.../pull/<n>`; that alone is the discriminator now.
        snapshots.write(self.ctx.state_dir, "linear", {"ok": True, "error": None, "viewer": {}, "issues": [
            {"identifier": "HUB-1", "title": "t", "url": "u", "state": {"name": "In Review", "type": "started"},
             "priorityLabel": "P2", "dueDate": None, "updatedAt": "t", "blockedBy": [], "blocks": [],
             "attachments": [{"url": "https://github.com/quantivly/hub/pull/9", "sourceType": "api"}]}],
            "notifications": []})
        snapshots.write(self.ctx.state_dir, "github", {"ok": True, "error": None, "login": "x",
                                                        "review_requests": [], "own_prs": [], "merged_recent": []})
        idx = reconcile.build_tracked_index(self.ctx, NOW)
        self.assertEqual(idx["linear"]["issues"][0]["pr_links"],
                          [{"key": "quantivly/hub#9", "url": "https://github.com/quantivly/hub/pull/9",
                            "state": "unknown", "title": None}])

    def test_a_non_github_attachment_is_not_read_as_a_pr_link(self):
        snapshots.write(self.ctx.state_dir, "linear", {"ok": True, "error": None, "viewer": {}, "issues": [
            {"identifier": "HUB-1", "title": "t", "url": "u", "state": {"name": "In Review", "type": "started"},
             "priorityLabel": "P2", "dueDate": None, "updatedAt": "t", "blockedBy": [], "blocks": [],
             "attachments": [{"url": "https://sentry.io/x", "sourceType": "sentry"},
                              {"url": "https://github.com/quantivly/hub/issues/9", "sourceType": "github"}]}],
            "notifications": []})
        snapshots.write(self.ctx.state_dir, "github", {"ok": True, "error": None, "login": "x",
                                                        "review_requests": [], "own_prs": [], "merged_recent": []})
        idx = reconcile.build_tracked_index(self.ctx, NOW)
        self.assertEqual(idx["linear"]["issues"][0]["pr_links"], [])

    def test_stale_blocked_g04_decided_from_mergeable_and_review_decision(self):
        # golden g04: auto-conf#461 is BEHIND and REVIEW_REQUIRED, not lint-failed as recorded.
        snapshots.write(self.ctx.state_dir, "github", {
            "ok": True, "error": None, "login": "x", "review_requests": [], "merged_recent": [],
            "own_prs": [{"repo": "auto-conf", "number": 461, "url": "u", "title": "t", "isDraft": False,
                        "mergeable": "BEHIND", "reviewDecision": "REVIEW_REQUIRED", "approved_by": []}]})
        idx = reconcile.build_tracked_index(self.ctx, NOW)
        pr = idx["github"]["own_prs"][0]
        self.assertEqual((pr["mergeable"], pr["review_decision"]), ("BEHIND", "REVIEW_REQUIRED"))

    def test_stale_blocked_g12_is_not_a_tracked_side_question_at_all(self):
        # golden g12's blocker ("needs SSH") is neither a Linear relation nor a GitHub PR state --
        # it is @zvi's own live report that the VPN is connected. No index field claims to cover
        # it; it is verified the same way question-owed/spoken-already-done are, against the
        # connector artifact (here, what @zvi just said), never against sources/linear.json or
        # sources/github.json.
        idx = reconcile.build_tracked_index(self.ctx, NOW)
        self.assertEqual(idx["linear"], {"ok": False, "reason": "never synced", "issues": []})


class LookupTrackedTests(unittest.TestCase):
    """DO-751: ``reconcile.lookup_tracked`` — what ``rabota tracked <key>...`` answers instead of
    a whole-tenant index. Drives the same golden cases ``GoldenClassSupportTests`` drives against
    ``build_tracked_index``, but per-key, to confirm cutting the reply down to exactly the asked-for
    subjects loses no decidability.
    """

    def setUp(self):
        self.tmp, self.ctx = _ctx()
        self.addCleanup(self.tmp.cleanup)

    def test_classify_subject_routes_linear_github_and_other(self):
        self.assertEqual(reconcile.classify_subject("HUB-5812"), "linear")
        self.assertEqual(reconcile.classify_subject("CORE-561"), "linear")
        self.assertEqual(reconcile.classify_subject("sre-customers-library#369"), "github")
        self.assertEqual(reconcile.classify_subject("quantivly/hub#9"), "github")
        # A person-plus-topic subject (a Slack channel id, a Fireflies transcript id): neither
        # shape, so `question-owed`/`spoken-already-done` never look it up here at all.
        self.assertEqual(reconcile.classify_subject("C0A2FRLPA58"), "other")
        self.assertEqual(reconcile.classify_subject("01M1H28CHBVMJXBSDKF1ZHN32D"), "other")

    def test_subjects_copied_from_free_text_resolve_to_the_same_record(self):
        # DO-751 review F2/F3: an agent builds keys from Slack and transcript text. A trailing comma,
        # a lowercase key, a full Linear URL or a full PR URL must reach the record the bare key does.
        snapshots.write(self.ctx.state_dir, "linear", dict(LINEAR_SNAP))
        gh = dict(GITHUB_SNAP)
        gh["own_prs"] = [dict(p, repo="quantivly/" + p["repo"]) for p in GITHUB_SNAP["own_prs"]]
        snapshots.write(self.ctx.state_dir, "github", gh)
        asked = ["HUB-5812,", "hub-5812", "(HUB-5812)", "https://linear.app/quantivly/issue/HUB-5812/some-slug",
                 "https://github.com/quantivly/auto-conf/pull/461", "quantivly/auto-conf#461."]
        out = reconcile.lookup_tracked(self.ctx, asked, NOW)
        for r in out["results"]:
            self.assertEqual(r["status"], "found", r)
        self.assertEqual({r.get("resolved", r["key"]) for r in out["results"]},
                         {"HUB-5812", "quantivly/auto-conf#461"})

    def test_an_owner_less_pr_key_resolves_by_unique_suffix_and_reports_ambiguity(self):
        # DO-751 review: `auto-conf#461` against an index keyed `quantivly/auto-conf#461` answered
        # not_found for a PR that is there. A unique suffix match resolves it; two are reported.
        snapshots.write(self.ctx.state_dir, "linear", dict(LINEAR_SNAP))
        gh = dict(GITHUB_SNAP)
        gh["own_prs"] = [dict(p, repo="quantivly/" + p["repo"]) for p in GITHUB_SNAP["own_prs"]] + [
            dict(GITHUB_SNAP["own_prs"][1], repo="someone/auto-conf")]
        snapshots.write(self.ctx.state_dir, "github", gh)
        by_key = {r["key"]: r for r in reconcile.lookup_tracked(
            self.ctx, ["sre-customers-library#369", "auto-conf#461"], NOW)["results"]}
        self.assertEqual(by_key["sre-customers-library#369"]["status"], "found")
        self.assertEqual(by_key["sre-customers-library#369"]["resolved"], "quantivly/sre-customers-library#369")
        self.assertEqual(by_key["auto-conf#461"]["status"], "ambiguous")
        self.assertEqual(by_key["auto-conf#461"]["candidates"], ["quantivly/auto-conf#461", "someone/auto-conf#461"])

    def test_found_not_found_and_unknown_are_distinct(self):
        snapshots.write(self.ctx.state_dir, "linear", dict(LINEAR_SNAP))
        snapshots.write(self.ctx.state_dir, "github", dict(GITHUB_SNAP))
        out = reconcile.lookup_tracked(self.ctx, ["HUB-5812", "HUB-9999", "sre-customers-library#369",
                                                   "no-such-repo#1", "C0A2FRLPA58"], NOW)
        by_key = {r["key"]: r for r in out["results"]}
        self.assertEqual(by_key["HUB-5812"]["status"], "found")
        self.assertEqual(by_key["HUB-5812"]["kind"], "linear")
        self.assertEqual(by_key["HUB-9999"]["status"], "not_found")           # trustworthy source, absent subject
        self.assertEqual(by_key["sre-customers-library#369"]["status"], "found")
        self.assertEqual(by_key["sre-customers-library#369"]["kind"], "github")
        self.assertEqual(by_key["no-such-repo#1"]["status"], "not_found")
        self.assertEqual(by_key["C0A2FRLPA58"]["status"], "not_applicable")

    def test_unknown_is_never_conflated_with_not_found(self):
        # golden g06's bug one level up: a key routed to a source that cannot be relied on (never
        # synced here) must read "unknown", never the "not_found" a caller could mistake for proof
        # of absence.
        out = reconcile.lookup_tracked(self.ctx, ["HUB-5812", "sre-customers-library#369"], NOW)
        for r in out["results"]:
            self.assertEqual(r["status"], "unknown", r)
            self.assertIn("never synced", r["reason"])

    def test_a_skipped_source_reads_unknown_not_not_found(self):
        tmp, ctx = _ctx("toysim")   # lists github only, per tests/fixtures/config
        self.addCleanup(tmp.cleanup)
        out = reconcile.lookup_tracked(ctx, ["HUB-1"], NOW)
        self.assertEqual(out["results"][0]["status"], "unknown")
        self.assertIn("does not use this source", out["results"][0]["reason"])

    def test_g03_tracked_satisfied_decidable_from_a_single_pr_lookup(self):
        snapshots.write(self.ctx.state_dir, "github", {
            "ok": True, "error": None, "login": "x", "review_requests": [],
            "own_prs": [{"repo": "sre-customers-library", "number": 369, "url": "u", "title": "t",
                        "isDraft": False, "mergeable": "CLEAN", "reviewDecision": "APPROVED",
                        "approved_by": ["benoit"]}],
            "merged_recent": []})
        out = reconcile.lookup_tracked(self.ctx, ["sre-customers-library#369"], NOW)
        r = out["results"][0]
        self.assertEqual(r["status"], "found")
        self.assertEqual(r["record"]["kind"], "own_pr")
        self.assertEqual(r["record"]["review_decision"], "APPROVED")

    def test_g04_stale_blocked_decidable_from_a_single_pr_lookup(self):
        snapshots.write(self.ctx.state_dir, "github", {
            "ok": True, "error": None, "login": "x", "review_requests": [], "merged_recent": [],
            "own_prs": [{"repo": "auto-conf", "number": 461, "url": "u", "title": "t", "isDraft": False,
                        "mergeable": "BEHIND", "reviewDecision": "REVIEW_REQUIRED", "approved_by": []}]})
        out = reconcile.lookup_tracked(self.ctx, ["auto-conf#461"], NOW)
        r = out["results"][0]["record"]
        self.assertEqual((r["mergeable"], r["review_decision"]), ("BEHIND", "REVIEW_REQUIRED"))

    def test_g07_state_contradiction_decidable_from_a_single_issue_lookup(self):
        snapshots.write(self.ctx.state_dir, "linear", {"ok": True, "error": None, "viewer": {}, "issues": [
            {"identifier": "HUB-5812", "title": "gate the sre-ui view header editor", "url": "u",
             "state": {"name": "In Review", "type": "started"}, "priorityLabel": "P2", "dueDate": "2026-09-04",
             "updatedAt": "2026-08-29T00:00:00Z", "blockedBy": [], "blocks": [],
             "attachments": [{"url": "https://github.com/quantivly/sre-core/pull/1473", "sourceType": "github"}]}],
            "notifications": []})
        snapshots.write(self.ctx.state_dir, "github", {"ok": True, "error": None, "login": "x",
                                                        "review_requests": [], "own_prs": [],
                                                        "merged_recent": [{"repo": "quantivly/sre-core", "number": 1473,
                                                                           "url": "u", "title": "HUB-5693",
                                                                           "mergedAt": "2026-08-31T00:00:00Z"}]})
        out = reconcile.lookup_tracked(self.ctx, ["HUB-5812"], NOW)
        rec = out["results"][0]["record"]
        self.assertEqual(rec["pr_links"], [{"key": "quantivly/sre-core#1473",
                                             "url": "https://github.com/quantivly/sre-core/pull/1473",
                                             "state": "merged", "title": "HUB-5693"}])

    def test_g10_tracked_satisfied_decidable_from_merged_recent_lookup(self):
        snapshots.write(self.ctx.state_dir, "github", {
            "ok": True, "error": None, "login": "x", "review_requests": [], "own_prs": [],
            "merged_recent": [{"repo": "auto-conf", "number": 461, "url": "u", "title": "t",
                               "mergedAt": "2026-09-05T00:00:00Z"}]})
        out = reconcile.lookup_tracked(self.ctx, ["auto-conf#461"], NOW)
        self.assertEqual(out["results"][0]["record"]["kind"], "merged_recent")

    def test_a_pr_key_in_both_own_prs_and_merged_recent_resolves_to_merged(self):
        snapshots.write(self.ctx.state_dir, "github", {
            "ok": True, "error": None, "login": "x", "review_requests": [],
            "own_prs": [{"repo": "auto-conf", "number": 461, "url": "u", "title": "t", "isDraft": False,
                        "mergeable": "MERGEABLE", "reviewDecision": "APPROVED", "approved_by": []}],
            "merged_recent": [{"repo": "auto-conf", "number": 461, "url": "u", "title": "t",
                               "mergedAt": "2026-09-05T00:00:00Z"}]})
        out = reconcile.lookup_tracked(self.ctx, ["auto-conf#461"], NOW)
        self.assertEqual(out["results"][0]["record"]["kind"], "merged_recent")

    def test_empty_keys_returns_empty_results_and_still_reports_side_status(self):
        out = reconcile.lookup_tracked(self.ctx, [], NOW)
        self.assertEqual(out["results"], [])
        self.assertFalse(out["linear"]["ok"])
