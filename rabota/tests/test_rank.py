import argparse, json, tempfile, unittest
from unittest import mock
from datetime import date
from pathlib import Path
from rabota import config, context, errors, rank, secrets, snapshots
from rabota.commands import rank as rank_cmd
from rabota.runner import FakeRunner

FIX = Path(__file__).parent / "fixtures" / "config"
T = config.load(FIX).tenants["quantivly"]

def issue(ident, state_type, prio, due=None, project="P", updated="2026-09-15T00:00:00Z"):
    return {"id": ident, "identifier": ident, "title": ident, "url": f"u/{ident}", "priorityLabel": prio,
            "dueDate": due, "state": {"name": state_type, "type": state_type}, "team": {"key": ident.split("-")[0]},
            "project": {"name": project} if project else None, "updatedAt": updated, "createdAt": updated,
            "assignee": {"id": "me"}, "blockedBy": [], "blocks": []}

def review(repo, n, individually, teams, updated="2026-09-15T00:00:00Z", author="alex"):
    return {"repo": repo, "number": n, "url": f"u{n}", "title": f"t{n}", "author": author, "requested_individually": individually,
            "via_teams": teams, "updatedAt": updated, "isDraft": False}

class RankTests(unittest.TestCase):
    def base(self, **over):
        linear = {"viewer": {"id": "me"}, "issues": over.get("issues", []), "notifications": []}
        if "blocked" in over:                       # DO-878: the snapshot section; absent on a snapshot older than DO-875/878
            linear["blocked"] = over["blocked"]
        github = {"login": "work-login", "review_requests": over.get("rr", []), "own_prs": over.get("prs", []), "merged_recent": []}
        return rank.RankInputs(linear=linear, github=github, slack=None, inbox_plan=over.get("plan"),
                               census=over.get("census"), pins=over.get("pins", []), tenant=T, today=date(2026, 9, 16))

    def test_batch_due_dates_detected(self):
        issues = [issue(f"HUB-{i}", "backlog", "Medium", due="2026-09-04") for i in range(5)] + [issue("HUB-9", "unstarted", "High", due="2026-09-20")]
        self.assertEqual(rank.batch_due_dates(issues), {"2026-09-04"})

    def test_reply_queue_and_individual_reviews_are_bucket_1(self):
        plan = {"buckets": {"reply_queue": [{"issue_identifier": "HUB-6247", "actor": "benoit", "created_at": "2026-09-14T00:00:00Z", "url": "u", "title": "t"}]}}
        rr = [review("quantivly/hub", 1, True, []),
              review("quantivly/sre-core", 2, False, ["hub-backend"], author="connor"),
              review("quantivly/dev-setup", 3, False, ["devops"], author="kyle")]
        seq = rank.rank(self.base(plan=plan, rr=rr))
        b1 = [i["key"] for i in seq["items"] if i["bucket"] == 1]
        self.assertEqual(b1, ["HUB-6247", "quantivly/hub#1"])          # oldest first; team-derived excluded
        self.assertEqual([t["key"] for t in seq["triage"]], ["quantivly/dev-setup#3"])  # hub-backend dropped (alex owns it)
        self.assertEqual(seq["items"][0]["waiting_on"], "benoit")

    def test_reply_queue_pr_notification_without_an_issue_gets_a_repo_hash_number_key(self):
        # DO-715 F6: a Linear notification about a PR (no linked issue) fell back to the raw
        # PR url as the "key", rendering as a bare URL with no title. A repo#number is the
        # same identifier bucket 4 already uses, and it is derived, not invented.
        plan = {"buckets": {"reply_queue": [{"issue_identifier": None, "pr_url": "https://github.com/quantivly/hub/pull/456",
                                              "url": "https://github.com/quantivly/hub/pull/456", "title": "",
                                              "actor": "alex", "created_at": "2026-09-14T00:00:00Z", "type": "pullRequestReviewRequested"}]}}
        seq = rank.rank(self.base(plan=plan))
        item = next(i for i in seq["items"] if i["bucket"] == 1)
        self.assertEqual(item["key"], "quantivly/hub#456")

    def test_reply_queue_item_with_no_url_at_all_falls_back_to_the_notification_id(self):
        # Review finding: `url` is nullable on a Linear notification, so the bare-url fallback
        # could return None and `brief` rendered the literal line "1. None" — worse than the bare
        # URL this change replaces. Every notification has an id; print that instead.
        plan = {"buckets": {"reply_queue": [{"issue_identifier": None, "pr_url": None, "url": None,
                                              "notification_id": "n-abc", "title": "", "actor": "alex",
                                              "created_at": "2026-09-14T00:00:00Z"}]}}
        seq = rank.rank(self.base(plan=plan))
        item = next(i for i in seq["items"] if i["bucket"] == 1)
        self.assertEqual(item["key"], "n-abc")
        self.assertNotIn(item["key"], (None, "None"))

    def test_reply_queue_item_with_neither_issue_nor_pr_url_keeps_the_bare_url(self):
        # No identifier is derivable: showing the url is honest; inventing one would not be.
        plan = {"buckets": {"reply_queue": [{"issue_identifier": None, "pr_url": None, "url": "https://example.com/x",
                                              "title": "", "actor": "alex", "created_at": "2026-09-14T00:00:00Z"}]}}
        seq = rank.rank(self.base(plan=plan))
        item = next(i for i in seq["items"] if i["bucket"] == 1)
        self.assertEqual(item["key"], "https://example.com/x")

    def test_bucket_1_orders_by_age_not_by_source(self):
        plan = {"buckets": {"reply_queue": [{"issue_identifier": "HUB-1", "actor": "b", "created_at": "2026-09-15T00:00:00Z", "url": "u", "title": "t"}]}}
        rr = [review("quantivly/hub", 1, True, [], updated="2026-09-10T00:00:00Z")]
        seq = rank.rank(self.base(plan=plan, rr=rr))
        self.assertEqual([i["key"] for i in seq["items"] if i["bucket"] == 1], ["quantivly/hub#1", "HUB-1"])

    def test_bucket_1_folds_a_thread_to_one_row_and_a_review_request_in_both_sources_to_one(self):
        # DO-876: three notifications on one thread and one review request carried by both the plan
        # and github.json yield two rows. Each row orders by its key's OLDEST notification and says
        # how many it folded; the first row seen keeps its other fields.
        plan = {"buckets": {"reply_queue": [
            {"issue_identifier": "HUB-1", "actor": "b", "created_at": "2026-09-14T00:00:00Z", "url": "u", "title": "t", "type": "issueNewComment"},
            {"issue_identifier": "HUB-1", "actor": "c", "created_at": "2026-09-12T00:00:00Z", "url": "u", "title": "t", "type": "issueNewComment"},
            {"issue_identifier": "HUB-1", "actor": "b", "created_at": "2026-09-15T00:00:00Z", "url": "u", "title": "t", "type": "issueCommentMention"},
            {"issue_identifier": None, "pr_url": "https://github.com/quantivly/hub/pull/7", "url": "https://github.com/quantivly/hub/pull/7",
             "title": "", "actor": "alex", "created_at": "2026-09-13T00:00:00Z", "type": "pullRequestReviewRequested"}]}}
        rr = [review("quantivly/hub", 7, True, [], updated="2026-09-15T00:00:00Z")]
        seq = rank.rank(self.base(plan=plan, rr=rr))
        b1 = [i for i in seq["items"] if i["bucket"] == 1]
        self.assertEqual([i["key"] for i in b1], ["HUB-1", "quantivly/hub#7"])      # HUB-1's oldest is 09-12, the PR's 09-13
        self.assertEqual(b1[0]["why_now"], "3 notifications on the thread since 2026-09-12, unanswered")
        self.assertEqual(b1[0]["waiting_on"], "b")                                  # the first row seen keeps its fields
        self.assertEqual(b1[1]["why_now"], "2 notifications on the thread since 2026-09-13, unanswered")
        self.assertEqual(len({i["key"] for i in b1}), len(b1))

    def test_bucket_1_single_rows_keep_their_own_why_now(self):
        plan = {"buckets": {"reply_queue": [{"issue_identifier": "HUB-2", "actor": "b", "created_at": "2026-09-14T00:00:00Z",
                                              "url": "u", "title": "t", "type": "issueNewComment"}]}}
        seq = rank.rank(self.base(plan=plan))
        self.assertEqual(seq["items"][0]["why_now"], "issueNewComment 2026-09-14, unanswered")

    def test_p0_in_backlog_is_a_decision_and_batch_date_not_a_deadline(self):
        issues = [issue("DO-9", "backlog", "Urgent")] + [issue(f"HUB-{i}", "unstarted", "High", due="2026-09-04") for i in range(5)]
        seq = rank.rank(self.base(issues=issues))
        self.assertEqual([d["key"] for d in seq["decisions"]], ["DO-9"])
        self.assertFalse(any(i["bucket"] == 3 for i in seq["items"]))  # batch date discounted

    def test_high_issue_with_a_real_date_is_bucket_3(self):
        seq = rank.rank(self.base(issues=[issue("HUB-7", "unstarted", "High", due="2026-09-20")]))
        item = next(i for i in seq["items"] if i["key"] == "HUB-7")
        self.assertEqual((item["bucket"], item["why_now"]), (3, "due 2026-09-20"))
        self.assertIn("bucket 3", item["rationale"])

    def test_in_flight_issue_is_demoted(self):
        issues = [issue("DO-574", "unstarted", "High", due="2026-09-20")]
        census = {"sessions": [{"name": "fix-do-574", "cwd": "/x", "owner_lane": None}], "lanes": []}
        seq = rank.rank(self.base(issues=issues, census=census))
        self.assertFalse(any(i["key"] == "DO-574" and i["bucket"] == 3 for i in seq["items"]))
        self.assertTrue(any("in flight" in i["rationale"] for i in seq["items"] if i["key"] == "DO-574"))

    def test_in_flight_keys_read_sessions_and_lane_briefs(self):
        census = {"sessions": [{"name": "hub-6247 reply", "cwd": "/home/z/quantivly/do-574"}], "lanes": [{"brief": "Fix CORE-12 first"}]}
        self.assertEqual(rank.in_flight_keys(census), {"HUB-6247", "DO-574", "CORE-12"})
        self.assertEqual(rank.in_flight_keys(None), set())

    def test_approved_own_pr_and_started_issue_are_bucket_4_and_todo_is_capped_bucket_5(self):
        prs = [{"repo": "quantivly/hub", "number": 5, "url": "u5", "title": "t5", "isDraft": False, "mergeable": "MERGEABLE",
                "reviewDecision": "APPROVED", "approved_by": ["alex"], "headRefName": "f", "baseRefName": "main"},
               {"repo": "quantivly/hub", "number": 6, "url": "u6", "title": "t6", "isDraft": True, "mergeable": "MERGEABLE",
                "reviewDecision": "APPROVED", "approved_by": ["alex"], "headRefName": "g", "baseRefName": "main"}]
        issues = [issue("HUB-3", "started", "Medium")] + [issue(f"HUB-{i}", "unstarted", "Medium", updated=f"2026-09-{i:02d}T00:00:00Z") for i in range(10, 15)]
        seq = rank.rank(self.base(prs=prs, issues=issues))
        b4 = [i["key"] for i in seq["items"] if i["bucket"] == 4]
        b5 = [i["key"] for i in seq["items"] if i["bucket"] == 5]
        self.assertEqual(b4, ["quantivly/hub#5", "HUB-3"])            # draft PR excluded
        self.assertEqual(b5, ["HUB-14", "HUB-13", "HUB-12"])           # newest first, capped to 3
        self.assertEqual([i["bucket"] for i in seq["items"]], sorted(i["bucket"] for i in seq["items"]))

    def test_bucket_3_and_4_issues_that_block_open_issues_say_so_and_order_first(self):
        # DO-878: the people waiting on an own issue are a reason. The count reads the snapshot's
        # `blocked[]` (DO-875's relation read: one row per issue the operator's issues block, with
        # its state); only open targets count, the row says how many before its own line, and
        # within buckets 3 and 4 a blocking row orders before the rows that block none.
        issues = [issue("HUB-1", "unstarted", "High", due="2026-09-22"), issue("HUB-2", "unstarted", "High", due="2026-09-18"),
                  issue("HUB-3", "started", "Medium", updated="2026-09-10T00:00:00Z"),
                  issue("HUB-4", "started", "Medium", updated="2026-09-12T00:00:00Z")]
        issues[0]["blocks"] = ["CORE-1", "CORE-2", "CORE-3"]; issues[3]["blocks"] = ["CORE-4"]
        blocked = [{"identifier": "CORE-1", "state": {"name": "In Progress", "type": "started"}},
                   {"identifier": "CORE-2", "state": {"name": "Done", "type": "completed"}},
                   {"identifier": "CORE-3", "state": {"name": "Todo", "type": "unstarted"}},
                   {"identifier": "CORE-4", "state": {"name": "Backlog", "type": "backlog"}}]
        prs = [{"repo": "quantivly/hub", "number": 5, "url": "u5", "title": "t5", "isDraft": False, "mergeable": "MERGEABLE",
                "reviewDecision": "APPROVED", "approved_by": ["alex"], "headRefName": "f", "baseRefName": "main"}]
        seq = rank.rank(self.base(issues=issues, blocked=blocked, prs=prs))
        rows = {i["key"]: i for i in seq["items"]}
        self.assertEqual([i["key"] for i in seq["items"] if i["bucket"] == 3], ["HUB-1", "HUB-2"])   # HUB-2's date is sooner; HUB-1 blocks two
        self.assertEqual(rows["HUB-1"]["why_now"], "blocks 2 open issues · due 2026-09-22")
        self.assertEqual(rows["HUB-2"]["why_now"], "due 2026-09-18")
        self.assertEqual([i["key"] for i in seq["items"] if i["bucket"] == 4], ["HUB-4", "quantivly/hub#5", "HUB-3"])
        self.assertEqual(rows["HUB-4"]["why_now"], "blocks 1 open issue · in progress since 2026-09-12")
        self.assertEqual(rows["HUB-3"]["why_now"], "in progress since 2026-09-10")
        self.assertEqual([i["bucket"] for i in seq["items"]], sorted(i["bucket"] for i in seq["items"]))

    def test_backlog_p0_that_blocks_open_issues_is_still_a_decision(self):
        # DO-878: the standing correction is not weakened by the new input.
        issues = [issue("DO-9", "backlog", "Urgent")]; issues[0]["blocks"] = ["CORE-1"]
        blocked = [{"identifier": "CORE-1", "state": {"name": "In Progress", "type": "started"}}]
        seq = rank.rank(self.base(issues=issues, blocked=blocked))
        self.assertEqual([d["key"] for d in seq["decisions"]], ["DO-9"])
        self.assertEqual(seq["items"], [])

    def test_blocks_count_ignores_closed_targets_and_a_snapshot_without_the_section(self):
        # DO-878: a closed target is nobody waiting; a snapshot older than the section ranks as before.
        issues = [issue("HUB-1", "unstarted", "High", due="2026-09-22")]; issues[0]["blocks"] = ["CORE-2", "CORE-9"]
        blocked = [{"identifier": "CORE-2", "state": {"name": "Done", "type": "completed"}}]   # CORE-9 unknown to the snapshot
        for inputs in (self.base(issues=issues, blocked=blocked), self.base(issues=issues)):
            seq = rank.rank(inputs)
            self.assertEqual(seq["items"][0]["why_now"], "due 2026-09-22")

    def test_snoozed_key_leaves_every_bucket_and_is_a_decision_once(self):
        # DO-874: a snoozed key is dropped wherever a bucket placed it (1 by a notification, 2 by a
        # pin, 3 as a hot issue) and said once in decisions with the stamp it comes back at; a key
        # not snoozed stays, and a snooze on a key nothing ranks says nothing.
        plan = {"buckets": {"reply_queue": [{"issue_identifier": "HUB-1", "actor": "someone", "created_at": "2026-09-14T00:00:00Z", "url": "u", "title": "t"}]}}
        pins = [{"item_key": "HUB-2", "bucket": 2, "rationale": "promised"}]
        issues = [issue("HUB-3", "unstarted", "High", due="2026-09-20"), issue("HUB-4", "unstarted", "High", due="2026-09-21")]
        inp = self.base(plan=plan, pins=pins, issues=issues)
        until = "2026-09-17T00:00:00Z"
        inp.snoozes = [{"item_key": k, "until": until, "ts": "2026-09-16T08:00:00Z"} for k in ("HUB-1", "HUB-2", "HUB-3", "HUB-9")]
        seq = rank.rank(inp)
        self.assertEqual([i["key"] for i in seq["items"]], ["HUB-4"])
        self.assertEqual([(d["key"], d["why"]) for d in seq["decisions"]],
                         [("HUB-1", f"snoozed until {until}"), ("HUB-2", f"snoozed until {until}"), ("HUB-3", f"snoozed until {until}")])
        self.assertEqual([i["key"] for i in rank.rank(self.base(plan=plan, pins=pins, issues=issues))["items"]],
                         ["HUB-1", "HUB-2", "HUB-3", "HUB-4"])

    def test_issues_assigned_to_others_are_not_own(self):
        other = issue("HUB-8", "unstarted", "High", due="2026-09-20"); other["assignee"] = {"id": "someone"}
        seq = rank.rank(self.base(issues=[other]))
        self.assertEqual(seq["items"], [])

    def test_missing_sources_rank_to_empty_not_crash(self):
        inp = rank.RankInputs(linear=None, github=None, slack=None, inbox_plan=None, census=None, pins=[], tenant=T, today=date(2026, 9, 16))
        seq = rank.rank(inp)
        self.assertEqual((seq["items"], seq["triage"], seq["decisions"], seq["tenant"]), ([], [], [], "quantivly"))

    def test_markdown_has_rationale_per_item(self):
        seq = rank.rank(self.base(pins=[{"item_key": "PROMISE-1", "bucket": 2, "rationale": "spoken promise to benoit"}]))
        md = rank.to_markdown(seq)
        self.assertIn("PROMISE-1", md); self.assertIn("spoken promise to benoit", md)


class RankCommandTests(unittest.TestCase):
    def ctx(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        ns = argparse.Namespace(tenant="quantivly", state_dir=str(Path(tmp.name)), text=False, dry_run=False)
        ctx = context.Context.from_namespace(ns, cfg_base=FIX, runner=FakeRunner([]), env={"PATH": "/bin"}, cwd=Path("/"), today=date(2026, 9, 16))
        self.addCleanup(ctx.close)
        return ctx

    def test_compute_sequence_hands_rank_only_the_snoozes_active_now(self):
        # DO-874: an expired snooze is still a row and no longer hides anything; a live one does.
        ctx = self.ctx()
        snapshots.write(ctx.state_dir, "linear", {"ok": True, "viewer": {"id": "me"},
                                                  "issues": [issue("HUB-3", "unstarted", "High", due="2026-09-20")], "notifications": []})
        ctx.store.set_snooze("quantivly", "HUB-3", "2000-01-01T00:00:00Z")
        self.assertEqual([i["key"] for i in rank_cmd.compute_sequence(ctx)["items"]], ["HUB-3"])
        ctx.store.set_snooze("quantivly", "HUB-3", "2999-01-01T00:00:00Z")
        seq = rank_cmd.compute_sequence(ctx)
        self.assertEqual(seq["items"], [])
        self.assertEqual([(d["key"], d["why"]) for d in seq["decisions"]], [("HUB-3", "snoozed until 2999-01-01T00:00:00Z")])

    def test_run_rank_writes_sequence_files_and_failed_sources(self):
        ctx = self.ctx()
        snapshots.write(ctx.state_dir, "linear", {"ok": True, "viewer": {"id": "me"}, "notifications": [],
                                                   "issues": [issue("HUB-7", "unstarted", "High", due="2026-09-20")]})
        ctx.store.record_sync("quantivly", "linear", True, None, "p")
        ctx.store.record_sync("quantivly", "calendar", False, "connector timed out", "")
        ctx.store.set_pin("quantivly", "PROMISE-1", 2, "spoken promise")
        rep = rank_cmd.run_rank(ctx)
        day = ctx.state_dir / "2026-09-16"
        seq = json.loads((day / "sequence.json").read_text())
        self.assertEqual(rep["path"], str(day / "sequence.json"))
        self.assertEqual(rep["items"], 2)
        self.assertEqual(seq["failed_sources"], ["calendar"])
        self.assertEqual([i["key"] for i in seq["items"]], ["PROMISE-1", "HUB-7"])
        self.assertIn("HUB-7", (day / "sequence.md").read_text())

    def test_dry_run_rank_writes_nothing(self):
        ctx = self.ctx(); ctx.dry_run = True
        snapshots.write(ctx.state_dir, "linear", {"ok": True, "viewer": {"id": "me"}, "notifications": [],
                                                   "issues": [issue("HUB-7", "unstarted", "High", due="2026-09-20")]})
        rep = rank_cmd.run_rank(ctx)
        day = ctx.state_dir / "2026-09-16"
        self.assertFalse(day.exists())
        self.assertIsNone(rep["path"])
        self.assertEqual(rep["items"], 1)   # still computed
        self.assertEqual(rep["dry_run"], "nothing written (sequence.json, sequence.md)")

    def test_registered_value_in_ranked_data_never_reaches_sequence_files(self):
        # k2, third route: ranked data carrying a protected value used to land in sequence.json and
        # sequence.md through two Path.write_text calls that skipped the guard emit.write_file exists
        # for. inbox-plan.json is written by the skill in-session, outside every guard rabota has, so
        # it is the input that can still carry one. Nothing may be written; the leak names no value.
        minted = "minted-gho-token-0123456789abcdef"
        secrets.register_value(minted); self.addCleanup(secrets.REGISTERED_VALUES.discard, minted)
        ctx = self.ctx()
        snapshots.write(ctx.state_dir, "linear", {"ok": True, "viewer": {"id": "me"}, "notifications": [], "issues": []})
        plan = {"buckets": {"reply_queue": [{"issue_identifier": "HUB-1", "actor": "benoit", "created_at": "2026-09-15T00:00:00Z",
                                             "url": "u", "title": f"gh said: token {minted} rejected"}]}}
        (ctx.state_dir / "inbox-plan.json").write_text(json.dumps(plan))
        day = ctx.state_dir / "2026-09-16"
        with self.assertRaises(errors.SecretLeak) as cm:
            rank_cmd.run_rank(ctx)
        self.assertNotIn(minted, str(cm.exception))
        self.assertFalse((day / "sequence.json").exists(), "sequence.json was written with a protected value in it")
        self.assertFalse((day / "sequence.md").exists(), "sequence.md was written with a protected value in it")

    def test_pin_rationale_with_a_protected_value_is_redacted_at_the_store(self):
        # The pin route is closed one layer earlier: the store redacts, so the rationale that reaches
        # sequence.json is the marker, and the rank still completes.
        minted = "minted-gho-token-0123456789abcdef"
        secrets.register_value(minted); self.addCleanup(secrets.REGISTERED_VALUES.discard, minted)
        ctx = self.ctx()
        ctx.store.set_pin("quantivly", "PROMISE-1", 2, f"spoken promise; token {minted}")
        rank_cmd.run_rank(ctx)
        text = (ctx.state_dir / "2026-09-16" / "sequence.json").read_text()
        self.assertNotIn(minted, text); self.assertIn("spoken promise; token [redacted:minted-token]", text)

    def test_inputs_signature_moves_with_every_input_rank_reads(self):
        # DO-738: establish the input list from `rank`'s own code (RankInputs), not from the issue
        # text. Each assertion changes exactly ONE thing `rank` reads and checks the signature
        # moves; anything `inputs_signature` forgot to read would leave that one assertion looking
        # at two identical dicts.
        ctx = self.ctx()
        base = rank_cmd.inputs_signature(ctx)

        snapshots.write(ctx.state_dir, "linear", {"ok": True, "viewer": {}, "issues": [], "notifications": []})
        self.assertNotEqual(rank_cmd.inputs_signature(ctx)["linear"], base["linear"])

        snapshots.write(ctx.state_dir, "github", {"ok": True, "review_requests": [], "own_prs": []})
        self.assertNotEqual(rank_cmd.inputs_signature(ctx)["github"], base["github"])

        (ctx.state_dir / "inbox-plan.json").write_text(json.dumps({"generated_at": "2026-09-16T08:00:00Z"}))
        self.assertNotEqual(rank_cmd.inputs_signature(ctx)["inbox_plan"], base["inbox_plan"])

        (ctx.state_dir / "census.json").write_text(json.dumps({"at": "2026-09-16T08:00:00Z"}))
        self.assertNotEqual(rank_cmd.inputs_signature(ctx)["census"], base["census"])

        # The pins table: a `set_pin` moves it, and so does a `clear_pin` -- the case an mtime or a
        # hash of the rows would miss (see test_store's pins_version test for why).
        ctx.store.set_pin("quantivly", "PROMISE-1", 2, "spoken promise")
        after_set = rank_cmd.inputs_signature(ctx)
        self.assertNotEqual(after_set["pins"], base["pins"])
        ctx.store.clear_pin("quantivly", "PROMISE-1")
        self.assertNotEqual(rank_cmd.inputs_signature(ctx)["pins"], after_set["pins"])

        # The snoozes (DO-874): a `set_snooze` moves it, a `clear_snooze` moves it, and so does the
        # CLOCK passing a snooze's `until` with no write at all -- which is why the term is the
        # active set as a value and not a counter like the pins'.
        ctx.store.set_snooze("quantivly", "SNOOZED-1", "2999-01-01T00:00:00Z")
        after_snooze = rank_cmd.inputs_signature(ctx)
        self.assertNotEqual(after_snooze["snoozes"], base["snoozes"])
        with mock.patch("rabota.commands.rank.now", return_value="2999-01-01T00:00:00Z"):
            self.assertNotEqual(rank_cmd.inputs_signature(ctx)["snoozes"], after_snooze["snoozes"])
        ctx.store.clear_snooze("quantivly", "SNOOZED-1")
        self.assertNotEqual(rank_cmd.inputs_signature(ctx)["snoozes"], after_snooze["snoozes"])

    def test_inputs_signature_ignores_slack_because_rank_never_reads_it(self):
        # `RankInputs.slack` is filled in by `compute_sequence` but `rank.rank` never dereferences
        # it (grep-verified against rank.py) -- a Slack snapshot landing cannot change the ranked
        # answer, so fingerprinting it would re-rank (and rewrite sequence.json/.md) for nothing.
        ctx = self.ctx()
        before = rank_cmd.inputs_signature(ctx)
        snapshots.write(ctx.state_dir, "slack", {"ok": True, "items": []})
        self.assertEqual(rank_cmd.inputs_signature(ctx), before)

    def test_inputs_signature_is_stable_when_nothing_moved(self):
        ctx = self.ctx()
        snapshots.write(ctx.state_dir, "linear", {"ok": True, "viewer": {}, "issues": [], "notifications": []})
        ctx.store.set_pin("quantivly", "PROMISE-1", 2, "spoken promise")
        self.assertEqual(rank_cmd.inputs_signature(ctx), rank_cmd.inputs_signature(ctx))

    def test_compute_sequence_stamps_the_current_inputs_signature(self):
        ctx = self.ctx()
        seq = rank_cmd.compute_sequence(ctx)
        self.assertEqual(seq["inputs"], rank_cmd.inputs_signature(ctx))
