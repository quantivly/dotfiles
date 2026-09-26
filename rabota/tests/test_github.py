import json, unittest
from pathlib import Path
from rabota.sources import github
from rabota.runner import FakeRunner, Result

MINTED = "ghp_" + "m" * 36          # assembled at runtime; not a real token (gitleaks convention)
AMBIENT = "a" * 40
MINT_OK = (["gh", "auth", "token", "--user", "me"], Result(0, MINTED + "\n", ""))


class EnvRecordingRunner(FakeRunner):
    """FakeRunner that also keeps the env each call was given, so the identity rule can be asserted."""
    def __init__(self, responses):
        super().__init__(responses); self.envs = []
    def run(self, argv, *, env=None, **kw):
        self.envs.append(dict(env or {})); return super().run(argv, env=env, **kw)


class GhClientTests(unittest.TestCase):
    def test_env_has_config_dir_and_a_minted_token_not_the_ambient_one(self):
        minted = MINTED
        runner = FakeRunner([(["gh", "auth", "token", "--user", "me"], Result(0, minted + "\n", "")),
                             (["gh", "api", "user"], Result(0, '"me"\n', ""))])
        ambient = github.secrets.UNSET_FOR_GH[0]
        c = github.GhClient(runner, {"PATH": "/bin", ambient: AMBIENT}, Path("/cfg"), "me")
        self.assertEqual(c.whoami(), "me")
        self.assertEqual(c.env["GH_CONFIG_DIR"], "/cfg")
        self.assertEqual(c.env[ambient], minted)                       # minted, not ambient
        self.assertNotIn(AMBIENT, c.env.values())
        with self.assertRaises(github.errors.SecretLeak):              # the minted value is now protected
            github.secrets.assert_clean(f"token is {minted}", {})
        # the minting call itself ran without the ambient token and with the config dir
        self.assertEqual(runner.calls[0][:3], ["gh", "auth", "token"])

    def test_mint_call_env_has_no_ambient_token_and_api_call_env_has_the_minted_one(self):
        runner = EnvRecordingRunner([MINT_OK, (["gh", "api", "user"], Result(0, '"me"\n', ""))])
        ambient, second = github.secrets.UNSET_FOR_GH
        c = github.GhClient(runner, {"PATH": "/bin", ambient: AMBIENT, second: "b" * 40}, Path("/cfg"), "me")
        c.whoami()
        mint_env, api_env = runner.envs
        self.assertEqual(mint_env.get("GH_CONFIG_DIR"), "/cfg")
        self.assertNotIn(ambient, mint_env); self.assertNotIn(second, mint_env)
        self.assertEqual(api_env[ambient], MINTED); self.assertNotIn(second, api_env)

    def test_minting_failure_is_a_refusal_not_an_empty_queue(self):
        runner = FakeRunner([(["gh", "auth", "token", "--user", "me"], Result(1, "", "no oauth token for me"))])
        with self.assertRaises(github.errors.Refused):
            github.GhClient(runner, {"PATH": "/bin"}, Path("/cfg"), "me")

    def test_empty_mint_output_is_a_refusal(self):
        runner = FakeRunner([(["gh", "auth", "token", "--user", "me"], Result(0, "\n", ""))])
        with self.assertRaises(github.errors.Refused):
            github.GhClient(runner, {"PATH": "/bin"}, Path("/cfg"), "me")

    def test_missing_login_is_a_refusal_before_any_process_runs(self):
        runner = FakeRunner([])
        with self.assertRaises(github.errors.Refused):
            github.GhClient(runner, {"PATH": "/bin"}, Path("/cfg"), "")
        self.assertEqual(runner.calls, [])

    def test_review_requests_split_individual_and_team(self):
        search = [{"repository": {"nameWithOwner": "quantivly/hub"}, "number": 1, "url": "u1", "title": "t1",
                   "author": {"login": "alex"}, "updatedAt": "2026-09-15T00:00:00Z", "isDraft": False},
                  {"repository": {"nameWithOwner": "quantivly/sre-core"}, "number": 2, "url": "u2", "title": "t2",
                   "author": {"login": "connor"}, "updatedAt": "2026-09-14T00:00:00Z", "isDraft": False}]
        runner = FakeRunner([
            MINT_OK,
            (["gh", "search", "prs"], Result(0, json.dumps(search), "")),
            (["gh", "api", "repos/quantivly/hub/pulls/1/requested_reviewers"],
             Result(0, json.dumps({"users": [{"login": "me"}], "teams": []}), "")),
            (["gh", "api", "repos/quantivly/sre-core/pulls/2/requested_reviewers"],
             Result(0, json.dumps({"users": [], "teams": [{"slug": "hub-backend"}]}), "")),
        ])
        c = github.GhClient(runner, {"PATH": "/bin"}, None, "me")
        rr = c.review_requests()
        self.assertEqual([(r["repo"], r["requested_individually"], r["via_teams"]) for r in rr],
                         [("quantivly/hub", True, []), ("quantivly/sre-core", False, ["hub-backend"])])
        self.assertEqual(rr[0]["author"], "alex")

    def test_own_prs_collect_approvers_and_merge_state(self):
        search = [{"repository": {"nameWithOwner": "quantivly/hub"}, "number": 7, "url": "u7", "title": "t7",
                   "author": {"login": "me"}, "updatedAt": "2026-09-15T00:00:00Z", "isDraft": False}]
        view = {"reviews": [{"author": {"login": "alex"}, "state": "APPROVED"}, {"author": {"login": "kyle"}, "state": "COMMENTED"}],
                "mergeable": "MERGEABLE", "reviewDecision": "APPROVED", "headRefName": "f", "baseRefName": "main", "isDraft": False}
        runner = FakeRunner([MINT_OK, (["gh", "search", "prs"], Result(0, json.dumps(search), "")),
                             (["gh", "pr", "view", "7", "--repo", "quantivly/hub"], Result(0, json.dumps(view), ""))])
        prs = github.GhClient(runner, {"PATH": "/bin"}, None, "me").own_prs()
        self.assertEqual(prs[0]["approved_by"], ["alex"])
        self.assertEqual((prs[0]["reviewDecision"], prs[0]["baseRefName"]), ("APPROVED", "main"))

    def test_merged_recent_uses_closed_at_as_merged_at(self):
        search = [{"repository": {"nameWithOwner": "o/r"}, "number": 3, "url": "u3", "title": "t3",
                   "closedAt": "2026-09-10T00:00:00Z"}]
        runner = FakeRunner([MINT_OK, (["gh", "search", "prs"], Result(0, json.dumps(search), ""))])
        merged = github.GhClient(runner, {"PATH": "/bin"}, None, "me").merged_recent(days=30)
        self.assertEqual(merged, [{"repo": "o/r", "number": 3, "url": "u3", "title": "t3",
                                   "mergedAt": "2026-09-10T00:00:00Z"}])
        self.assertTrue(any(a.startswith("--merged-at=>=") for a in runner.calls[1]))

    def test_api_failure_raises_with_stderr(self):
        runner = FakeRunner([MINT_OK, (["gh", "api"], Result(1, "", "HTTP 404: Not Found"))])
        with self.assertRaises(github.errors.RabotaError) as cm:
            github.GhClient(runner, {"PATH": "/bin"}, None, "me").api("repos/x/y")
        self.assertIn("404", str(cm.exception))

    def test_api_with_jq_returns_a_bare_string_as_is(self):
        # real `gh api user --jq .login` prints the string unquoted; the fixture above prints it quoted
        runner = FakeRunner([MINT_OK, (["gh", "api", "user"], Result(0, "me\n", ""))])
        self.assertEqual(github.GhClient(runner, {"PATH": "/bin"}, None, "me").whoami(), "me")
