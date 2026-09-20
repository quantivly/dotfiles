"""Lane budget. Credential dimension first (F13), through claude-pick --gate — the one gate every
spawner shares; then the machine dimension (load/memory/swap) for the machine the lane would
actually run on; then that machine's running-lane count against the cap. An unmeasured
dimension refuses — a missing census, an absent or unreachable machine row — never as room, and
never by falling back to the local reading.
"""
import datetime
import json
from rabota import errors
from rabota.store import now

CONSOLE_SEATS = ("quantivly-3",)
WORK_PREFIX, PERSONAL_PREFIXES = "quantivly-", ("personal-", "toysim-")
WORK_TENANT = "quantivly"


def seat_for(tenant, machine: str, override: str | None = None) -> str:
    """The seat a lane for ``tenant`` on ``machine`` must use; refuses a seat the tenant rule forbids.

    ``local`` reads ``[seats] local``; any other machine reads ``[machines.<m>].profile``. An
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
        raise errors.Refused(f"no seat configured for tenant {tenant.name!r} on machine {machine!r} "
                             f"([seats] local / [machines.{machine}].profile in tenants/{tenant.name}.toml)")
    if seat in CONSOLE_SEATS:
        raise errors.Refused(f"seat {seat} is the interactive console and is never used headless")
    is_work = tenant.name == WORK_TENANT
    if is_work and not seat.startswith(WORK_PREFIX):
        raise errors.Refused(f"seat {seat} is not a {WORK_PREFIX}* seat; work never runs on a personal window")
    if not is_work and seat.startswith(WORK_PREFIX):
        raise errors.Refused(f"seat {seat} is a work seat; tenant {tenant.name} must use "
                             + "/".join(p + "*" for p in PERSONAL_PREFIXES))
    return seat


def credential_gate(runner, seat: str, model: str, effort: str, est_minutes: int) -> dict:
    """Ask ``claude-pick --gate`` about ``seat``. Any answer that is not a measured allow is a refusal with a code.

    ``credential:window`` — the seat exists and is measured, and the 5h projection, the pool, or the
    model's weekly spend wall says no (``gate-projected``, ``exhausted``, or ``gate-spend-wall``);
    ``credential:unmeasured`` — everything else: claude-pick absent (127) or without profiles (5), a
    window it could not read, non-JSON, or an exit 0 that carries no gate verdict (an older
    claude-pick, or ``--gate`` silently dropped). Never ok on exit code alone.
    """
    res = runner.run(["claude-pick", "--profile", seat, "--dry-run", "--json", "--gate",
                      "--model", model, "--effort", effort, "--est-minutes", str(est_minutes)], timeout=30)
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
