"""``rabota pin``: record a dated promise so ``rank`` schedules it (design table, skill reconcile.md).

``rank._bucket_2`` reads ``pins`` rows by ``item_key``/``bucket``/``rationale`` (and optionally
``title``/``waiting_on``/``url``, defaulted when absent) and only ever schedules the ones with
``bucket == 2`` — the live skill's own example is ``rabota pin <key> --bucket 2 --rationale …``.
``Store.set_pin`` is ``INSERT OR REPLACE`` keyed by ``(tenant, item_key)``, so re-pinning the same
key is an upsert: the newest bucket/rationale/ts wins and there is never more than one open pin per
key — the shape a re-run of the same promise wants, not a growing log of restatements.
"""
from rabota import cli, errors
from rabota.context import Context


def run_pin(ctx: Context, item_key: str, bucket: int, rationale: str) -> dict:
    """Upsert a pin; with ``ctx.dry_run`` (DO-753) no ``pins`` row is written and none is read back."""
    if ctx.dry_run:
        return {"item_key": item_key, "bucket": bucket, "rationale": rationale, "ts": None,
                "dry_run": "nothing written (pins row)"}
    ctx.store.set_pin(ctx.tenant.name, item_key, bucket, rationale)
    row = next(p for p in ctx.store.pins(ctx.tenant.name) if p["item_key"] == item_key)
    return {"item_key": row["item_key"], "bucket": row["bucket"], "rationale": row["rationale"], "ts": row["ts"]}


def _build(sub):
    p = sub.add_parser("pin", help="record a dated promise for rank to schedule")
    p.add_argument("key")
    p.add_argument("--bucket", required=True, type=int)
    p.add_argument("--rationale", required=True)


#: The only bucket `rank` reads a pin into. Buckets 3-5 exist in `rank`, but they are built from
#: issues and PRs, not from pins — a pin in one is stored and never scheduled, which is a silent
#: no-op the caller has no way to notice.
PINNABLE_BUCKETS = (2,)


def _run(ns):
    if ns.bucket not in PINNABLE_BUCKETS:
        raise errors.Usage(
            f"--bucket {ns.bucket} is not read by rank; only {', '.join(map(str, PINNABLE_BUCKETS))} "
            "schedules a pin, and a pin in any other bucket would be stored and silently ignored")
    if not ns.key.strip():
        raise errors.Usage("the pin key must not be empty")
    if not ns.rationale.strip():
        raise errors.Usage("--rationale must not be empty; it is what the brief shows for the pin")
    return run_pin(Context.from_namespace(ns), ns.key, ns.bucket, ns.rationale)


cli.register("pin", _build, _run)
