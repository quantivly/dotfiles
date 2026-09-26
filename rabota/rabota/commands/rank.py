"""``rabota rank``: read the snapshots, plan, census and pins; write ``YYYY-MM-DD/sequence.{json,md}``."""
import hashlib
import json
from pathlib import Path

from rabota import cli, emit, rank as rank_mod, snapshots
from rabota.context import Context


def _read_json(path: Path) -> dict | None:
    return json.loads(path.read_text()) if path.exists() else None


def inputs_signature(ctx: Context) -> dict:
    """A fingerprint of every input ``rank.rank`` actually reads (DO-738), cheap to recompute on
    each ``brief`` call.

    Established by reading ``rank.rank`` itself, not by restating the issue text: it reads
    ``inp.linear``, ``inp.github``, ``inp.inbox_plan``, ``inp.census`` and ``inp.pins`` -- never
    ``inp.slack``, which ``RankInputs`` carries and ``compute_sequence`` fills in but no code under
    ``rank.rank`` dereferences. A Slack snapshot landing is real news for ``needs``
    (``NEEDS_SOURCES`` in ``commands.brief``), but it cannot move anything THIS function ranks, and
    "re-ranking is not free" cuts both ways: fingerprinting a field the ranker never reads would
    re-rank (and rewrite ``sequence.json``/``.md``) on a change that could not have altered the
    answer. If a future change makes ``rank.rank`` read Slack, add it here in the same commit.

    Each remaining field is a digest of its file's bytes (see ``_digest``) — never a file mtime,
    which would also change on a touch that did not change the content. The pins table is different: it lives in ``rabota.db``, which several writers share,
    so neither an mtime nor a hash of its rows proves anything (a lesson from this project — a
    delete can leave a row-derived aggregate like ``MAX(ts)`` unchanged). ``Store.pins_version`` is
    a counter bumped on every ``set_pin``/``clear_pin``, so it is the one thing here that is
    actually true of "did the pins table change" rather than merely correlated with it.
    """
    sd = ctx.state_dir
    return {"linear": _digest(sd / "sources" / "linear.json"), "github": _digest(sd / "sources" / "github.json"),
            "inbox_plan": _digest(sd / "inbox-plan.json"), "census": _digest(sd / "census.json"),
            "pins": ctx.store.pins_version(ctx.tenant.name)}


def _digest(path: Path) -> str | None:
    """A short content digest of one input file, or ``None`` when it does not exist.

    Content, not the embedded stamp (DO-738 review): ``fetched_at`` has one-second resolution, so
    two writes with different content in the same second carried the same stamp and the change was
    missed. A digest of the bytes cannot miss a content change, and like the stamp it ignores a
    touch that changes nothing.
    """
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()[:16]
    except FileNotFoundError:
        return None


def compute_sequence(ctx: Context) -> dict:
    """Rank today's inputs and return ``seq``, without writing anything (used by ``rank`` and by
    ``brief --dry-run``, which needs the same ranked answer but must not persist it).

    ``seq["inputs"]`` is this rank's ``inputs_signature`` — recorded so a later ``brief`` call, the
    same day, can tell whether anything it would read has moved since (DO-738).
    """
    inp = rank_mod.RankInputs(
        linear=snapshots.read(ctx.state_dir, "linear"), github=snapshots.read(ctx.state_dir, "github"),
        slack=snapshots.read(ctx.state_dir, "slack"),
        inbox_plan=_read_json(ctx.state_dir / "inbox-plan.json"),
        census=_read_json(ctx.state_dir / "census.json"),
        pins=ctx.store.pins(ctx.tenant.name), tenant=ctx.tenant, today=ctx.today)
    seq = rank_mod.rank(inp)
    seq["failed_sources"] = [s for s in ctx.tenant.sources
                             if (ctx.store.last_sync(ctx.tenant.name, s) or {}).get("ok") == 0]
    seq["inputs"] = inputs_signature(ctx)
    return seq


def run_rank(ctx: Context) -> dict:
    """Rank today's inputs; sources whose last sync failed are listed in ``failed_sources``.

    ``ctx.dry_run`` (DO-753): the same ranked answer is still computed (``compute_sequence``,
    already write-free — the same function ``brief --dry-run`` uses), but ``sequence.json``/``.md``
    are not written and the day directory is not created.
    """
    seq = compute_sequence(ctx)
    if ctx.dry_run:
        return {"path": None, "items": len(seq["items"]), "decisions": len(seq["decisions"]),
                "triage": len(seq["triage"]), "dry_run": "nothing written (sequence.json, sequence.md)"}
    day = ctx.state_dir / ctx.today.isoformat()
    day.mkdir(parents=True, exist_ok=True)
    emit.write_file(day / "sequence.json", json.dumps(seq, indent=1))    # guarded: nothing lands on a leak (k2)
    emit.write_file(day / "sequence.md", rank_mod.to_markdown(seq))
    return {"path": str(day / "sequence.json"), "items": len(seq["items"]),
            "decisions": len(seq["decisions"]), "triage": len(seq["triage"])}


def _build(sub):
    sub.add_parser("rank", help="rank next actions into sequence.json/.md")


cli.register("rank", _build, lambda ns: run_rank(Context.from_namespace(ns)))
