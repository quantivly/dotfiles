"""``rabota rank``: read the snapshots, plan, census and pins; write ``YYYY-MM-DD/sequence.{json,md}``."""
import json
from pathlib import Path

from rabota import cli, rank as rank_mod, snapshots
from rabota.context import Context


def _read_json(path: Path) -> dict | None:
    return json.loads(path.read_text()) if path.exists() else None


def run_rank(ctx: Context) -> dict:
    """Rank today's inputs; sources whose last sync failed are listed in ``failed_sources``."""
    day = ctx.state_dir / ctx.today.isoformat()
    day.mkdir(parents=True, exist_ok=True)
    inp = rank_mod.RankInputs(
        linear=snapshots.read(ctx.state_dir, "linear"), github=snapshots.read(ctx.state_dir, "github"),
        slack=snapshots.read(ctx.state_dir, "slack"),
        inbox_plan=_read_json(ctx.state_dir / "inbox-plan.json"),
        census=_read_json(ctx.state_dir / "census.json"),
        pins=ctx.store.pins(ctx.tenant.name), tenant=ctx.tenant, today=ctx.today)
    seq = rank_mod.rank(inp)
    seq["failed_sources"] = [s for s in ctx.tenant.sources
                             if (ctx.store.last_sync(ctx.tenant.name, s) or {}).get("ok") == 0]
    (day / "sequence.json").write_text(json.dumps(seq, indent=1))
    (day / "sequence.md").write_text(rank_mod.to_markdown(seq))
    return {"path": str(day / "sequence.json"), "items": len(seq["items"]),
            "decisions": len(seq["decisions"]), "triage": len(seq["triage"])}


def _build(sub):
    sub.add_parser("rank", help="rank next actions into sequence.json/.md")


cli.register("rank", _build, lambda ns: run_rank(Context.from_namespace(ns)))
