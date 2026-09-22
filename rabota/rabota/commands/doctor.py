"""``rabota doctor``: install link, config parse, store schema, pre-compute timer, and the three
couplings that span two machines.

A coupling between two machines is invisible from either one, so each is asserted here rather
than assumed. All three concern a remote lane, and all three were "documented and kept true by
hand" before they were checks:

* ``seat_cache_age`` — the laptop's clauth cache for the seat a machine's lanes bill. Stale, and
  the gate goes unmeasured and that machine's lanes refuse though the machine is fine.
* ``slice_headroom`` — the admission cap (``budget.max_lanes_local`` x ``lanes.memory_max``, both
  on the laptop) against the cgroup cap (``agents.slice``'s ``MemoryMax``, on the machine).
  Nothing else compares them, and ``budget`` never reads the slice.
* ``remote_seat_identity`` — the seat the MACHINE REGISTRY declares against the account that
  machine's own login actually bills. A mismatch spends a window the gate never metered.
"""
import datetime
import hashlib
import json
import re
from pathlib import Path

from rabota import cli, emit, errors, remote
from rabota.commands import lane
from rabota.context import Context
from rabota.store import SCHEMA_VERSION

EXPECTED_LINK = Path.home() / ".dotfiles" / "scripts" / "rabota"

# One ssh round-trip per machine per check, matching budget.py's credential-gate timeout and
# remote.read's: long enough for a cold connection, short enough that an unreachable machine is
# a FAIL rather than a hang.
REMOTE_TIMEOUT = 30

# clauth's own per-profile record of WHICH ACCOUNT a profile is, and therefore of which account's
# window ``claude-pick --gate --profile <p>`` meters. Measured 2026-09-21: every profile dir holds
# ``account_id.json``, a bare JSON string equal to that account's ``oauthAccount.accountUuid``
# (confirmed by digest against ~/.local/state/claude-account-dirs/<profile>/.claude.json, and
# distinct for every profile on this box). Overridable as a parameter so the state table can hand
# it a fixture tree, the same seam sysinfo.read uses for /proc.
CLAUTH_PROFILES = Path.home() / ".clauth" / "profiles"


def seat_cache_age(ctx, max_age_s: int = 600) -> list[tuple[str, bool, str]]:
    """Per machine with a seat: is this box's usage cache for that seat fresh enough to gate on?

    A dev lane's credential dimension is answered HERE, from this machine's monitoring grant for
    the remote seat (the window is server-side, so any grant on the account reports it). If clauth
    stops polling, the gate goes unmeasured and dev lanes refuse even though dev is fine. That
    coupling is invisible from either machine, so it is asserted rather than assumed.

    This row is about CACHE FRESHNESS only. Whether the seat the machine registry declares
    is the account that machine actually bills is a different question, answered by
    ``remote_seat_identity`` — which emits a row per seated machine unconditionally, pass or fail,
    so the question is never silently unanswered. Until 2026-09-21 every row here carried a "NOT
    VERIFIED" clause because no such check existed; repeating it now would contradict the row
    directly below it.

    ``--dry-run`` is load-bearing, not cosmetic. Without it, this call reaches claude-pick's
    account-dir builder (``scripts/claude-account-dirs.sh``, reachable because claude-pick sources
    ``zsh/zshrc.herdr``) and reconciles ``.credentials.json`` out of band from that reconciler's own
    2-minute timer — a command documented as "check install, config, store, timer" must not write
    credential state as a side effect of running. The explicit ``timeout=30`` (matching
    ``budget.py``'s credential-gate call) avoids inheriting the runner's 60s default for a call that
    now drags a shell layer into a subprocess.

    NOT YET PROVEN in production: ``usage.cache_age_s`` was confirmed to exist by hand-running
    claude-pick in an interactive shell, a different environment from this scrubbed-env subprocess
    call — the key is confirmed, this call's shape against the real binary is not.
    """
    rows = []
    for name, m in sorted(ctx.tenant.machines.items()):
        if not m.profile:
            continue
        res = ctx.runner.run(["claude-pick", "--profile", m.profile, "--dry-run", "--json"], timeout=REMOTE_TIMEOUT)
        if not res.ok:
            rows.append((name, False, f"claude-pick exited {res.code} for {m.profile}"))
            continue
        try:
            age = json.loads(res.out)["usage"]["cache_age_s"]
            ok = age <= max_age_s
        except (json.JSONDecodeError, KeyError, TypeError):
            rows.append((name, False, f"claude-pick printed no usage.cache_age_s for {m.profile}"))
            continue
        rows.append((name, ok, f"declared seat {m.profile}: usage cache is {age}s old"
                     + ("" if ok else f"; lanes on {name} will refuse with credential:unmeasured "
                                      "until clauth polls it")))
    return rows


_SIZE_SUFFIXES = {"": 1, "K": 1024, "M": 1024 ** 2, "G": 1024 ** 3, "T": 1024 ** 4, "P": 1024 ** 5}
_SIZE_RE = re.compile(r"^(\d+(?:\.\d+)?)\s*([KMGTP]?)B?$", re.IGNORECASE)


def parse_size(s: str) -> int:
    """systemd's size syntax (``6G``, ``512M``, ``1048576``) as bytes. ``ValueError`` on anything else.

    Base 1024, which is systemd's own convention for these suffixes and what the live smoke
    measured: ``-p MemoryMax=6G`` showed as ``MemoryMax=6442450944`` (6 x 1024**3) on dev,
    2026-09-20.

    Deliberately strict rather than permissive: the numeric part must be plain decimal digits, so
    ``inf``, ``nan``, ``1e3`` and a negative are refused instead of quietly becoming a number.
    ``float()`` accepts all four, and ``int(float("inf"))`` raises ``OverflowError`` — a different
    exception type, escaping a caller that catches ``ValueError``. A size nobody can read is not a
    cap, and guessing one hides exactly the misconfiguration this check exists to find.
    """
    m = _SIZE_RE.match(str(s).strip())
    if not m:
        raise ValueError(f"not a systemd size: {s!r}")
    return int(float(m.group(1)) * _SIZE_SUFFIXES[m.group(2).upper()])


def _gib(n: int) -> str:
    return f"{n / 1024 ** 3:.1f} GiB"


SLICE_PROPS = ("MemoryMax", "MemoryHigh", "FragmentPath")


def slice_show_argv(machine) -> list[str]:
    """The one ssh call that reads the lane slice's caps on ``machine``.

    ``lane.LANE_SLICE`` and not a literal: this must be the slice a lane actually joins
    (``build_remote`` inserts ``--slice=<LANE_SLICE>``), or doctor would assert a budget no lane
    is subject to — a green tick for the wrong cgroup.
    """
    props = " ".join(f"-p {p}" for p in SLICE_PROPS)
    return remote.ssh_argv(machine, f"systemctl --user show {remote.shquote(lane.LANE_SLICE)} {props}")


def parse_show(out: str) -> dict:
    """``systemctl show``'s ``Key=Value`` lines as a dict. An empty VALUE is a value, not a miss.

    ``FragmentPath=`` with nothing after it is the whole signal that a unit has no unit FILE, so
    the empty string must survive into the dict; the caller distinguishes "present and empty"
    from "absent" and they mean different things.
    """
    d = {}
    for line in out.splitlines():
        k, sep, v = line.partition("=")
        if sep:
            d[k.strip()] = v.strip()
    return d


def slice_headroom(ctx) -> list[tuple[str, bool, str]]:
    """Per remote machine: does ``max_lanes_local`` x ``lanes.memory_max`` fit inside its lane slice?

    Two caps that must agree are set in two files on two machines and nothing compares them.
    ``budget`` admits up to ``budget.max_lanes_local`` by reading the HOST's load, MemAvailable and
    swap; it never reads the slice. Each admitted lane separately requests ``-p MemoryMax=`` into
    ``lane.LANE_SLICE``, which also holds that host's herdr server and every attended pane.
    Measured on dev 2026-09-21: 3 x 6G = 18 GiB admissible into a 10 GiB slice.

    This is a CONFIGURATION invariant — true or false regardless of what is running — which is why
    it is asserted here and not made a refusal in ``budget``. A static misconfiguration surfacing
    as a runtime ``machine:...`` refusal would report the wrong thing at the wrong time: the lane
    you wanted refuses, and the actual cause is a TOML edit from three weeks ago.

    Four states, and telling them apart is the point:

    * the ssh call or the property list fails/comes back incomplete -> FAIL. Unmeasured, never
      "no limit" — the same rule ``remote.UNITS_OK`` exists for.
    * ``FragmentPath`` is EMPTY -> FAIL. The machine has no such unit file, and
      ``--slice=<LANE_SLICE>`` then makes systemd create an implicit slice with no cap at all, so
      the lane is inside no budget while the design says it is. Measured 2026-09-21 on this
      laptop: ``systemctl --user show agents.slice -p MemoryMax`` prints ``MemoryMax=infinity``
      with ``LoadState=loaded`` for a slice that HAS NO UNIT FILE. Reading MemoryMax alone would
      have called that "unbounded, fine". ``FragmentPath`` is what tells the two apart.
    * a real unit file whose ``MemoryMax`` is ``infinity`` -> PASS, saying so. Somebody wrote a
      slice and chose not to cap it; the arithmetic holds and the choice is theirs.
    * a real unit file with a byte count -> the arithmetic, against ``MemoryMax``. ``MemoryHigh``
      is named in the text but not asserted on: it is where throttling starts (and where every
      pane on that host slows first), while ``MemoryMax`` is the hard cap this product must fit
      under. One assertion per row; both numbers visible.
    """
    rows = []
    want = ctx.tenant.budget.max_lanes_local
    declared = ctx.tenant.lanes.memory_max
    try:
        per_lane, size_error = parse_size(declared), None
    except ValueError as e:
        per_lane, size_error = None, str(e)
    for name, m in sorted(ctx.tenant.machines.items()):
        where = f"lanes.memory_max in tenants/{ctx.tenant.name}.toml"
        if size_error:
            rows.append((name, False, f"{where} is unreadable ({size_error}), so no lane memory "
                                      f"budget can be checked for {name!r}"))
            continue
        res = ctx.runner.run(slice_show_argv(m), timeout=REMOTE_TIMEOUT)
        consequence = (f"a lane on {name!r} joins {lane.LANE_SLICE} explicitly and that slice is the "
                       "only thing bounding what agent work there can take from the host")
        if not res.ok:
            rows.append((name, False, f"could not read {lane.LANE_SLICE} on {name!r} "
                                      f"(exit {res.code}: {(res.err or res.out).strip()[:160]}); {consequence}"))
            continue
        props = parse_show(res.out)
        missing = [k for k in SLICE_PROPS if k not in props]
        if missing:
            rows.append((name, False, f"systemctl on {name!r} returned no {', '.join(missing)} for "
                                      f"{lane.LANE_SLICE}; {consequence}"))
            continue
        if not props["FragmentPath"]:
            rows.append((name, False, f"{name!r} has no {lane.LANE_SLICE} unit file, so "
                                      f"--slice={lane.LANE_SLICE} creates an implicit slice with no "
                                      f"memory cap and a lane there is inside no budget "
                                      f"(MemoryMax reads {props['MemoryMax']!r} for a slice that does "
                                      f"not exist); install the slice on {name!r}"))
            continue
        budget_line = (f"{want} lanes x {declared} = {_gib(want * per_lane)} admissible into "
                       f"{lane.LANE_SLICE}")
        if props["MemoryMax"] == "infinity":
            rows.append((name, True, f"{budget_line} on {name!r}, which sets no collective cap "
                                     f"(MemoryMax=infinity, MemoryHigh={props['MemoryHigh']})"))
            continue
        try:
            cap = int(props["MemoryMax"])
        except ValueError:
            rows.append((name, False, f"{lane.LANE_SLICE} on {name!r} reports MemoryMax="
                                      f"{props['MemoryMax']!r}, neither a byte count nor 'infinity'; "
                                      f"{consequence}"))
            continue
        need = want * per_lane
        high = props["MemoryHigh"]
        high_txt = high if high == "infinity" else _gib(int(high)) if high.isdigit() else repr(high)
        ok = need <= cap
        rows.append((name, ok, f"{budget_line} MemoryMax {_gib(cap)} on {name!r}"
                     + (" — fits" if ok else
                        f" — OVER by {_gib(need - cap)}. Lower budget.max_lanes_local or "
                        f"lanes.memory_max in tenants/{ctx.tenant.name}.toml, or raise the slice "
                        f"on {name!r}")
                     + f" (MemoryHigh {high_txt}, where throttling starts and every pane on "
                       f"{name!r} slows before any lane dies)"))
    return rows


# Reads the account a machine's OWN login last recorded and prints a DIGEST of it, never the value.
# The uuid therefore never crosses the wire and never reaches a transcript; the comparison below
# prints neither side, only the verdict.
#
# $HOME/.claude.json -- HOME level, NOT inside .claude -- is deliberately the same file a remote
# lane itself resolves: build_local omits CLAUDE_CONFIG_DIR for a remote machine (fix round 5,
# after the first live smoke showed that setting it to a directory relocates where Claude Code
# looks for this file), so a lane there uses the machine's own defaults, and this reads those.
#
# `o if isinstance(o, dict) else {}`: read a JSON value's type before indexing it. A rewritten or
# truncated file whose oauthAccount is a string would otherwise raise AttributeError inside the
# remote python and arrive as an opaque traceback.
_ACCOUNT_PY = (
    'import json,hashlib,os;'
    'o=json.load(open(os.path.expanduser("~/.claude.json"))).get("oauthAccount");'
    'd=o if isinstance(o,dict) else {};'
    'u=d.get("accountUuid") or "";'
    'print(hashlib.sha256(u.encode()).hexdigest() if u else "NONE");'
    'print(d.get("profileFetchedAt") or "unknown")'
)
_HEX64 = re.compile(r"^[0-9a-f]{64}$")


def _fetched_at(value) -> str:
    """``profileFetchedAt`` rendered as something a reader can act on.

    Claude Code writes that field as a MILLISECOND EPOCH, not the ISO string its name suggests:
    measured on dev 2026-09-21 as ``1789895607090`` (= 2026-09-20T09:13:27Z). Found only by
    running the check against the real machine — every hermetic row fed it an ISO string, because
    that is the shape the field name implies, and the live row read "fetched 1789895607090".

    Seconds and milliseconds are told apart by magnitude: a seconds epoch would have to be in the
    year 5138 to pass 1e11. Anything unrenderable becomes "unknown" rather than a number nobody
    can read — a timestamp this cannot parse is not a timestamp, and it is only ever context on a
    row whose verdict was already decided.
    """
    if isinstance(value, str) and not value.strip().isdigit():
        return value.strip() or "unknown"
    try:
        n = float(value)
    except (TypeError, ValueError):
        return "unknown"
    if n > 1e11:
        n /= 1000.0
    try:
        return datetime.datetime.fromtimestamp(n, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except (OverflowError, OSError, ValueError):
        return "unknown"


def _declared_account_digest(root: Path, profile: str) -> str:
    """sha256 of the account uuid clauth records for ``profile``. Raises on anything unreadable."""
    value = json.loads((root / profile / "account_id.json").read_text())
    if not isinstance(value, str) or not value:
        raise ValueError(f"{profile}/account_id.json is not a non-empty string")
    return hashlib.sha256(value.encode()).hexdigest()


def remote_seat_identity(ctx, clauth_profiles=None) -> list[tuple[str, bool, str]]:
    """Per machine with a seat: is the seat the registry declares the account that machine really bills?

    The gate meters the DECLARED seat from this laptop's clauth grant, and the lane authenticates
    with the TARGET machine's own login (ruling F-P, 2026-09-20). Nothing connected the two, so a
    machine logged into a different account would spend a window the gate never metered — the leak
    class DO-632 and DO-641 exist to close — and ``doctor`` said "NOT VERIFIED" because no check
    existed. One does now, and it needs no credential:

    * the laptop side is ``<clauth_profiles>/<profile>/account_id.json``, clauth's own record of
      which account that profile IS, and so of whose window ``claude-pick --gate`` meters;
    * the machine side is ``oauthAccount.accountUuid`` in that machine's ``$HOME/.claude.json``;
    * both are hashed BEFORE they travel or are compared, and this function prints neither the
      uuid nor its digest — only match / MISMATCH. An account uuid is an identifier and not a
      credential, but the rule in this repo is that a diagnostic prints neither, and the verdict
      is the whole actionable content anyway.

    What it does NOT prove, stated rather than implied: ``oauthAccount`` is the account that
    machine LAST RECORDED when Claude Code fetched its profile, not a live check of the token in
    its credential file. Every row carries that record's ``profileFetchedAt`` so the reader can
    see how old the answer is. It catches a machine sitting on the wrong account, which is the
    failure that has ever happened; it would not catch a token swapped underneath an unchanged
    profile record.

    A row is emitted for every seated machine, pass or fail — an unanswerable check FAILS rather
    than falling silent, because a missing row reads like a clean one.
    """
    root = Path(clauth_profiles) if clauth_profiles is not None else CLAUTH_PROFILES
    rows = []
    for name, m in sorted(ctx.tenant.machines.items()):
        if not m.profile:
            continue
        leak = (f"a lane on {name!r} would bill a window the gate never metered")
        try:
            want = _declared_account_digest(root, m.profile)
        except (OSError, ValueError) as e:
            rows.append((name, False, f"this machine holds no readable account id for declared seat "
                                      f"{m.profile!r} ({type(e).__name__}: {e}), so the seat {name!r} "
                                      f"bills stays UNVERIFIED; {leak}"))
            continue
        res = ctx.runner.run(remote.ssh_argv(m, "python3 -c " + remote.shquote(_ACCOUNT_PY)),
                             timeout=REMOTE_TIMEOUT)
        lines = (res.out or "").splitlines()
        got = lines[0].strip() if lines else ""
        fetched = _fetched_at(lines[1].strip() if len(lines) > 1 else "unknown")
        if not res.ok or not _HEX64.match(got):
            rows.append((name, False, f"could not read which account {name!r}'s own login records "
                                      f"(exit {res.code}: {(res.err or res.out).strip()[:160] or 'no digest'}), "
                                      f"so declared seat {m.profile!r} stays UNVERIFIED; {leak}"))
            continue
        if got != want:
            rows.append((name, False, f"MISMATCH: {name!r}'s own login is NOT declared seat "
                                      f"{m.profile!r}; {leak}. Either fix the tenants file's entry for {name!r} "
                                      f"in tenants/{ctx.tenant.name}.toml or log {name!r} into the "
                                      f"declared account. (Record fetched {fetched}.)"))
            continue
        rows.append((name, True, f"{name!r}'s own login is declared seat {m.profile}, compared by "
                                 f"digest — no account id and no credential is printed. That record "
                                 f"was fetched {fetched}: it is the account {name!r} last recorded, "
                                 f"not a live check of its token."))
    return rows


def run_doctor(ctx: Context, clauth_profiles=None) -> dict:
    """Return the doctor report; ``ok`` is false whenever ``problems`` is non-empty.

    ``clauth_profiles`` is passed through to ``remote_seat_identity`` so the state table can hand
    it a fixture tree instead of this user's real clauth store.
    """
    problems = []
    link = ctx.runner.run(["readlink", "-f", str(Path.home() / ".local/bin/rabota")])
    link_ok = link.ok and link.out.strip() == str(EXPECTED_LINK)
    if not link_ok:
        problems.append("~/.local/bin/rabota is not linked to ~/.dotfiles/scripts/rabota (run dotfiles install)")
    timer = ctx.runner.run(["systemctl", "--user", "is-enabled", f"rabota-precompute@{ctx.tenant.name}.timer"])
    timer_state = timer.out.strip() if timer.ok else "missing"
    if timer_state != "enabled":
        problems.append(f"rabota-precompute@{ctx.tenant.name}.timer is {timer_state} (WS5 installs it)")
    try:
        schema = ctx.store.schema_version()
    except errors.Refused as e:      # a newer DB: the store refuses to open it (both numbers in the text)
        schema = None
        problems.append(str(e))
    else:
        if schema != SCHEMA_VERSION:
            problems.append(f"rabota.db schema is {schema}, this rabota expects {SCHEMA_VERSION} "
                            "(no migration is defined for it yet)")
    seat_rows = seat_cache_age(ctx)
    for name, ok, detail in seat_rows:
        if not ok:
            problems.append(f"seat cache for machine {name!r}: {detail}")
    slice_rows = slice_headroom(ctx)
    for name, ok, detail in slice_rows:
        if not ok:
            problems.append(f"lane memory budget on machine {name!r}: {detail}")
    identity_rows = remote_seat_identity(ctx, clauth_profiles)
    for name, ok, detail in identity_rows:
        if not ok:
            problems.append(f"declared seat on machine {name!r}: {detail}")
    as_rows = lambda rs: [{"machine": n, "ok": ok, "detail": d} for n, ok, d in rs]
    return {"tenant": ctx.tenant.name, "state_dir": str(ctx.state_dir), "config_ok": True,
            "db_schema": schema, "links": {"rabota": link_ok}, "timer": {"state": timer_state},
            "seat_cache": as_rows(seat_rows), "slice_headroom": as_rows(slice_rows),
            "remote_seat": as_rows(identity_rows),
            "ok": not problems, "problems": problems}


def _build(sub):
    sub.add_parser("doctor", help="check install, config, store, timer, and the cross-machine couplings")


def _run(ns):
    ctx = Context.from_namespace(ns)
    report = run_doctor(ctx)
    if not report["ok"]:
        emit.json_out(report)   # the caller sees the report and then the refusal
        raise errors.Refused("; ".join(report["problems"]))
    return report


cli.register("doctor", _build, _run)
