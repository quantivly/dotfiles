"""``rabota snooze <key> --until <when>`` and ``rabota unsnooze <key>`` (DO-874).

Sol's "Later today" on a rank row used to be a Sol-only snooze: rabota kept ranking the row, so
the brief and the phone disagreed by the afternoon. A snooze is now a ``snoozes`` row — tenant,
key, ``until``, ``ts`` — and ``rank`` drops the key from every bucket while ``until`` is ahead of
the clock, saying so in ``decisions`` ("snoozed until …"); ``brief`` prints what ``rank`` ranked,
so the row is gone there too; ``show`` carries the active snoozes to the server. A second snooze
on the same key replaces the first (one row per key), and a row is never deleted on expiry, it
just stops being active. ``pin`` is the promotion; this is the demotion.

``--until`` takes an ISO-8601 date or datetime, or ``tomorrow``. A date, and ``tomorrow``, mean
the start of that day in the laptop's own zone; a naive datetime is in that zone too; an aware
one keeps its offset. The stored value is a UTC stamp in ``store.now()``'s spelling, so ``rank``
compares it as text. A stamp already past is a usage error, never a silent no-op.
"""
from datetime import date, datetime, time, timedelta, timezone, tzinfo

from rabota import cli, errors
from rabota.context import Context
from rabota.store import now

TOMORROW = "tomorrow"
STAMP_FORMAT = "%Y-%m-%dT%H:%M:%SZ"   # ``store.now()``'s spelling
DRY_RUN_NOTE = "nothing written (snoozes row)"


def local_zone() -> tzinfo:
    return datetime.now().astimezone().tzinfo


def parse_until(value: str, today: date, zone: tzinfo | None = None) -> str:
    """``value`` as a UTC stamp, or ``errors.Usage`` naming what was wrong with it."""
    zone = zone or local_zone()
    text = value.strip()
    if text.lower() == TOMORROW:
        moment = datetime.combine(today + timedelta(days=1), time(0), tzinfo=zone)
    else:
        try:
            moment = datetime.fromisoformat(text)
        except ValueError:
            raise errors.Usage(f"--until {value!r}: not an ISO-8601 date or datetime, and not {TOMORROW!r}") from None
        if moment.tzinfo is None:
            moment = moment.replace(tzinfo=zone)
    return moment.astimezone(timezone.utc).strftime(STAMP_FORMAT)


def run_snooze(ctx: Context, item_key: str, until: str, zone: tzinfo | None = None) -> dict:
    """Store the snooze, replacing the key's earlier one; with ``ctx.dry_run`` nothing is written."""
    stamp = parse_until(until, ctx.today, zone)
    if stamp <= now():
        raise errors.Usage(f"--until {until!r} is {stamp}, already past; a snooze ends in the future")
    if ctx.dry_run:
        return {"item_key": item_key, "until": stamp, "ts": None, "dry_run": DRY_RUN_NOTE}
    ctx.store.set_snooze(ctx.tenant.name, item_key, stamp)
    row = next(s for s in ctx.store.snoozes(ctx.tenant.name) if s["item_key"] == item_key)
    return {"item_key": row["item_key"], "until": row["until"], "ts": row["ts"]}


def run_unsnooze(ctx: Context, item_key: str) -> dict:
    """Clear the key's snooze; ``cleared`` says whether there was one. Dry run: nothing is deleted."""
    if ctx.dry_run:
        return {"item_key": item_key, "cleared": None, "dry_run": DRY_RUN_NOTE}
    return {"item_key": item_key, "cleared": ctx.store.clear_snooze(ctx.tenant.name, item_key)}


def _build_snooze(sub):
    p = sub.add_parser("snooze", help="hide a ranked key from the rank and the brief until a time")
    p.add_argument("key")
    p.add_argument("--until", required=True, help=f"ISO-8601 date or datetime, or {TOMORROW!r}")


def _build_unsnooze(sub):
    p = sub.add_parser("unsnooze", help="clear a key's snooze so the rank may place it again")
    p.add_argument("key")


def _key(ns) -> str:
    # Checked before a Context exists, so a usage error touches no store (the pin tests' rule).
    if not ns.key.strip():
        raise errors.Usage("the key must not be empty")
    return ns.key.strip()


def _run_snooze(ns):
    key = _key(ns)
    return run_snooze(Context.from_namespace(ns), key, ns.until)


def _run_unsnooze(ns):
    key = _key(ns)
    return run_unsnooze(Context.from_namespace(ns), key)


cli.register("snooze", _build_snooze, _run_snooze)
cli.register("unsnooze", _build_unsnooze, _run_unsnooze)
