"""Tenant data lives in ~/.dotfiles-local/rabota (private overlay). Mechanism here."""
import os
import tomllib
from dataclasses import dataclass, field
from pathlib import Path
from typing import Mapping

from rabota import errors

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
    claude_bin: str = str(Path.home() / ".local/bin/claude")


@dataclass
class Machine:
    name: str
    ssh: str
    tenants: list[str]
    repos: dict[str, str] = field(default_factory=dict)
    state_dir: str = "~/.local/state/rabota"
    profile: str | None = None      # the clauth seat a headless lane on this machine bills


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
    slack_user_id: str | None = None
    sources: list[str] = field(default_factory=lambda: ["github"])
    review_routing: ReviewRouting = field(default_factory=ReviewRouting)
    linear: LinearRules = field(default_factory=LinearRules)
    budget: BudgetThresholds = field(default_factory=BudgetThresholds)
    lanes: LaneDefaults = field(default_factory=LaneDefaults)
    machines: dict[str, Machine] = field(default_factory=dict)
    seats: dict[str, str] = field(default_factory=dict)   # {"local": "<clauth profile>"}; dev seats are [machines.<m>].profile
    excludes: list[Path] = field(default_factory=list)


@dataclass
class Config:
    routes: list[tuple[Path, str]]
    default: str
    tenants: dict[str, Tenant]


def _dc(cls, data: dict):
    """Build dataclass ``cls`` from ``data``, ignoring keys it does not declare."""
    known = set(cls.__dataclass_fields__)
    return cls(**{k: v for k, v in data.items() if k in known})


def _tenant(name: str, d: dict) -> Tenant:
    machines = {m: Machine(name=m, **v) for m, v in d.get("machines", {}).items()}
    return Tenant(
        name=name, root=_p(d["root"]), state_dir=_p(d["state_dir"]),
        gh_config_dir=_p(d.get("gh_config_dir")), gh_login=d.get("gh_login"),
        gh_pin_repo=d.get("gh_pin_repo"), linear_key_env=d.get("linear_key_env"),
        linear_viewer=d.get("linear_viewer"), slack_user_id=d.get("slack_user_id"),
        sources=d.get("sources", ["github"]),
        review_routing=_dc(ReviewRouting, d.get("review_routing", {})),
        linear=_dc(LinearRules, d.get("linear", {})),
        budget=_dc(BudgetThresholds, d.get("budget", {})),
        lanes=_dc(LaneDefaults, d.get("lanes", {})),
        machines=machines,
        seats=dict(d.get("seats", {})),
        excludes=[_p(x) for x in d.get("excludes", [])],
    )


def _toml(path: Path) -> dict:
    """Parse ``path``; a malformed file is a ``Usage`` error naming it, not a traceback."""
    try:
        with path.open("rb") as f:
            return tomllib.load(f)
    except tomllib.TOMLDecodeError as e:
        raise errors.Usage(f"malformed TOML in {path}: {e}") from None


def load(base: Path | None = None) -> Config:
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
    routes = []
    for r in top.get("route", []):
        try:
            routes.append((_p(r["prefix"]), r["tenant"]))
        except KeyError as e:
            raise errors.Usage(f"{main}: a [[route]] entry is missing required key {e.args[0]!r}") from None
    tenants = {}
    for path in sorted((base / "tenants").glob("*.toml")):
        try:
            tenants[path.stem] = _tenant(path.stem, _toml(path))
        except KeyError as e:
            raise errors.Usage(f"{path}: missing required key {e.args[0]!r}") from None
        except TypeError as e:   # a [machines.<name>] table missing a Machine field
            raise errors.Usage(f"{path}: {e}") from None
    for prefix, tenant in routes:
        if tenant not in tenants:
            raise errors.Usage(f"{main}: route {str(prefix)!r} names tenant {tenant!r}, which has no tenants/{tenant}.toml")
    default = top.get("default", "personal")
    if default not in tenants:
        raise errors.Usage(f"{main}: default tenant {default!r} has no tenants/{default}.toml")
    return Config(routes=routes, default=default, tenants=tenants)


def resolve_tenant(cfg: Config, cwd: Path, env: Mapping[str, str], override: str | None) -> Tenant:
    """Pick a tenant: ``override`` → ``$CLAUDE_ACCOUNT_TENANT`` → longest route prefix of ``cwd`` → default."""
    name = override or env.get("CLAUDE_ACCOUNT_TENANT")
    if name:
        if name not in cfg.tenants:
            raise errors.Usage(f"unknown tenant {name!r}; known: {sorted(cfg.tenants)}")
        return cfg.tenants[name]
    cwd = Path(cwd).resolve()
    best = None
    for prefix, tenant in cfg.routes:
        try:
            cwd.relative_to(prefix.resolve())
        except ValueError:
            continue
        if best is None or len(str(prefix)) > len(str(best[0])):
            best = (prefix, tenant)
    return cfg.tenants[best[1] if best else cfg.default]
