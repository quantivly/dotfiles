"""The tracked-side index reconcile needs, built from ``sources/linear.json`` and ``sources/github.json``
(DO-716 move 4).

**Why this exists.** Turn 1 of ``/rabota brief`` cannot know a commitment's tracked counterpart —
Slack and Calendar are not fetched yet (see ``commands.brief.compute_needs``), and Fireflies,
though fetched server-side by the timer since DO-746, is not yet classified: its items reach
``needs`` unclassified, the same way a stale Slack/Calendar entry does. So pairing a commitment
with what Linear/GitHub say has to wait for turn 2, where the agent has just fetched or been
handed the connector items.

**What it is not.** It does not fetch anything itself, and it does not do the classification —
that stays model judgement (``reconcile.md``). It is the haystack, not the needle.

**DO-751: this module's projection no longer rides in turn 1's JSON reply at all.**
``build_tracked_index`` builds the whole-tenant projection below and is kept — ``snapshot_health``
still calls it, and so does ``lookup_tracked`` — but ``commands.brief.run_brief`` stopped returning
it once @zvi's real tenant (~908 open assigned-or-created issues) measured it at ~303 KB
synthetically scaled to that count (110 with a PR attachment, 20 open PRs, 100 merged;
``tests/test_reconcile_index.py``'s ``TrackedIndexLiveScaleTests``) — about 75x the ~4 KB reference
point this module's docstring used to cite as "small," and climbing linearly with the tenant's
open-issue count, never bounded by what a turn-2 classification pass actually needs to look at
(typically single digits of subjects). ``lookup_tracked`` (below) answers ``rabota tracked
<key>...`` instead: the same per-item projection, cut to exactly the keys a caller names, at the
cost of one more CLI call turn 2 already has the connector items to make. See ``reconcile.md`` for
the turn-2 contract and ``lookup_tracked``'s docstring for the "not found" vs "unknown" split that
answers the same question ``build_tracked_index``'s per-side ``ok``/``reason`` always has.

**Missing or unreadable snapshots.** Following the precedent ``compute_needs`` set (#237): an
unreadable or absent snapshot is an empty side of the index plus a ``reason``, never an exception —
the brief must still print. A *stale* snapshot is not the same thing: the data is still the best
the CLI has, so it is returned as-is with a ``reason`` noting its age, not suppressed.
"""
import re
from datetime import datetime, timezone

from rabota import errors, snapshots
from rabota.snapshots import STALE_AFTER_MIN
from rabota.sources.linear import LinearClient
# One definition, in `snapshots` -- see the comment there for why it is not restated here.

# DO-735: a GitHub-integration attachment's URL path, not its (undocumented) `metadata`, is what
# tells a PR attachment apart from a plain GitHub Issue one — see sources/linear.py's schema notes.
_GITHUB_PR_URL = re.compile(r"^https://github\.com/([^/\s]+/[^/\s]+)/pull/(\d+)")

# A Linear identifier: team key, dash, number (``HUB-5812``, ``CORE-561``). A GitHub PR/issue key
# built by this module is always ``owner/repo#n`` and so always contains ``#`` -- the two shapes
# never collide, which is what lets `classify_subject` route on shape alone (DO-751).
_LINEAR_KEY = re.compile(r"^[A-Z][A-Z0-9]*-\d+$")


def classify_subject(key: str) -> str:
    """``"linear"``/``"github"``/``"other"`` -- which side of the tracked index, if any, a
    commitment's subject could be looked up against. A person-plus-topic subject (a Slack thread, a
    Fireflies transcript) is ``"other"``: `reconcile.md` verifies those two classes
    (``question-owed``/``spoken-already-done``) against the connector artifact itself, never
    against Linear or GitHub, so `lookup_tracked` never looks one up at all."""
    key = normalize_subject(key)
    if "#" in key:
        return "github"
    if _LINEAR_KEY.match(key):
        return "linear"
    return "other"


_LINEAR_URL = re.compile(r"^https://linear\.app/[^/\s]+/issue/([A-Za-z][A-Za-z0-9]*-\d+)(?:/|$)")
_LINEAR_KEY_ANY_CASE = re.compile(r"^[A-Za-z][A-Za-z0-9]*-\d+$")
_STRAY = "\"'`()[]{}<>.,;:!?"


def normalize_subject(key: str) -> str:
    """The canonical form of a subject an agent copied out of free text (DO-751 review).

    Surrounding quotes, brackets and punctuation are stripped (``HUB-5812,`` from a Slack line), a
    GitHub PR URL becomes ``owner/repo#n``, a Linear issue URL becomes its identifier, and a Linear
    identifier is upper-cased (``hub-5812``). Anything else is returned stripped but otherwise as
    given, so an unrecognised subject still reads as ``other``, never as a guessed key."""
    key = (key or "").strip().strip(_STRAY)
    m = _GITHUB_PR_URL.match(key)
    if m:
        return f"{m.group(1)}#{m.group(2)}"
    m = _LINEAR_URL.match(key)
    if m:
        return m.group(1).upper()
    if _LINEAR_KEY_ANY_CASE.match(key):
        return key.upper()
    return key


def _pr_links(issue: dict) -> list[dict] | None:
    """``[{"key", "url", "state", "title"}]`` per GitHub-PR attachment on ``issue``, or ``None``
    when the snapshot predates DO-735 (no ``attachments`` key at all — never confuse that with
    "checked, and there are none"). ``state`` starts ``"unknown"``; ``build_tracked_index`` fills
    in ``"open"``/``"merged"`` from ``sources/github.json`` where it can, carrying that PR's title
    along with it (``title`` stays ``None`` until then — see review finding F2: it is the signal
    ``reconcile.md``'s g07 case needs, since ``key`` is always ``owner/repo#n`` and can never name
    "a different issue").

    Review finding F1: matching used to also require ``sourceType == "github"``. Measured live on
    @zvi's Linear tenant, 123 attachment URLs contain ``/pull/`` but only 117 carry
    ``sourceType: "github"`` — the rest are ``api``/``oauthClient`` (still the GitHub integration,
    just a different attachment-creation path), and those issues read as ``pr_links: []``, "no PR
    linked", which is exactly the false claim DO-735 exists to prevent. The URL already anchors on
    ``^https://github\\.com/.../pull/<n>``, which is sourceType-agnostic and sufficient on its own;
    ``sourceType`` is not read anywhere else in this module and is otherwise unused now."""
    if "attachments" not in issue:
        return None
    links = []
    for a in issue["attachments"] or []:
        m = _GITHUB_PR_URL.match(a.get("url") or "")
        if m:
            links.append({"key": f"{m.group(1)}#{m.group(2)}", "url": a["url"], "state": "unknown", "title": None})
    return links


def _linear_side(state_dir, now: datetime) -> dict:
    """``{"ok", "reason", "issues"}`` — one slim record per Linear issue, or an empty list plus a reason."""
    try:
        snap = snapshots.read(state_dir, "linear")
    except Exception as e:  # noqa: BLE001 — an unreadable file must not cost the whole brief; see module docstring
        return {"ok": False, "reason": f"unreadable ({type(e).__name__})", "issues": []}
    if snap is None:
        return {"ok": False, "reason": "never synced", "issues": []}
    if not isinstance(snap, dict) or not isinstance(snap.get("issues"), list):
        return {"ok": False, "reason": "unreadable (not the expected shape)", "issues": []}
    issues = [{"key": i.get("identifier"), "title": i.get("title"), "url": i.get("url"),
               "state": (i.get("state") or {}).get("name"), "state_type": (i.get("state") or {}).get("type"),
               "priority_label": i.get("priorityLabel"), "due_date": i.get("dueDate"),
               "updated_at": i.get("updatedAt"), "blocked_by": i.get("blockedBy") or [],
               "blocks": i.get("blocks") or [], "pr_links": _pr_links(i)}
              for i in snap["issues"]]
    fresh_ok, reason = _age_verdict(snap, now)
    ok = bool(snap.get("ok", True)) and fresh_ok
    if not snap.get("ok", True):
        reason = snap.get("error") or "last sync failed"
    return {"ok": ok, "reason": reason, "issues": issues}


def _resolve_pr_states(linear_side: dict, github_side: dict) -> None:
    """Fill each issue's ``pr_links[*]["state"]``/``["title"]`` in from ``own_prs``/``merged_recent``
    by ``key``, in place. Only ``own_prs`` (my open PRs) and ``merged_recent`` (my recent merges) are
    consulted — a colleague's PR, one closed without merging, or one merged outside the
    ``merged_recent`` window has no tracked-side confirmation, so it stays ``"unknown"``/``None``
    rather than being guessed at from Linear's own (undocumented) attachment metadata. No live
    cross-org GitHub search: see the module docstring on cost.

    ``title`` (F2) is what ``reconcile.md``'s g07 case is actually decided from: a ``pr_links``
    entry whose ``key`` is ``owner/repo#n`` can never "name a different issue" than the Linear issue
    it's attached to (``key`` has no Linear identifier in it at all) — the PR's *title* is the only
    field here that can read as belonging to a different piece of work."""
    own_by_key = {p["key"]: p for p in github_side.get("own_prs", [])}
    merged_by_key = {p["key"]: p for p in github_side.get("merged_recent", [])}
    for issue in linear_side.get("issues", []):
        for link in issue.get("pr_links") or []:
            if link["key"] in merged_by_key:
                link["state"] = "merged"
                link["title"] = merged_by_key[link["key"]].get("title")
            elif link["key"] in own_by_key:
                link["state"] = "open"
                link["title"] = own_by_key[link["key"]].get("title")


def _github_side(state_dir, now: datetime) -> dict:
    """``{"ok", "reason", "own_prs", "merged_recent"}`` — the two lists that carry review/merge state."""
    try:
        snap = snapshots.read(state_dir, "github")
    except Exception as e:  # noqa: BLE001 — same reasoning as `_linear_side`
        return {"ok": False, "reason": f"unreadable ({type(e).__name__})", "own_prs": [], "merged_recent": []}
    if snap is None:
        return {"ok": False, "reason": "never synced", "own_prs": [], "merged_recent": []}
    if not isinstance(snap, dict) or not isinstance(snap.get("own_prs"), list) or not isinstance(snap.get("merged_recent"), list):
        return {"ok": False, "reason": "unreadable (not the expected shape)", "own_prs": [], "merged_recent": []}
    own_prs = [{"key": f"{p.get('repo')}#{p.get('number')}", "url": p.get("url"), "title": p.get("title"),
                "review_decision": p.get("reviewDecision"), "mergeable": p.get("mergeable"),
                "approved_by": p.get("approved_by") or []}
               for p in snap["own_prs"]]
    merged = [{"key": f"{p.get('repo')}#{p.get('number')}", "url": p.get("url"), "title": p.get("title"),
               "merged_at": p.get("mergedAt")}
              for p in snap["merged_recent"]]
    fresh_ok, reason = _age_verdict(snap, now)
    ok = bool(snap.get("ok", True)) and fresh_ok
    if not snap.get("ok", True):
        reason = snap.get("error") or "last sync failed"
    return {"ok": ok, "reason": reason, "own_prs": own_prs, "merged_recent": merged}


def _age_verdict(snap: dict, now: datetime) -> tuple[bool, str | None]:
    """``(trustworthy, reason)`` from a snapshot's ``fetched_at``.

    Review finding: ``ok`` used to be copied straight from the snapshot, so a side could come back
    ``ok: True`` with ``reason`` saying its timestamp was unreadable, and a ``fetched_at`` in the
    future came back with no reason at all. **``ok`` has to mean "you can rely on this"**, or a
    caller that checks only ``ok`` -- which is the cheap and obvious thing to check -- is misled.
    So an unreadable timestamp and a timestamp in the future are both ``False`` here: one means we
    cannot tell how old the data is, the other means a clock is wrong, and neither is a basis for
    relying on it. Merely stale stays trustworthy -- old data is still data, which is why it comes
    back with a reason rather than emptied.
    """
    try:
        fetched = snapshots.parse_fetched_at(snap["fetched_at"])
    except (ValueError, TypeError, KeyError):
        return False, "unreadable (fetched_at is not a UTC timestamp)"
    age_min = (now - fetched).total_seconds() / 60
    if age_min < 0:
        return False, f"fetched_at is {int(-age_min)} min in the future (clock skew?)"
    return True, (f"stale ({int(age_min)} min old)" if age_min > STALE_AFTER_MIN else None)


def build_tracked_index(ctx, now: datetime | None = None) -> dict:
    """``{"linear", "github"}``: the tracked-side facts reconcile's six classes ask for.

    Included because a class needs it: ``state``/``state_type`` (``state-contradiction``),
    ``blocked_by``/``blocks`` (``stale-blocked``), ``review_decision``/``mergeable`` (``tracked-satisfied``,
    the ``stale-blocked`` "BEHIND + REVIEW_REQUIRED" case), ``merged_recent`` (confirming a
    ``tracked-satisfied`` PR actually landed). Every Linear issue and PR title/key is also the
    haystack ``promised-untracked`` searches to confirm nothing tracks a commitment.

    ``pr_links`` (DO-735) is what lets ``state-contradiction`` tell "no PR exists" (``[]``) apart
    from "a PR is linked" (a non-empty list, ``state`` one of ``"open"``/``"merged"``/``"unknown"``,
    ``title`` the matched PR's title or ``None`` — see ``_resolve_pr_states``) and from "this
    snapshot predates attachment sync" (``None``, never read as "no PR"). It never claims cross-org
    search: a colleague's PR or one outside ``own_prs``/``merged_recent`` reads as linked with
    ``state: "unknown"``, not as absent. Matching (F2, review of DO-735) is on the attachment's URL
    alone, not its ``sourceType`` — a live tenant has GitHub ``/pull/`` attachments whose
    ``sourceType`` is ``api``/``oauthClient``, not ``github``, and those are real PR links too.
    ``title`` is what a ``state-contradiction`` reader checks against the issue's own subject to
    notice a linked PR belongs to different work entirely (golden ``g07``) — ``key`` cannot do
    this, since it is always ``owner/repo#n`` and never carries a Linear identifier.

    Left out on purpose: issue descriptions (reconcile.md itself says relations outrank
    description prose), Linear notifications and GitHub ``review_requests`` (no class needs
    them — they answer "what's requesting MY attention", not "what does the tracked side say
    about a commitment"). A tenant that does not list a source gets that side back as
    ``{"ok": False, "reason": "tenant does not use this source", ...}`` — mirroring the skip
    ``compute_needs`` already applies to ``NEEDS_SOURCES``.

    ``spoken-already-done`` and ``question-owed`` never consult this index at all: both are
    verified against the connector artifact itself (a Slack ``ts``, a transcript id), never
    against Linear or GitHub. See the verdict for which of the six classes this index cannot
    fully decide.
    """
    now = now or datetime.now(timezone.utc)
    sources = getattr(ctx.tenant, "sources", [])
    # `skipped` rather than only a reason string: review finding, a source the tenant does not use
    # was indistinguishable from a real failure to a caller checking `ok` alone, which is the cheap
    # and obvious check. `preflight` already marks this case `{"ok": True, "skipped": True}`; the
    # flag is carried here too so the two agree, while `ok` stays False because there is no data.
    linear = (_linear_side(ctx.state_dir, now) if "linear" in sources
              else {"ok": False, "skipped": True, "reason": "tenant does not use this source", "issues": []})
    github = (_github_side(ctx.state_dir, now) if "github" in sources
              else {"ok": False, "skipped": True, "reason": "tenant does not use this source",
                    "own_prs": [], "merged_recent": []})
    _resolve_pr_states(linear, github)
    return {"linear": linear, "github": github}


def snapshot_health(ctx, now: datetime | None = None) -> list[dict]:
    """``[{"source", "reason"}]`` for each of ``linear``/``github`` the CLI cannot rely on.

    Cheap on purpose: it reads the two files but projects nothing, so both ``--text`` and JSON can
    call it on every brief. Review finding: `--text` never noticed an unreadable
    ``sources/linear.json`` at all once the day's ``sequence.json`` existed -- only JSON mode's
    ``tracked`` revalidated it -- so the brief could rank on a corrupt snapshot and say nothing. A
    source the tenant does not use is not a health problem and is never reported.
    """
    now = now or datetime.now(timezone.utc)
    index = build_tracked_index(ctx, now)
    return [{"source": source, "reason": side["reason"] or "unreliable"}
            for source, side in index.items()
            if not side["ok"] and not side.get("skipped")]


def lookup_tracked(ctx, keys: list[str], now: datetime | None = None, lin=None) -> dict:
    """``{"linear": {"ok", "reason"}, "github": {"ok", "reason"}, "results": [...]}`` for exactly
    ``keys`` (DO-751) -- what ``rabota tracked <key>...`` answers, and what turn 2 calls instead of
    reading a whole-tenant index out of turn 1's ``brief`` reply. Built from the same per-issue/PR
    projection ``build_tracked_index`` computes (so a lookup can never disagree with it about what
    a field means), then cut to the handful of subjects a caller is actually classifying, which is
    what keeps this cheap where returning the whole index is not: one CLI call, and a byte cost
    proportional to the keys asked for rather than to the tenant's issue count.

    Each result is exactly one of:

    - ``{"key", "status": "found", "kind": "linear"|"github", "record": {...}}`` -- the same record
      shape ``build_tracked_index`` returns for that item (an issue dict with ``pr_links``, or a PR
      dict tagged with ``kind: "own_pr"``/``"merged_recent"``).
    - ``{"key", "status": "not_found", "kind": "linear"|"github"}`` -- the source is trustworthy
      (``ok`` true) and simply does not name this subject *among what that source fetches*: for
      Linear, the open-issue snapshot (see below); for GitHub, own open PRs plus merges in the
      last 30 days -- an older merge, or a colleague's PR, reads ``not_found`` too, a known gap
      `reconcile.md` names rather than a network call fixes. ``kind`` is what lets a caller (and
      `commands.tracked._text_line`) say which, instead of the single "does not name this
      subject" that DO-754 found could be misread as "does not exist".
    - ``{"key", "status": "found_closed", "kind": "linear", "state": {"name", "type"},
      "completed_at"}`` -- DO-754: a Linear identifier the open-issue snapshot doesn't carry
      (``sync`` fetches only ``assigned_open``/``created_open``, both excluding
      ``dead_state_types``) but that Linear, checked with one batched read-only query (below),
      still has on file. **Never treat this as absence** -- for `promised-untracked` it means
      "already done" (or otherwise resolved), not "untracked"; see `reconcile.md` for what it means
      for the other classes.
    - ``{"key", "status": "unknown", "reason"}`` -- the source cannot be relied on (unsynced,
      unreadable, the tenant does not use it, or -- DO-754 -- the batched Linear lookup below could
      not be made or failed), so absence here proves nothing. **Never conflate this with
      ``not_found``** — that conflation is exactly golden ``g06``'s bug (a pre-attachment snapshot
      read as "no PR exists" rather than "attachments unknown"), one level up: at the per-key
      rather than per-attachment layer.
    - ``{"key", "status": "ambiguous", "candidates"}`` -- an owner-less PR key (``repo#n``)
      matching more than one ``owner/repo#n`` in the index; the candidates are listed, never picked.
    - Any result may carry ``resolved``: the canonical key (see `normalize_subject`) when it differs
      from what was asked.
    - ``{"key", "status": "not_applicable"}`` -- ``key`` is neither a Linear identifier nor a
      ``owner/repo#n`` PR key (see `classify_subject`), i.e. a person-plus-topic subject that
      `reconcile.md` verifies against the connector artifact itself and never against this index.

    A PR key present in both ``own_prs`` and ``merged_recent`` reads as ``merged_recent`` — the
    same precedence `_resolve_pr_states` already gives a merged PR over an open one.

    **DO-754.** Once every key above resolves, ``_resolve_closed`` makes ONE batched, read-only
    ``LinearClient.find_by_identifiers`` call -- but only when at least one result is still
    ``not_found`` and classified ``linear``; a caller whose keys all resolved from the snapshot (or
    named none) costs nothing extra. ``lin`` is an injectable client for tests (same shape as
    ``commands.sync``'s ``lin``/``gh``/``ff`` params); a real run builds ``LinearClient.from_context``
    itself. A dry run does not suppress this call -- it is a read, and ``LinearClient.dry_run`` only
    ever gates a mutation.
    """
    now = now or datetime.now(timezone.utc)
    index = build_tracked_index(ctx, now)
    linear_side, github_side = index["linear"], index["github"]
    linear_by_key = {i["key"]: i for i in linear_side.get("issues", [])}
    github_by_key = {}
    for p in github_side.get("own_prs", []):
        github_by_key[p["key"]] = {"kind": "own_pr", **p}
    for p in github_side.get("merged_recent", []):     # merged wins over open — see docstring
        github_by_key[p["key"]] = {"kind": "merged_recent", **p}

    results = []
    canon_of = {}
    for key in keys:
        subject = classify_subject(key)
        canon = normalize_subject(key)
        side = linear_side if subject == "linear" else github_side if subject == "github" else None
        by_key = linear_by_key if subject == "linear" else github_by_key
        if subject == "github" and "/" not in canon.split("#")[0]:
            # `sre-core#1473` with no owner: the index is keyed `owner/repo#n`, so an exact lookup
            # would answer not_found for a PR that is there (DO-751 review). Resolve by a unique
            # suffix; more than one match is reported, never picked.
            matches = [k for k in by_key if k.endswith("/" + canon)]
            if len(matches) > 1:
                results.append({"key": key, "status": "ambiguous", "candidates": sorted(matches)})
                continue
            if matches:
                canon = matches[0]
        resolved = {} if canon == key else {"resolved": canon}
        canon_of[key] = canon
        if subject == "other":
            results.append({"key": key, "status": "not_applicable"})
        elif canon in by_key:
            results.append({"key": key, **resolved, "status": "found", "kind": subject, "record": by_key[canon]})
        elif not side["ok"]:
            results.append({"key": key, "status": "unknown", "reason": side["reason"]})
        else:
            results.append({"key": key, **resolved, "status": "not_found", "kind": subject})
    _resolve_closed(ctx, results, canon_of, lin)
    return {"linear": {"ok": linear_side["ok"], "reason": linear_side["reason"]},
            "github": {"ok": github_side["ok"], "reason": github_side["reason"]},
            "results": results}


def _resolve_closed(ctx, results: list[dict], canon_of: dict, lin) -> None:
    """DO-754: rewrite each still-``not_found`` Linear-classified result in ``results`` in place,
    with ONE batched, read-only ``LinearClient.find_by_identifiers`` call naming exactly those
    identifiers -- never a call per key, and never a call at all when nothing is pending (the
    common case: most keys resolve from the snapshot). ``lin`` is used if given (tests); otherwise
    a real client is built from ``ctx`` on demand, so a tenant with no Linear key configured, or a
    request that fails outright, never reaches the wire and downgrades every pending key to
    ``unknown`` instead -- a failed or refused call proves nothing about whether the issue exists,
    so it must never read as the ``not_found`` `promised-untracked` takes as proof of absence.
    """
    pending = [r for r in results if r["status"] == "not_found" and r.get("kind") == "linear"]
    if not pending:
        return
    idents = sorted({canon_of[r["key"]] for r in pending})
    try:
        client = lin or LinearClient.from_context(ctx)
        # Keyed by the identifier ASKED FOR: a moved issue comes back under its new identifier,
        # and `find_by_identifiers` records which asked key it answers (DO-754 review F2).
        found = {rec.get("asked", rec["identifier"]): rec for rec in client.find_by_identifiers(idents)}
    except Exception as e:  # noqa: BLE001 -- DO-754 review F1: a timeout or any other failure
        # proves nothing about existence, so every pending key reads `unknown`, never `not_found`,
        # and the keys already resolved from the snapshot are kept rather than failing the call.
        msg = str(e) if isinstance(e, errors.RabotaError) else f"{type(e).__name__}: {e}"
        for r in pending:
            r["status"], r["reason"] = "unknown", f"Linear lookup failed: {msg}"
            del r["kind"]
        return
    for r in pending:
        rec = found.get(canon_of[r["key"]])
        if rec:
            r["status"] = "found_closed"
            r["state"] = rec["state"]
            r["completed_at"] = rec.get("completedAt")
            if rec.get("identifier") != canon_of[r["key"]]:
                r["moved_to"] = rec["identifier"]   # the same issue, now under another team's key
