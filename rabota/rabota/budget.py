"""Lane budget. Credential dimension first (F13), through claude-pick --gate — the one gate every
spawner shares; then the machine dimension (load/memory/swap) for the machine the lane would
actually run on; then that machine's running-lane count against the cap. An unmeasured
dimension refuses — a missing census, an absent or unreachable machine row — never as room, and
never by falling back to the local reading.
"""
import datetime
import json
import statistics
from rabota import errors
from rabota.store import now

CONSOLE_SEATS = ("quantivly-3",)
WORK_PREFIX, PERSONAL_PREFIXES = "quantivly-", ("personal-", "toysim-")
WORK_TENANT = "quantivly"

# DO-728: a seat with no usable rate history is projected at the worst rate this project has
# ever actually measured (scripts/claude-pick's own CLAUDE_PICK_RATE_DEFAULT derivation: the
# WS1 fix lane on 2026-09-16, 19 points in 10 minutes = 114 pts/h, rounded up to 115) rather than
# a typical one — an unmeasured seat must never be MORE permissive than the constant it replaces,
# only a seat with real history earns a lower, less conservative rate.
RATE_FLOOR = 115.0
RATE_HISTORY_LIMIT = 30   # how many of a seat's most recent usable lanes the trailing stat sees


def _busy_intervals(rows: list[dict]) -> list[tuple[float, float, int, int]]:
    """Collapse ``rows`` (one seat's lanes) into non-overlapping busy spans.

    Two or three lanes often run on one seat at once (DO-728): a lane's own start-to-end delta
    then includes its neighbours' burn too, and a naive per-lane rate double- and triple-counts
    the shared window growth. Instead of a per-lane rate, this computes ONE rate per busy span —
    the span's utilisation delta (last lane's ``five_h_pct_at_end`` to end, minus the first lane's
    ``five_h_pct_at_start``) over its wall-clock length — so overlapping neighbours contribute
    their SHARED span exactly once. A lane fully contained inside a wider span (starts after and
    ends before the span's current bounds) is folded in for coverage but does not move either
    edge, matching "at least exclude overlap from the sample" without discarding it outright.

    Returns ``(start_epoch, end_epoch, pct_start, pct_end)`` tuples, chronological, unsorted by
    duration. A span whose ``pct_end < pct_start`` (the 5h window reset mid-span) is dropped by
    the caller, never corrected into a negative or absurd rate here.
    """
    parsed = []
    for r in rows:
        try:
            start = datetime.datetime.fromisoformat(str(r["started_at"]).replace("Z", "+00:00"))
            end = datetime.datetime.fromisoformat(str(r["ended_at"]).replace("Z", "+00:00"))
        except ValueError:
            continue
        if end <= start:
            continue   # zero/negative duration: a clamped or otherwise unreal ended_at (DO-722)
        parsed.append((start.timestamp(), end.timestamp(), r["five_h_pct_at_start"], r["five_h_pct_at_end"]))
    parsed.sort(key=lambda x: x[0])
    spans = []
    for start, end, pct_start, pct_end in parsed:
        if spans and start <= spans[-1][1]:
            s = spans[-1]
            if end > s[1]:
                spans[-1] = (s[0], end, s[2], pct_end)
        else:
            spans.append((start, end, pct_start, pct_end))
    return spans


def measured_rate(store, tenant: str, seat: str) -> tuple[float, str]:
    """The seat's trailing MEDIAN burn rate in pts/h, and a source string naming how it was derived.

    Median, not p75 or max: DO-728's own 2026-09-24 sample (8 lanes, 6.7-20.5 pts/h) is what a
    single fixed 115 pts/h was refusing affordable work against, and the median is the rate that
    describes what a lane on this seat actually costs most of the time -- p75 or max would carry
    forward the same overestimate the fixed constant did, just a smaller one. ``RATE_FLOOR``
    still bounds the DOWNSIDE for a seat with no history at all.
    """
    rows = store.lanes_for_rate(tenant, seat, limit=RATE_HISTORY_LIMIT)
    spans = _busy_intervals(rows)
    rates = []
    for start, end, pct_start, pct_end in spans:
        if pct_end < pct_start:
            continue   # the 5h window reset mid-span; never let that read as a negative rate
        hours = (end - start) / 3600
        if hours > 0:
            rates.append((pct_end - pct_start) / hours)
    if not rates:
        return RATE_FLOOR, f"floor {RATE_FLOOR:g} pts/h, no history"
    rate = statistics.median(rates)
    return rate, f"measured median {rate:.1f} pts/h over {len(rows)} lanes"


def seat_for(tenant, machine: str, override: str | None = None) -> str:
    """The seat a lane for ``tenant`` on ``machine`` must use; refuses a seat the tenant rule forbids.

    ``local`` reads ``[seats] local``; any other machine reads the MACHINE REGISTRY, which
    ``config.load`` fills from the tenants file through ``scripts/machines-render`` (DO-665) —
    not from this tenant's TOML, where a leftover ``profile`` key is now refused outright. An
    ``override`` (``--seat``) replaces the lookup but is still checked against the rule.
    """
    if override:
        seat = override
    elif machine == "local":
        seat = tenant.seats.get("local")
    else:
        m = tenant.machines.get(machine)
        seat = m.profile if m else None
    if not seat:
        where = (f"[seats] local in tenants/{tenant.name}.toml" if machine == "local" else
                 f"CLAUDE_TENANT_MACHINE_OWNED + CLAUDE_TENANT_MACHINE_ID for machine "
                 f"{machine!r} in the tenants file (see scripts/machines-render)")
        raise errors.Refused(f"no seat configured for tenant {tenant.name!r} on machine {machine!r} ({where})")
    if seat in CONSOLE_SEATS:
        raise errors.Refused(f"seat {seat} is the interactive console and is never used headless")
    is_work = tenant.name == WORK_TENANT
    if is_work and not seat.startswith(WORK_PREFIX):
        raise errors.Refused(f"seat {seat} is not a {WORK_PREFIX}* seat; work never runs on a personal window")
    if not is_work and seat.startswith(WORK_PREFIX):
        raise errors.Refused(f"seat {seat} is a work seat; tenant {tenant.name} must use "
                             + "/".join(p + "*" for p in PERSONAL_PREFIXES))
    return seat


def credential_gate(runner, seat: str, model: str, effort: str, est_minutes: int, *,
                    env: dict | None = None, rate: float | None = None, rate_source: str = "") -> dict:
    """Ask ``claude-pick --gate`` about ``seat``. Any answer that is not a measured allow is a refusal with a code.

    ``credential:window`` — the seat exists and is measured, and the 5h projection, the pool, or the
    model's weekly spend wall says no (``gate-projected``, ``exhausted``, or ``gate-spend-wall``);
    ``credential:unmeasured`` — everything else: claude-pick absent (127) or without profiles (5), a
    window it could not read, non-JSON, or an exit 0 that carries no gate verdict (an older
    claude-pick, or ``--gate`` silently dropped). Never ok on exit code alone.

    ``rate`` (from ``measured_rate``), when given, replaces claude-pick's own ``CLAUDE_PICK_RATE_DEFAULT``
    (115, undocumented as anything but "the worst rate ever seen") for THIS call only, via the
    environment — claude-pick itself is out of scope for DO-728, but it already reads that variable
    ahead of its own hard-coded fallback, and its projection math and reason text already name
    whatever rate they used. ``rate_source`` is appended to the refusal detail so the seat's own
    history (or the floor, and why) is named too, not just the number. A tenant config that still
    sets ``CLAUDE_PICK_RATES[model:effort]`` for this exact pair wins over either — out of scope here.
    """
    call_env = dict(env) if env is not None else None
    if rate is not None:
        call_env = {**(call_env or {}), "CLAUDE_PICK_RATE_DEFAULT": str(max(1, round(rate)))}
    kwargs = {"env": call_env} if call_env is not None else {}
    res = runner.run(["claude-pick", "--profile", seat, "--dry-run", "--json", "--gate",
                      "--model", model, "--effort", effort, "--est-minutes", str(est_minutes)],
                      timeout=30, **kwargs)
    base = {"ok": False, "code": "credential:unmeasured", "detail": "", "five_h_pct_now": None, "resets_at": None, "tier": None}
    if res.code in (5, 127) or not res.out.strip():
        base["detail"] = f"claude-pick exit {res.code}: {(res.err or '').strip()[:160] or 'no output'}"
        return base
    try:
        j = json.loads(res.out)
    except json.JSONDecodeError:
        base["detail"] = f"claude-pick exit {res.code} printed non-JSON"
        return base
    if not isinstance(j, dict):
        base["detail"] = "claude-pick printed JSON that is not an object"
        return base
    usage, resets, gate = j.get("usage") or {}, j.get("resets_at") or {}, j.get("gate") or {}
    out = {"ok": False, "code": None, "detail": j.get("reason") or "", "five_h_pct_now": usage.get("five_hour"),
           "resets_at": resets.get("five_hour"), "tier": j.get("tier")}
    state = j.get("state")
    if res.code == 0 and gate.get("verdict") == "allow":
        out["ok"] = True
        return out
    if state in ("gate-projected", "exhausted", "gate-spend-wall"):
        out["code"] = "credential:window"
        fallback = (f"{seat} weekly window spent, spend {gate.get('spend')}"
                    if state == "gate-spend-wall"
                    else f"{seat} 5h window: {usage.get('five_hour')}% now, projected {gate.get('projected')}%")
        out["detail"] = out["detail"] or fallback
        if rate_source and state != "gate-spend-wall":
            out["detail"] = f"{out['detail']} ({rate_source})"
    else:  # gate-unmeasured, gate-misconfigured, no-profiles, bad-table, backpressure,
           # or exit 0 without a verdict
        out["code"] = "credential:unmeasured"
        out["detail"] = out["detail"] or f"claude-pick state {state!r} with no gate verdict"
    return out


def compute(census: dict | None, cred: dict, t, max_lanes_local: int, machine: str = "local",
           max_census_age_s: int = 900) -> dict:
    """Order: credential → machine → counts, for the machine the lane would run on."""
    reasons, unavailable = [], []
    if not cred["ok"]:
        reasons.append({"code": cred["code"], "detail": cred["detail"]})
    running = 0
    if census is None:
        unavailable.extend(["machine", "counts"])
        if not reasons:
            reasons.append({"code": "machine:unmeasured", "detail": "no census; run rabota census first"})
    elif not _census_fresh(census, max_census_age_s):
        reasons.append({"code": "census:stale",
                        "detail": f"census.json is missing 'at' or older than {max_census_age_s}s; "
                                  "run rabota census"})
        unavailable.extend(["machine", "counts"])
        unavailable.extend(census.get("unavailable", []))
    else:
        m = _reading_for(census, machine)
        if m is None:
            reasons.append({"code": "machine:unmeasured",
                            "detail": f"census has no usable reading for machine {machine!r}"})
            unavailable.append("machine")
        else:
            reasons.extend(_machine_reasons(m, t))
            running = _running_lanes(census, machine)
        unavailable.extend(census.get("unavailable", []))
    allowed = 0 if reasons else max(0, max_lanes_local - running)
    return {"schema": 1, "at": now(), "allowed_new_lanes": allowed, "reasons": reasons,
            "seat_pick": None, "five_h_pct_now": cred.get("five_h_pct_now"), "resets_at": cred.get("resets_at"),
            "tier": cred.get("tier"), "unavailable": unavailable}


def _census_fresh(census: dict, max_age_s: int) -> bool:
    """A census with no timestamp, or an unparseable one, is stale — never fresh by default.

    ``--state-dir`` lets a caller point ``budget`` at any directory, so the file's own age is the
    only thing standing between a hand-written census and manufactured room.
    """
    at = census.get("at")
    if not at:
        return False
    try:
        ts = datetime.datetime.fromisoformat(str(at).replace("Z", "+00:00"))
    except ValueError:
        return False
    if ts.tzinfo is None:
        # fromisoformat accepts a string with no UTC offset and parses it WITHOUT raising,
        # into a naive datetime -- the except above never fires for this case. Subtracting a
        # naive timestamp from the aware "now" below would raise TypeError instead, uncaught,
        # so this check catches it explicitly: a timestamp whose timezone we do not know is
        # not a timestamp we can age, and an unmeasured dimension refuses.
        return False
    age = (datetime.datetime.now(datetime.timezone.utc) - ts).total_seconds()
    return 0 <= age <= max_age_s


def _reading_for(census: dict, machine: str) -> dict | None:
    """The load/memory reading for ``machine``, or None when it was not measured.

    None and a zeroed row are the two ways an unmeasured machine becomes "room"; the caller
    turns None into a refusal, so neither can.
    """
    if machine == "local":
        return census.get("machine")
    for row in census.get("machines", []):
        if row.get("name") == machine:
            return row if row.get("reachable") else None
    return None


def _machine_reasons(m: dict, t) -> list[dict]:
    """Load, memory and swap against the tenant's thresholds. One named reason per breach."""
    out = []
    ncpu = m.get("ncpu") or 1
    if m["load1"] > t.load1_per_cpu * ncpu:
        out.append({"code": "machine:load",
                    "detail": f"load1 {m['load1']} over {t.load1_per_cpu}×{ncpu} cpus"})
    if m["mem_available_gib"] < t.mem_available_min_gib:
        out.append({"code": "machine:memory",
                    "detail": f"{m['mem_available_gib']} GiB available, floor {t.mem_available_min_gib}"})
    if m["swap_used_pct"] > t.swap_pct_max:
        out.append({"code": "machine:swap",
                    "detail": f"swap {m['swap_used_pct']}% over {t.swap_pct_max}%"})
    return out


def _running_lanes(census: dict, machine: str) -> int:
    """Lanes already running on ``machine`` — local counts owners, remote counts its units."""
    if machine == "local":
        c = census.get("counts", {})
        return c.get("rabota", 0) + c.get("sol", 0)
    for row in census.get("machines", []):
        if row.get("name") == machine:
            return sum(u.get("state") in ("active", "activating") for u in row.get("units", []))
    return 0


def text_line(b: dict) -> str:
    pct = b.get("five_h_pct_now")
    head = f"budget: {b['allowed_new_lanes']} lanes allowed · seat {b.get('seat_pick')} at {'unknown' if pct is None else f'{pct}%'}"
    return head + (f" · {b['reasons'][0]['code']}: {b['reasons'][0]['detail']}" if b["reasons"] else "")
