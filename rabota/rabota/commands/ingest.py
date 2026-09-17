"""``rabota ingest <source> --file``: store connector results the skill fetched in-session.

The file is ``{"fetched_at": "<UTC Z>", "ok": true|false, "error": str|null, "items": [...]}``.
``ok`` must be a JSON boolean: a string ``"false"`` is truthy, so coercing it recorded a failed
source as a success and ``brief`` stayed silent (review finding k5). Anything that is not
``true``/``false`` — a string, a number, ``null``, absent — is ``Usage`` naming the type it got;
a file that cannot state success or failure unambiguously has not stated it.
A failed fetch (``ok: false``) is still recorded — the snapshot is written with ``items: []``
and ``source_syncs`` gets ``ok=0`` with the error — so ``brief`` can say
``! <source> failed — list is partial`` instead of silently ranking without it.
"""
import json
from pathlib import Path

from rabota import cli, errors, snapshots
from rabota.context import Context

ALLOWED = ("slack", "calendar", "fireflies")


def _load(file: Path) -> dict:
    """Read and validate the ingest file; every fault in it is ``Usage`` naming the file."""
    try:
        data = json.loads(Path(file).read_text())
    except (OSError, json.JSONDecodeError) as e:
        raise errors.Usage(f"cannot read {file}: {e}") from None
    if not isinstance(data, dict) or "fetched_at" not in data:
        raise errors.Usage(f"{file}: ingest file must be an object with 'fetched_at' (and 'items' when ok)")
    try:
        snapshots.parse_fetched_at(str(data["fetched_at"]))
    except ValueError:
        raise errors.Usage(f"{file}: fetched_at must be UTC like 2026-09-16T07:00:00Z") from None
    ok = data.get("ok")
    if not isinstance(ok, bool):
        got = "absent" if "ok" not in data else f"{type(ok).__name__} {ok!r}"
        raise errors.Usage(f"{file}: 'ok' must be a JSON boolean (true or false), got {got}")
    if ok and not isinstance(data.get("items"), list):
        raise errors.Usage(f"{file}: a successful ingest file needs an 'items' list")
    return data


def run_ingest(ctx: Context, source: str, file: Path) -> dict:
    """Validate ``file`` and write ``sources/<source>.json``; a failed fetch is recorded, not raised."""
    if source not in ALLOWED:
        raise errors.Usage(f"ingest accepts {ALLOWED}")
    data = _load(file)
    ok = data["ok"]                       # a bool, or _load raised
    error = None if ok else str(data.get("error") or "unknown error")
    items = data["items"] if ok else []
    payload = {"ok": ok, "error": error, "fetched_at": data["fetched_at"], "items": items}
    path = snapshots.write(ctx.state_dir, source, payload)
    ctx.store.record_sync(ctx.tenant.name, source, ok, error, str(path))
    return {"source": source, "ok": ok, "error": error, "items": len(items), "path": str(path)}


def _build(sub):
    p = sub.add_parser("ingest", help="store connector results fetched in-session")
    p.add_argument("source", choices=ALLOWED)
    p.add_argument("--file", required=True)


def _run(ns):
    return run_ingest(Context.from_namespace(ns), ns.source, Path(ns.file))


cli.register("ingest", _build, _run)
