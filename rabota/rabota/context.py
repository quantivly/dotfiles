"""Per-invocation context every command builds first: config, tenant, store, runner, scrubbed env."""
import os
from datetime import date
from pathlib import Path

from rabota import config, secrets
from rabota.runner import SubprocessRunner
from rabota.store import Store


class Context:
    """Resolved tenant plus the injectable collaborators (runner, env, clock) a command needs."""

    def __init__(self, cfg, tenant, state_dir, runner, env, dry_run, today=None):
        self.cfg, self.tenant, self.state_dir = cfg, tenant, Path(state_dir)
        self.runner, self.env, self.dry_run = runner, env, dry_run
        self.today = today or date.today()
        self._store = None

    @property
    def store(self) -> Store:
        """The tenant's SQLite store, opened on first use."""
        if self._store is None:
            self._store = Store.open(self.state_dir)
        return self._store

    @classmethod
    def from_namespace(cls, ns, cfg_base=None, runner=None, env=None, cwd=None, today=None):
        """Build a context from parsed args; every keyword lets a test inject a substitute."""
        env = dict(env if env is not None else os.environ)
        cfg = config.load(cfg_base)
        tenant = config.resolve_tenant(cfg, Path(cwd or Path.cwd()), env, getattr(ns, "tenant", None))
        state_dir = Path(getattr(ns, "state_dir", None) or tenant.state_dir)
        scrubbed = secrets.scrub_env(env)
        return cls(cfg, tenant, state_dir, runner or SubprocessRunner(scrubbed), scrubbed,
                   bool(getattr(ns, "dry_run", False)), today)
