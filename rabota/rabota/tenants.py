"""Which tenant owns a directory: asked rather than kept.

Until DO-773 this was answered twice, by different keys. ``config.resolve_tenant`` routed by cwd
PATH PREFIX, from rabota's own ``[[route]]`` table; the account picker
(``_claude_tenant_for`` in ``zsh/zshrc.herdr``) routes by GIT REMOTE OWNER first, then a path
route, then the default. One directory, two tenants — and on the box this was found on, two live:
``~/.dotfiles`` and a Toysim checkout under the personal root each resolved one way for an
interactive session and the other for a lane. Different seats, different gh identities, pools with
nothing in common. A lane billed one account and the session beside it billed another.

WHICH RULE SURVIVED. The picker's, because it is the one with an argument behind it: a
repository's identity travels with the repository, and where it happens to be checked out does
not. ``zsh/zshrc.herdr`` states it — "Only a directory with no GitHub remote may be decided by its
PLACE" — and that rule exists to stop a work repository drawing the personal pool.

AND RABOTA GAVE UP ITS COPY, the same trade DO-665 made for the machine registry one field over.
The ``[[route]]`` table and ``default`` are gone from ``config.toml``; the tenants file is the one
home for "which tenant owns this place". Two tables that agree today are two tables that can
disagree tomorrow, silently, and this one had already started to.

NOTHING IS CACHED AND NOTHING IS REIMPLEMENTED. A rendered copy is the same defect one level
down, so this shells out to ``scripts/tenant-route`` on demand — which in turn *calls* the
picker's resolver rather than parsing remotes again in Python. Measured 2026-09-28 at ~34 ms per
call on this box, slightly cheaper than the ``machines-render`` fork ``config.load`` already
makes, and skipped entirely when ``--tenant`` or ``$CLAUDE_ACCOUNT_TENANT`` answers first.

A FAILURE IS NEVER A TENANT. Every error path here raises; none returns a name. "git could not be
asked" is not "there is nothing here", and a router that fell through to the default on a git
error would hand a work repository the personal pool in silence — which is the failure this
module exists to end, not a new way to have it.
"""
import json
import subprocess
from pathlib import Path

from rabota import errors

# Relative to this module, not to ~/.dotfiles: rabota ships inside the dotfiles repo, and a
# worktree or a test checkout must route through ITS OWN copy of the picker rather than whichever
# one happens to be deployed. Same rule, and the same reason, as ``machines.RENDERER``.
ROUTER = Path(__file__).resolve().parents[2] / "scripts" / "tenant-route"

# Long enough for a cold `zsh -f` fork plus one `git remote` on a loaded box, short enough that a
# wedged router is an error rather than a hang. Matches machines.TIMEOUT.
TIMEOUT = 15

# The states ``scripts/tenant-route`` may report on its success path. ``unsupported`` reaches here
# with a usable tenant and means the OWNER half of the table could not be evaluated, so the answer
# was produced from the path routes alone — a complete-looking answer computed with half the rule.
# It is accepted (the picker accepts it too) and carried through so a caller can say so.
USABLE_STATES = ("matched", "default", "unsupported")


def route(cwd: Path, router: Path | None = None, env: dict | None = None) -> dict:
    """``{"tenant": str, "state": str, "why": str}`` for ``cwd``.

    Raises ``errors.Usage`` when the answer cannot be obtained — a missing router, a non-zero exit
    (no tenants file, a malformed table, or git unable to read the directory), a timeout, or
    output that is not the object this promises. There is no "no answer" return value: every
    directory belongs to someone, and a blank a caller might read as "the default" is the one
    shape this must not produce.
    """
    path = Path(router) if router else ROUTER
    if not path.exists():
        raise errors.Usage(
            f"the tenant router is missing ({path}); rabota reads which tenant owns a directory "
            f"through it (DO-773), and will not fall back to a route table of its own")
    try:
        res = subprocess.run([str(path), str(cwd)], capture_output=True, text=True,
                             timeout=TIMEOUT, env=env)
    except subprocess.TimeoutExpired:
        raise errors.Usage(f"the tenant router timed out after {TIMEOUT}s ({path})")
    except OSError as e:
        raise errors.Usage(f"could not run the tenant router {path}: {e}")
    if res.returncode != 0:
        # The router's stderr already names the directory and the resolver's own reason — which
        # of `git-error`, `bad-table` and `none` it was, and what to fix. Carried through verbatim
        # rather than summarised into "could not route", because those are three different faults.
        detail = (res.stderr or "").strip() or f"exit {res.returncode} with no message"
        raise errors.Usage(f"no tenant for {str(cwd)!r}: {detail}")
    try:
        data = json.loads(res.stdout)
    except json.JSONDecodeError as e:
        raise errors.Usage(f"the tenant router printed no JSON object ({e})")
    # A type check before indexing, not a truthiness check: a list or a bare string would index as
    # something else entirely below, and `.get` on a non-dict raises AttributeError from inside
    # this module rather than a named Usage error.
    if not isinstance(data, dict):
        raise errors.Usage(f"the tenant router printed {type(data).__name__}, not an object")
    name, state = data.get("tenant"), data.get("state")
    if not isinstance(name, str) or not name:
        raise errors.Usage(f"the tenant router named no tenant for {str(cwd)!r}")
    if state not in USABLE_STATES:
        # An unknown state is not a usable answer even WITH a tenant beside it: the router
        # promises to exit non-zero for every state it cannot answer from, so one arriving here is
        # the two sides having drifted, and guessing which way is how a wrong tenant gets used.
        raise errors.Usage(
            f"the tenant router reported state {state!r} for {str(cwd)!r}, which is not one of "
            f"{list(USABLE_STATES)}; rabota will not guess what it meant")
    return {"tenant": name, "state": state, "why": str(data.get("why") or "")}
