"""The machine registry: which clauth seat each machine bills, asked rather than kept.

Until DO-665 this fact was written down twice — ``CLAUDE_TENANT_MACHINE_OWNED`` in
``~/.config/claude-tenants.zsh`` (profile -> a human label) and ``[machines.<m>].profile`` here
(machine id -> profile) — in two files, two formats and two languages, with nothing checking they
agreed. Divergence was silent both ways: reassign a seat in one and the other goes on gating the
seat that machine no longer bills.

WHY THE TENANTS FILE WON, and rabota gave up its copy. A stale copy on the dotfiles side fails
OPEN and SILENTLY: ``claude-profile-foreign`` reads an empty table as "no machine owns anything",
and the DO-632 / DO-641 guards simply stop refusing with nothing said. rabota fails LOUDLY —
a missing seat is a ``Refused`` naming the file. So the hand-edited copy stays where staleness
would not be noticed, and the loud side asks.

AND NOTHING IS CACHED TO DISK. A rendered file is the same defect one level down, so this shells
out to ``scripts/machines-render`` on demand, the way ``rabota doctor`` already shells out to
``claude-pick``. One ``zsh -f`` fork per config load, measured in single-digit milliseconds.

A FAILURE IS NEVER AN EMPTY REGISTRY **on this side**. Every error path here raises; none
returns ``{}`` on a fault. The renderer has to hold the same line for itself, and the first two
cuts of it did not — see ``docs/CLAUDE_ACCOUNT_PICKER.md``; this module cannot tell an honest
``{}`` from a fault upstream, which is exactly why the guarantee has to be made there too. An empty registry is a real answer — a modular adopter owns no machine — and conflating
the two would turn "the renderer is missing" into "no machine has a seat", which reads as a
configuration choice and disables every seat gate without a word. That direction is the whole
reason this module exists.
"""
import json
import subprocess
from pathlib import Path

from rabota import errors

# Relative to this module, not to ~/.dotfiles: rabota ships inside the dotfiles repo, and a
# worktree or a test checkout must use ITS OWN renderer rather than whichever one happens to be
# deployed at ~/.dotfiles. doctor.py's EXPECTED_LINK asks a different question (is the deployed
# link the one this checkout provides) and keeps its absolute path for that reason.
RENDERER = Path(__file__).resolve().parents[2] / "scripts" / "machines-render"

# Long enough for a cold `zsh -f` fork on a loaded box, short enough that a wedged renderer is an
# error rather than a hang. The renderer does no I/O beyond reading one small file.
TIMEOUT = 15


def registry(renderer: Path | None = None, env: dict | None = None) -> dict[str, dict]:
    """``{machine_id: {"profile": str, "label": str}}``, from the tenants file.

    Raises ``errors.Usage`` when the answer cannot be obtained — a missing renderer, a non-zero
    exit (the renderer's own cross-check found the two halves of the fact disagreeing), a timeout,
    or output that is not the object this promises.
    """
    path = Path(renderer) if renderer else RENDERER
    if not path.exists():
        raise errors.Usage(
            f"the machine registry renderer is missing ({path}); rabota reads which seat a "
            f"machine bills from the tenants file through it (DO-665), and will not assume "
            f"no machine has a seat")
    try:
        res = subprocess.run([str(path)], capture_output=True, text=True, timeout=TIMEOUT,
                             env=env)
    except subprocess.TimeoutExpired:
        raise errors.Usage(f"the machine registry renderer timed out after {TIMEOUT}s ({path})")
    except OSError as e:
        raise errors.Usage(f"could not run the machine registry renderer {path}: {e}")
    if res.returncode != 0:
        # The renderer's stderr already names the machine or profile at fault, so it is carried
        # through verbatim rather than summarised into "could not read the registry".
        detail = (res.stderr or "").strip() or f"exit {res.returncode} with no message"
        raise errors.Usage(f"the machine registry is unusable: {detail}")
    try:
        data = json.loads(res.stdout)
    except json.JSONDecodeError as e:
        raise errors.Usage(f"the machine registry renderer printed no JSON object ({e})")
    # A type check, not a truthiness check: `{}` is a legitimate registry and must survive, while
    # a list or a bare string would index as something else entirely further down.
    if not isinstance(data, dict):
        raise errors.Usage(
            f"the machine registry renderer printed {type(data).__name__}, not an object")
    for name, row in data.items():
        if not isinstance(row, dict) or not row.get("profile"):
            raise errors.Usage(
                f"the machine registry entry for {name!r} declares no profile")
    return data


def seats(renderer: Path | None = None, env: dict | None = None) -> dict[str, str]:
    """``{machine_id: profile}`` — the registry with the display labels dropped."""
    return {m: row["profile"] for m, row in registry(renderer, env).items()}
