"""gh CLI wrapper. Identity is pinned by a token minted per client (F14); GET /user confirms it.

Every ``gh`` call runs with the env this client builds: the ambient gh token names dropped,
``GH_CONFIG_DIR`` set to the tenant's, and the first gh token name set to a value minted
through ``gh auth token --user <login>`` under that config dir (the ``_gh_user_token``
precedent in ``zsh/functions/github.sh``). The minted value is registered with
``secrets.register_value`` so ``assert_clean`` refuses any output carrying it. Callers pin
positively with ``whoami`` before believing an empty result: under the wrong identity a
private queue reads as empty and a write 404s as "missing".
"""
import json
from datetime import date, timedelta
from pathlib import Path

from rabota import errors, secrets

SEARCH_FIELDS = "repository,number,url,title,author,updatedAt,isDraft"
MERGED_FIELDS = "repository,number,url,title,closedAt"
PR_VIEW_FIELDS = "reviews,mergeable,reviewDecision,headRefName,baseRefName,isDraft"
SEARCH_LIMIT = "100"
MINT_TIMEOUT = 20
CALL_TIMEOUT = 120
STDERR_EXCERPT = 300


class GhClient:
    """One GitHub identity: a scrubbed env with a minted token, and the reads ``sync`` and ``preflight`` need."""

    def __init__(self, runner, env: dict, config_dir: Path | None, login: str):
        self.runner, self.login = runner, login
        base = secrets.scrub_env(env, set={"GH_CONFIG_DIR": str(config_dir)} if config_dir else None)
        if not login:
            raise errors.Refused("tenant has no gh_login; cannot pin a GitHub identity")
        mint = runner.run(["gh", "auth", "token", "--user", login], env=base, timeout=MINT_TIMEOUT)
        token = (mint.out or "").strip()
        if not mint.ok or not token:
            raise errors.Refused(f"could not mint a gh token for {login!r} in {config_dir}: "
                                 f"{(mint.err or '').strip()[:120] or 'empty output'} — run `gh auth login` there")
        secrets.register_value(token)
        self.env = secrets.scrub_env(base, set={secrets.UNSET_FOR_GH[0]: token})

    @classmethod
    def from_context(cls, ctx) -> "GhClient":
        return cls(ctx.runner, ctx.env, ctx.tenant.gh_config_dir, ctx.tenant.gh_login or "")

    def _run(self, argv: list[str], timeout: float = CALL_TIMEOUT) -> str:
        """Run ``argv`` under the client's env and return stdout; a non-zero exit is a ``RabotaError`` with stderr."""
        res = self.runner.run(argv, env=self.env, timeout=timeout)
        if not res.ok:
            raise errors.RabotaError(f"{' '.join(argv[:3])} failed: {res.err.strip()[:STDERR_EXCERPT]}")
        return res.out

    def _run_json(self, argv: list[str]):
        """``_run`` plus a JSON parse; output that is not JSON is a ``RabotaError`` naming the command."""
        out = self._run(argv)
        try:
            return json.loads(out)
        except json.JSONDecodeError as e:
            raise errors.RabotaError(f"{' '.join(argv[:3])} printed non-JSON output: {e.msg}") from None

    def api(self, path: str, *, jq: str | None = None, paginate: bool = False):
        """``gh api <path>`` parsed as JSON; with ``jq`` a bare scalar (gh prints strings unquoted) is returned as-is."""
        argv = ["gh", "api", path]
        if paginate:
            argv.append("--paginate")
        if jq:
            argv += ["--jq", jq]
        out = self._run(argv)
        if not out.strip():
            return None
        try:
            return json.loads(out)
        except json.JSONDecodeError:
            if jq:
                return out.strip()
            raise errors.RabotaError(f"gh api {path} printed non-JSON output") from None

    def whoami(self) -> str:
        """The login the minted token resolves to — the positive pin, from a real request."""
        return self.api("user", jq=".login")

    def _search_prs(self, *flags: str, fields: str = SEARCH_FIELDS) -> list[dict]:
        return self._run_json(["gh", "search", "prs", *flags, "--limit", SEARCH_LIMIT, "--json", fields])

    def review_requests(self) -> list[dict]:
        """Open PRs requesting my review, each resolved to individually-requested vs via a team."""
        out = []
        for pr in self._search_prs("--review-requested=@me", "--state=open"):
            repo, n = pr["repository"]["nameWithOwner"], pr["number"]
            rr = self.api(f"repos/{repo}/pulls/{n}/requested_reviewers") or {"users": [], "teams": []}
            out.append({"repo": repo, "number": n, "url": pr["url"], "title": pr["title"],
                        "author": pr["author"]["login"], "updatedAt": pr["updatedAt"], "isDraft": pr["isDraft"],
                        "requested_individually": any(u["login"] == self.login for u in rr.get("users", [])),
                        "via_teams": [t["slug"] for t in rr.get("teams", [])]})
        return out

    def own_prs(self) -> list[dict]:
        """My open PRs with approvers, mergeability and review decision from ``gh pr view``."""
        out = []
        for pr in self._search_prs("--author=@me", "--state=open"):
            repo, n = pr["repository"]["nameWithOwner"], pr["number"]
            view = self._run_json(["gh", "pr", "view", str(n), "--repo", repo, "--json", PR_VIEW_FIELDS])
            approved = sorted({r["author"]["login"] for r in view.get("reviews", []) if r.get("state") == "APPROVED"})
            out.append({"repo": repo, "number": n, "url": pr["url"], "title": pr["title"], "isDraft": view["isDraft"],
                        "mergeable": view.get("mergeable"), "reviewDecision": view.get("reviewDecision"),
                        "approved_by": approved, "headRefName": view["headRefName"], "baseRefName": view["baseRefName"]})
        return out

    def merged_recent(self, days: int = 30) -> list[dict]:
        """My PRs merged in the last ``days`` days; ``gh search`` exposes ``closedAt``, which is the
        merge time. ``title`` (DO-735 review, F2) is what lets ``reconcile.py`` carry a merged PR's
        title into its ``pr_links`` entry — the signal ``reconcile.md``'s g07 case is decided from."""
        since = (date.today() - timedelta(days=days)).isoformat()
        raw = self._search_prs("--author=@me", "--merged", f"--merged-at=>={since}", fields=MERGED_FIELDS)
        return [{"repo": p["repository"]["nameWithOwner"], "number": p["number"], "url": p["url"],
                 "title": p["title"], "mergedAt": p["closedAt"]}
                for p in raw]
