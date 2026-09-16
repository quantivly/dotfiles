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


@dataclass
class Machine:
    name: str
    ssh: str
    tenants: list[str]
    repos: dict[str, str] = field(default_factory=dict)
    state_dir: str = "~/.local/state/rabota"


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
        excludes=[_p(x) for x in d.get("excludes", [])],
    )


def load(base: Path | None = None) -> Config:
    """Load ``config.toml`` and every ``tenants/*.toml`` under ``base`` (default ``~/.dotfiles-local/rabota``)."""
    base = Path(os.path.expanduser(str(base or DEFAULT_BASE)))
    main = base / "config.toml"
    if not main.exists():
        raise errors.RabotaError(f"missing config: {main}")
    with main.open("rb") as f:
        top = tomllib.load(f)
    routes = [(_p(r["prefix"]), r["tenant"]) for r in top.get("route", [])]
    tenants = {}
    for path in sorted((base / "tenants").glob("*.toml")):
        with path.open("rb") as f:
            tenants[path.stem] = _tenant(path.stem, tomllib.load(f))
    default = top.get("default", "personal")
    if default not in tenants:
        raise errors.RabotaError(f"default tenant {default!r} has no tenants/{default}.toml")
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
