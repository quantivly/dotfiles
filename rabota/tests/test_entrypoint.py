"""``scripts/rabota`` picks an interpreter that can actually import ``tomllib`` (DO-712).

The entry point used to ``exec python3 -m rabota``. ``rabota/rabota/config.py`` imports ``tomllib``
at module load, which is 3.11+, so on any box whose ``python3`` is older the CLI died with
``ModuleNotFoundError: No module named 'tomllib'`` — measured on dev 2026-09-24, where
``/usr/bin/python3`` is 3.10.12 and ``python3.11`` (3.11.14) sits right beside it. A lane
dispatched there could not call ``rabota`` at all.

Every row here shadows EVERY candidate name in a temp directory at the head of ``PATH``. Shadowing
only ``python3`` would be a row that passes for the wrong reason: the loop would fall through to
this machine's real ``python3.14``, and the fixture would never prove which interpreter was chosen.
"""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ENTRY = Path(__file__).resolve().parents[2] / "scripts" / "rabota"

# Every name the entry point may try, in its own order. Read from the script rather than written
# out again here would be better still, but the list is the contract this row is about: a new
# candidate added there without a fixture entry here leaves a hole, so the row asserts the two
# agree (see test_the_fixture_shadows_every_candidate_the_script_tries).
CANDIDATES = ["python3", "python3.14", "python3.13", "python3.12", "python3.11"]

# A stub interpreter. `-c` decides whether it "has tomllib"; `-V` feeds the failure message;
# anything else (i.e. `-m rabota ...`) prints which stub was reached.
STUB = """#!/bin/sh
case "$1" in
  -c) exit %(rc)s ;;
  -V) echo 'Python %(ver)s' ; exit 0 ;;
  *)  echo 'RAN:%(name)s' ; exit 0 ;;
esac
"""


class EntryPointTests(unittest.TestCase):
    def bindir(self, has_tomllib: dict[str, bool]) -> str:
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, ignore_errors=True)
        for name in CANDIDATES:
            p = Path(d) / name
            p.write_text(STUB % {"rc": 0 if has_tomllib[name] else 1,
                                 "ver": name.replace("python", ""), "name": name})
            p.chmod(0o755)
        return d

    def run_entry(self, has_tomllib: dict[str, bool]):
        d = self.bindir(has_tomllib)
        env = dict(os.environ)
        # The stubs go FIRST; the real /usr/bin stays on so the script's own `readlink`, `dirname`
        # and `cd` still resolve. PYTHONPATH is cleared so nothing leaks in from the runner.
        env["PATH"] = f"{d}:/usr/bin:/bin"
        env.pop("PYTHONPATH", None)
        return subprocess.run([str(ENTRY), "version"], capture_output=True, text=True, env=env)

    def test_the_fixture_shadows_every_candidate_the_script_tries(self):
        """A candidate added to the script but not to CANDIDATES would fall through to this
        machine's real interpreter, and every row below would pass without proving anything."""
        line = next(l for l in ENTRY.read_text().splitlines() if l.startswith("candidates="))
        self.assertEqual(line.split("(", 1)[1].rstrip(")").split(), CANDIDATES)

    def test_it_uses_a_tomllib_capable_interpreter_when_python3_has_none(self):
        """dev's exact shape: `python3` is too old, `python3.11` is installed beside it."""
        res = self.run_entry({c: c == "python3.11" for c in CANDIDATES})
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("RAN:python3.11", res.stdout)

    def test_it_uses_python3_unchanged_when_python3_already_has_tomllib(self):
        """The precedence half. With BOTH capable, `python3` must still win — otherwise the row
        above would pass just as well under "always use python3.11", which is not the rule."""
        res = self.run_entry({c: True for c in CANDIDATES})
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("RAN:python3", res.stdout)
        self.assertNotIn("RAN:python3.11", res.stdout)

    def test_no_capable_interpreter_fails_loudly_naming_the_requirement(self):
        """Not a traceback from deep inside config.py, and not a silent fall-through to an
        interpreter that will die on import: a named refusal with the version it needs."""
        res = self.run_entry({c: False for c in CANDIDATES})
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("tomllib", res.stderr)
        self.assertIn("3.11", res.stderr)
        self.assertNotIn("RAN:", res.stdout)
