"""``rabota pin``: record a dated promise so ``rank`` schedules it (design table, skill reconcile.md).

``rank._bucket_2`` reads ``pins`` rows by ``item_key``/``bucket``/``rationale`` (and optionally
``title``/``waiting_on``/``url``, defaulted when absent) and only ever schedules the ones with
``bucket == 2`` — the live skill's own example is ``rabota pin <key> --bucket 2 --rationale …``.
``Store.set_pin`` is ``INSERT OR REPLACE`` keyed by ``(tenant, item_key)``, so re-pinning the same
key is an upsert: the newest bucket/rationale/ts wins and there is never more than one open pin per
key — the shape a re-run of the same promise wants, not a growing log of restatements.
"""
from rabota import cli
from rabota.context import Context


def run_pin(ctx: Context, item_key: str, bucket: int, rationale: str) -> dict:
    ctx.store.set_pin(ctx.tenant.name, item_key, bucket, rationale)
    row = next(p for p in ctx.store.pins(ctx.tenant.name) if p["item_key"] == item_key)
    return {"item_key": row["item_key"], "bucket": row["bucket"], "rationale": row["rationale"], "ts": row["ts"]}


def _build(sub):
    p = sub.add_parser("pin", help="record a dated promise for rank to schedule")
    p.add_argument("key")
    p.add_argument("--bucket", required=True, type=int)
    p.add_argument("--rationale", required=True)


def _run(ns):
    return run_pin(Context.from_namespace(ns), ns.key, ns.bucket, ns.rationale)


cli.register("pin", _build, _run)
