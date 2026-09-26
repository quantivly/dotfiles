"""``rabota tracked <key>...``: the tracked-side facts for exactly the subjects turn 2 is
classifying (DO-751), answered from ``sources/linear.json``/``sources/github.json`` on disk — see
``reconcile.lookup_tracked``.

This replaces reading a whole-tenant index out of turn 1's ``brief`` JSON reply. That index (see
``reconcile.build_tracked_index``) grew linearly with the tenant's open-issue count and measured
~303 KB on a synthetic tenant scaled to @zvi's real one (~908 open issues); a lookup measures
bytes proportional to the keys asked for instead. See ``reconcile.py``'s module docstring and
``claude/skills/rabota/references/reconcile.md`` for the turn-2 contract this command answers.

DO-754: a Linear key the snapshot doesn't carry might just be closed, not nonexistent (``sync``
only fetches open issues) -- when that happens, ``lookup_tracked`` makes ONE batched read-only
Linear query to tell the two apart, so this command is no longer network-free for every call, only
for the common one (every key resolves from the snapshot).
"""
from rabota import cli, errors
from rabota.context import Context
from rabota.reconcile import lookup_tracked


def _text_line(r: dict) -> str:
    if r["status"] == "found":
        rec = r["record"]
        if r["kind"] == "linear":
            return f"{r['key']}: found (linear) — {rec['state']} · {rec['priority_label']}"
        return f"{r['key']}: found (github, {rec['kind']})"
    if r["status"] == "found_closed":
        return f"{r['key']}: found closed (linear) — {r['state']['name']} · completed {r['completed_at']}"
    if r["status"] == "not_found":
        if r["kind"] == "github":
            return f"{r['key']}: not found — not among own open or recently merged PRs"
        return f"{r['key']}: not found — not among open issues synced"
    if r["status"] == "unknown":
        return f"{r['key']}: unknown — {r['reason']}"
    return f"{r['key']}: not applicable — not a Linear issue or owner/repo#n PR key"


def run_tracked(ctx: Context, keys: list[str], lin=None) -> dict:
    return lookup_tracked(ctx, keys, lin=lin)


def _build(sub):
    p = sub.add_parser("tracked", help="tracked-side facts for exactly the named subjects (DO-751)")
    p.add_argument("keys", nargs="+", help="Linear identifiers (HUB-5812) or owner/repo#n PR keys")


def _run(ns):
    keys = [k.strip() for k in ns.keys]
    if any(not k for k in keys):
        raise errors.Usage("every key must be non-empty")
    ctx = Context.from_namespace(ns)
    out = run_tracked(ctx, keys)
    if ns.text:
        return [_text_line(r) for r in out["results"]]
    return out


cli.register("tracked", _build, _run)
