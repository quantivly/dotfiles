"""Test package init — the one place the suite is made hermetic about the machine registry.

``config.load`` asks ``scripts/machines-render`` which seat each machine bills (DO-665), and
that renderer reads ``$CLAUDE_TENANTS_FILE`` or, failing that, the DEVELOPER'S OWN
``~/.config/claude-tenants.zsh``. Whoever runs this suite is very likely on a box whose real
tenants file names real seats, so without this the rows would be scored against whatever that
file happens to say today — and on CI, where no such file exists, against an empty registry.
Either way they would pass while asserting nothing about the fixture.

Set HERE rather than in a setUp: two test modules call ``config.load`` at IMPORT time
(``test_rank``, ``test_inbox_*``), which runs before any setUp, and a package ``__init__`` is the
only point that precedes them.

The real renderer runs against a fixture file — it is not stubbed. A stub is a claim about the
tool, and the fork-and-source behaviour it would be claiming is exactly what has gone wrong here
before.
"""
import os
from pathlib import Path

os.environ["CLAUDE_TENANTS_FILE"] = str(
    Path(__file__).parent / "fixtures" / "config" / "tenants.zsh")
