"""Tenant data lives in ~/.dotfiles-local/rabota (private overlay). Mechanism here."""
import os
import tomllib
from dataclasses import dataclass, field
from pathlib import Path
from typing import Mapping

from rabota import errors
from rabota import machines as machines_mod
from rabota import tenants as tenants_mod

DEFAULT_BASE = Path("~/.dotfiles-local/rabota")


def _p(s: str | None) -> Path | None:
    return Path(os.path.expanduser(s)) if s else None


@dataclass
class ReviewRouting:
    team_owned: dict[str, str] = field(default_factory=dict)
    bucket_teams: list[str] = field(default_factory=list)


@dataclass
class LinearRules:
    own_only_actions: bool = True
    confirm_teams: list[str] = field(default_factory=list)
    dead_state_types: list[str] = field(default_factory=lambda: ["completed", "canceled", "duplicate"])


@dataclass
class BudgetThresholds:
    max_local_sessions: int = 8
    max_lanes_local: int = 3
    load1_per_cpu: float = 1.25
    swap_pct_max: int = 40
    mem_available_min_gib: float = 6.0
    profile_5h_pct_max: int = 70


@dataclass
class LaneDefaults:
    default_model: str = "claude-sonnet-5"
    default_effort: str = "medium"
    evaluate_model: str = "claude-fable-5-1"
    permission_mode: str = "auto"
    max_verdict_bytes: int = 4096
    machines: list[str] = field(default_factory=lambda: ["local"])
    memory_max: str = "6G"
    # Unexpanded: a remote machine's $HOME is not this process's, so a home-relative default must
    # not be resolved at import time on whichever machine happens to import this module (DO-652
    # correction 6). ``build_local`` expands it with ``Path.expanduser()`` at call time, and a
    # remote lane instead passes an absolute path proven to exist there (``resolve_remote``).
    claude_bin: str = "~/.local/bin/claude"


@dataclass
class Machine:
    name: str
    ssh: str
    tenants: list[str]
    repos: dict[str, str] = field(default_factory=dict)
    state_dir: str = "~/.local/state/rabota"
    # FILLED FROM THE REGISTRY, never from this file (DO-665). The seat a machine bills is
    # declared once, in the tenants file's CLAUDE_TENANT_MACHINE_OWNED / _MACHINE_ID pair, and
    # read through scripts/machines-render. A `profile` key left in a [machines.<m>] table is
    # a REFUSAL rather than an override -- see _tenant -- because a second copy that merely loses
    # is still a second copy, and the losing one is the one somebody will edit.
    profile: str | None = None


@dataclass
class Tenant:
    name: str
    root: Path
    state_dir: Path
    gh_config_dir: Path | None = None
    gh_login: str | None = None
    gh_pin_repo: str | None = None
    linear_key_env: str | None = None
    linear_viewer: str | None = None
    fireflies_key_env: str | None = None
    slack_user_id: str | None = None
    sources: list[str] = field(default_factory=lambda: ["github"])
    review_routing: ReviewRouting = field(default_factory=ReviewRouting)
    linear: LinearRules = field(default_factory=LinearRules)
    budget: BudgetThresholds = field(default_factory=BudgetThresholds)
    lanes: LaneDefaults = field(default_factory=LaneDefaults)
    machines: dict[str, Machine] = field(default_factory=dict)
    seats: dict[str, str] = field(default_factory=dict)   # {"local": "<clauth profile>"}; a REMOTE machine's seat comes from the registry (DO-665), not from here
    excludes: list[Path] = field(default_factory=list)
    # Set by ``_tenant`` to the tenant's own toml path; used only to name the file in a
    # resolve-time error (DO-764 review G1), never read for any other purpose.
    config_path: Path | None = None


@dataclass
class Config:
    """Every tenant this overlay declares. NO routes and NO default (DO-773).

    Which tenant owns a directory is answered by ``tenants.route`` from the tenants file, the
    one home for that fact — see ``rabota/tenants.py`` for why rabota gave up its own copy.
    """
    tenants: dict[str, Tenant]


def _dc(cls, data: dict):
    """Build dataclass ``cls`` from ``data``, ignoring keys it does not declare."""
    known = set(cls.__dataclass_fields__)
    return cls(**{k: v for k, v in data.items() if k in known})


def _tenant(name: str, d: dict, seats_by_machine: dict[str, str] | None = None,
            path: Path | None = None) -> Tenant:
    seats_by_machine = seats_by_machine or {}
    machines = {}
    for m, v in d.get("machines", {}).items():
        if "profile" in v:
            raise errors.Usage(
                f"{path or f'tenants/{name}.toml'}: "
                f"[machines.{m}] declares profile = {v['profile']!r}, which moved to the tenants "
                f"file in DO-665: set CLAUDE_TENANT_MACHINE_OWNED and CLAUDE_TENANT_MACHINE_ID "
                f"there and delete this key. Two copies of which seat a machine bills is the "
                f"defect, and a losing copy is still the one somebody edits")
        machines[m] = Machine(name=m, **v)
        machines[m].profile = seats_by_machine.get(m)
    # DO-764 review G1: an empty ``dead_state_types`` is NOT rejected here. ``load()`` builds
    # every tenants/*.toml before any command picks the one it needs (see ``load``'s docstring),
    # so raising in ``_tenant`` would fail every tenant's every command over one sibling's stray
    # toml. The check moved to ``resolve_tenant``, which only ever sees the tenant a command
    # actually resolved to -- a bad tenant's config can then only ever hurt that tenant.
    linear = _dc(LinearRules, d.get("linear", {}))
    return Tenant(
        name=name, root=_p(d["root"]), state_dir=_p(d["state_dir"]),
        gh_config_dir=_p(d.get("gh_config_dir")), gh_login=d.get("gh_login"),
        gh_pin_repo=d.get("gh_pin_repo"), linear_key_env=d.get("linear_key_env"),
        linear_viewer=d.get("linear_viewer"), fireflies_key_env=d.get("fireflies_key_env"),
        slack_user_id=d.get("slack_user_id"),
        sources=d.get("sources", ["github"]),
        review_routing=_dc(ReviewRouting, d.get("review_routing", {})),
        linear=linear,
        budget=_dc(BudgetThresholds, d.get("budget", {})),
        lanes=_dc(LaneDefaults, d.get("lanes", {})),
        machines=machines,
        seats=dict(d.get("seats", {})),
        excludes=[_p(x) for x in d.get("excludes", [])],
        config_path=path,
    )


def _toml(path: Path) -> dict:
    """Parse ``path``; a malformed file is a ``Usage`` error naming it, not a traceback."""
    try:
        with path.open("rb") as f:
            return tomllib.load(f)
    except tomllib.TOMLDecodeError as e:
        raise errors.Usage(f"malformed TOML in {path}: {e}") from None


def load(base: Path | None = None, seats_by_machine: dict[str, str] | None = None) -> Config:
    """Load ``config.toml`` and every ``tenants/*.toml`` under ``base`` (default ``~/.dotfiles-local/rabota``).

    Every fault in the files themselves — malformed TOML, a tenant missing a required
    key, a route or the default naming a tenant with no file — is a config problem the
    operator can fix, so it is ``Usage`` (exit 2) with the file and the key in the message.
    """
    base = Path(os.path.expanduser(str(base or DEFAULT_BASE)))
    main = base / "config.toml"
    if not main.exists():
        raise errors.RabotaError(f"missing config: {main}")
    top = _toml(main)
    # ASKED ONCE PER LOAD, and never cached to disk: a rendered copy is the duplication this
    # replaced, one level down. A fault raises out of machines.registry rather than yielding an
    # empty mapping, so "the renderer is missing" can never arrive as "no machine has a seat".
    # The parameter is the test seam, the same shape config.load already uses for `base`.
    if seats_by_machine is None:
        seats_by_machine = machines_mod.seats()
    # A LEFTOVER [[route]] OR default IS REFUSED, not ignored (DO-773). Both moved to the
    # tenants file, and a table that is still written here but no longer read is the worst of
    # the three states: it looks maintained, it is edited when routing surprises someone, and
    # it changes nothing. Naming it is the only way the move completes.
    stale = [k for k in ("route", "default") if k in top]
    if stale:
        raise errors.Usage(
            f"{main}: {' and '.join(sorted(stale))} moved to the tenants file in DO-773 — "
            f"CLAUDE_TENANT_ROUTES / CLAUDE_TENANT_PATH_ROUTES / CLAUDE_TENANT_DEFAULT in "
            f"~/.config/claude-tenants.zsh are the one home for which tenant owns a directory. "
            f"Delete {'them' if len(stale) > 1 else 'it'} from this file; rabota no longer reads "
            f"{'them' if len(stale) > 1 else 'it'}")
    tenants = {}
    for path in sorted((base / "tenants").glob("*.toml")):
        try:
            tenants[path.stem] = _tenant(path.stem, _toml(path), seats_by_machine, path)
        except KeyError as e:
            raise errors.Usage(f"{path}: missing required key {e.args[0]!r}") from None
        except TypeError as e:   # a [machines.<name>] table missing a Machine field
            raise errors.Usage(f"{path}: {e}") from None
    if not tenants:
        raise errors.Usage(f"{base}/tenants: no tenants/*.toml, so no tenant can ever be resolved")
    return Config(tenants=tenants)


def _check_dead_state_types(tenant: Tenant) -> None:
    # DO-764 review G1: moved here from ``_tenant`` so a bad tenant's config can only ever hurt
    # the tenant it belongs to. reconcile.py's found_open/found_closed split, sync.py and
    # inbox/buckets.py all key off this one field -- a tenant that declares no dead state types
    # can never read anything as closed, flipping "resolved" to read as "live" in three
    # subsystems at once -- so this runs on every path out of ``resolve_tenant``, not just the
    # override branch.
    if not tenant.linear.dead_state_types:
        raise errors.Usage(
            f"{tenant.config_path or f'tenants/{tenant.name}.toml'}: [linear] dead_state_types "
            f"is empty -- a tenant needs at least one dead state type, or every issue reads as "
            f"still open")


def resolve_tenant(cfg: Config, cwd: Path, env: Mapping[str, str], override: str | None,
                   route_fn=None) -> Tenant:
    """Pick a tenant: ``override`` → ``$CLAUDE_ACCOUNT_TENANT`` → whatever owns ``cwd``.

    The third step is ``tenants.route`` (DO-773), which asks the ACCOUNT PICKER's own resolver
    through ``scripts/tenant-route``: git remote owner first, then a path route, then the default.
    rabota used to answer it from a ``[[route]]`` table of its own, by path only, and the two
    disagreed for any repository checked out away from its tenant's root — one tenant for an
    interactive session and another for a lane in the same directory.

    THE FIRST TWO STEPS STILL SHORT-CIRCUIT, and that is load-bearing rather than an
    optimisation: every scripted caller passes ``--tenant``, so the fork is skipped on the path
    that runs most often, and a command that names its tenant keeps working in a directory git
    cannot read at all.

    A ROUTING FAULT RAISES; it never becomes the default. ``tenants.route`` documents why, and
    "git could not be asked" is the case it is written for.

    ``route_fn`` is the test seam — ``f(cwd) -> {"tenant", "state", "why"}`` — the same shape
    ``run_recipe`` uses for ``budget_fn``. It exists so the suite does not fork a shell per row;
    rows that mean to exercise the real ``scripts/tenant-route`` call it directly.
    """
    name = override or env.get("CLAUDE_ACCOUNT_TENANT")
    if not name:
        answer = (route_fn or tenants_mod.route)(Path(cwd))
        name = answer["tenant"]
        if name not in cfg.tenants:
            # The tenants file named a tenant this overlay has no file for. That is the two
            # halves of the configuration disagreeing, so it names BOTH sides: the reader has to
            # know which file to edit, and the router's own `why` says how that name was reached.
            raise errors.Usage(
                f"the tenant router routed {str(cwd)!r} to tenant {name!r} ({answer['why']}), "
                f"which has no tenants/{name}.toml; the routing tables in the tenants file and "
                f"the tenant files in this overlay disagree. Known here: {sorted(cfg.tenants)}")
    elif name not in cfg.tenants:
        raise errors.Usage(f"unknown tenant {name!r}; known: {sorted(cfg.tenants)}")
    tenant = cfg.tenants[name]
    _check_dead_state_types(tenant)
    return tenant
