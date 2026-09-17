"""Per-invocation context every command builds first: config, tenant, store, runner, scrubbed env."""
import os
from contextlib import contextmanager
from datetime import date
from pathlib import Path

from rabota import config, secrets
from rabota.runner import SubprocessRunner
from rabota.store import Store

# Innermost-last stack of lists; ``Context.__init__`` appends itself to the top one. A command
# builds its own Context inside ``run(ns)``, so ``cli.main`` cannot hold it directly: it opens a
# collector around the run instead and closes whatever landed in it. A Context built outside any
# collector (a test's helper, say) is tracked by nobody and is its builder's to close.
_collectors = []


@contextmanager
def track_contexts():
    """Collect every ``Context`` built inside the block, so the caller can close them all."""
    opened = []
    _collectors.append(opened)
    try:
        yield opened
    finally:
        # Drop THIS list, found by identity. ``list.remove`` compares with ``==``, and two
        # empty collectors are equal — so an inner block exiting empty would take the OUTER
        # list off the stack, the next Context would land in a list nobody closes, and the
        # outer exit would raise ValueError.
        for i in range(len(_collectors) - 1, -1, -1):
            if _collectors[i] is opened:
                del _collectors[i]
                break


class Context:
    """Resolved tenant plus the injectable collaborators (runner, env, clock) a command needs."""

    def __init__(self, cfg, tenant, state_dir, runner, env, dry_run, today=None):
        self.cfg, self.tenant, self.state_dir = cfg, tenant, Path(state_dir)
        self.runner, self.env, self.dry_run = runner, env, dry_run
        self.today = today or date.today()
        self._store = None
        if _collectors:
            _collectors[-1].append(self)

    @property
    def store(self) -> Store:
        """The tenant's SQLite store, opened on first use."""
        if self._store is None:
            self._store = Store.open(self.state_dir)
        return self._store

    def close(self):
        """Close the store if this context opened one. Idempotent; a no-op if it never did."""
        store, self._store = self._store, None
        if store is not None:
            store.close()

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        self.close()   # returns None: never suppresses the body's exception

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
