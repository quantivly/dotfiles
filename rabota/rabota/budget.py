"""Lane budget. Credential dimension first (F13), through claude-pick --gate — the one gate every
spawner shares. An unmeasured dimension refuses; nothing here is ever read as zero.

Task 1 ships the credential slice and the ``budget.json`` shape. The machine and count dimensions
(``_machine_reasons`` / ``_count_reasons``) are filled in by WS4' Task 4; until then a missing
census is reported as ``machine:unmeasured`` and refuses, never as room.
"""
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

    ``credential:window`` — the seat exists and is measured, and the projection (or the pool) says no;
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
    if state in ("gate-projected", "exhausted"):
        out["code"] = "credential:window"
        out["detail"] = out["detail"] or f"{seat} 5h window: {usage.get('five_hour')}% now, projected {gate.get('projected')}%"
    else:  # gate-unmeasured, no-profiles, bad-table, backpressure, or exit 0 without a verdict
        out["code"] = "credential:unmeasured"
        out["detail"] = out["detail"] or f"claude-pick state {state!r} with no gate verdict"
    return out


def compute(census: dict | None, cred: dict, t, max_lanes_local: int) -> dict:
    """Order: credential → machine → counts. Task 4 fills the machine and count dimensions from ``census``."""
    reasons, unavailable = [], []
    if not cred["ok"]:
        reasons.append({"code": cred["code"], "detail": cred["detail"]})
    if census is None:
        unavailable.append("machine"); unavailable.append("counts")
        if not reasons:
            reasons.append({"code": "machine:unmeasured", "detail": "no census; run rabota census first"})
    else:
        reasons.extend(_machine_reasons(census, t))          # Task 4
        reasons.extend(_count_reasons(census, t))            # Task 4
        unavailable.extend(census.get("unavailable", []))
    counts = (census or {}).get("counts", {})
    running = counts.get("rabota", 0) + counts.get("sol", 0)
    allowed = 0 if reasons else max(0, max_lanes_local - running)
    return {"schema": 1, "at": now(), "allowed_new_lanes": allowed, "reasons": reasons,
            "seat_pick": None, "five_h_pct_now": cred.get("five_h_pct_now"), "resets_at": cred.get("resets_at"),
            "tier": cred.get("tier"), "unavailable": unavailable}


def _machine_reasons(census, t):   # replaced in Task 4
    return []


def _count_reasons(census, t):     # replaced in Task 4
    return []


def text_line(b: dict) -> str:
    pct = b.get("five_h_pct_now")
    head = f"budget: {b['allowed_new_lanes']} lanes allowed · seat {b.get('seat_pick')} at {'unknown' if pct is None else f'{pct}%'}"
    return head + (f" · {b['reasons'][0]['code']}: {b['reasons'][0]['detail']}" if b["reasons"] else "")
