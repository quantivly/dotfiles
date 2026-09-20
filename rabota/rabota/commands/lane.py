"""``rabota lane recipe``: render (and optionally run) exactly one lane unit.

The whole lifecycle this command owns is "start it and record one row". No polling, no retire,
no attach: ``census`` observes the unit and settles the row, ``reap`` abandons a stale one.

It is the ONE door a headless lane comes through, which is why every spawner shares
``claude-pick --gate`` beneath it (``rabota budget``). A second door that skips the gate is how
a window gets spent unmetered.

This module currently supplies the local form only: ``unit_name`` and ``build_local``. The
subcommand itself (argument parsing, the remote form, and the registration with ``cli``) is
built on top of these in a later task.
"""
import re
import uuid
from pathlib import Path

SAFE = re.compile(r"[^A-Za-z0-9._-]+")


def unit_name(tenant: str, slug: str) -> str:
    """``rabota-lane-<tenant>-<slug>-<uuid8>.service``, with the slug reduced to safe characters."""
    s = SAFE.sub("-", slug).strip("-").lower() or "lane"
    return f"rabota-lane-{tenant}-{s}-{uuid.uuid4().hex[:8]}.service"


def seat_config_dir(seat: str) -> str:
    """The account dir a lane bills. One per seat, as claude() builds them."""
    return str(Path.home() / f".claude-{seat}")


def build_local(ctx, *, seat, repo, worktree, out_dir, brief, model, effort, unit,
                session_id: str | None = None) -> list[str]:
    """The systemd-run argv for a lane on this machine. Every value is an argv element, never a string."""
    return [
        "systemd-run", "--user", "--collect", f"--unit={unit}",
        f"--working-directory={worktree}",
        f"--setenv=CLAUDE_CONFIG_DIR={seat_config_dir(seat)}",
        "-p", f"StandardOutput=append:{out_dir}/stream.jsonl",
        "-p", f"StandardError=append:{out_dir}/stream.err",
        "-p", f"MemoryMax={ctx.tenant.lanes.memory_max}",
        ctx.tenant.lanes.claude_bin,
        "-p", f"Read {brief} and execute.",
        "--output-format", "stream-json", "--verbose",
        "--session-id", session_id or str(uuid.uuid4()),
        "--model", model, "--effort", effort,
        "--permission-mode", ctx.tenant.lanes.permission_mode,
        "--add-dir", out_dir,
    ]
