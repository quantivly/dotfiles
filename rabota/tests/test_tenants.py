"""The tenant router rabota asks rather than keeps (DO-773).

Every row here is about ONE property: a fault must never arrive as a tenant. rabota gave up its
own ``[[route]]`` table, so this is the only thing standing between "git could not read that
directory" and a lane quietly billing whichever account the default names. A wrong tenant is not
a visible failure — it is a lane that runs, finishes, and books its window to somebody else.

The success path runs the REAL ``scripts/tenant-route`` against the fixture tenants file, for the
reason ``test_machines`` gives for the same choice: a stub of the script is a claim about the
script, and the fork-and-source behaviour it would be claiming is exactly the part that has gone
wrong before. The stub below is used only for shapes a real tenants file cannot produce.
"""
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from rabota import errors, tenants

REAL = Path(__file__).resolve().parents[2] / "scripts" / "tenant-route"


def fake_router(body: str) -> Path:
    """A stand-in router with a chosen exit status and output."""
    d = Path(tempfile.mkdtemp())
    p = d / "route.sh"
    p.write_text("#!/usr/bin/env bash\n" + body + "\n")
    p.chmod(p.stat().st_mode | stat.S_IEXEC)
    return p


class RealRouterTests(unittest.TestCase):
    """No stub anywhere: the shipped script, the fork it does, the fixture tenants file."""

    def test_a_directory_with_no_remote_gets_the_fixture_default(self):
        with tempfile.TemporaryDirectory() as d:
            answer = tenants.route(Path(d))
        self.assertEqual(answer["tenant"], "personal")
        self.assertEqual(answer["state"], "default")
        self.assertIn("no remote", answer["why"])

    def test_an_owner_route_beats_the_default_and_says_which_remote_decided(self):
        with tempfile.TemporaryDirectory() as d:
            subprocess.run(["git", "init", "-q", d], check=True)
            subprocess.run(["git", "-C", d, "remote", "add", "origin",
                            "git@github.com:fixture-org/thing.git"], check=True)
            answer = tenants.route(Path(d))
        self.assertEqual(answer["tenant"], "quantivly")
        self.assertEqual(answer["state"], "matched")
        self.assertIn("fixture-org", answer["why"])

    def test_a_directory_git_cannot_read_raises_rather_than_defaulting(self):
        # THE row. Falling through to the default here is how a work repository would draw the
        # personal pool in silence — the failure DO-773 exists to end, not a new way to have it.
        with self.assertRaises(errors.Usage) as cm:
            tenants.route(Path("/no/such/directory/anywhere"))
        self.assertIn("git-error", str(cm.exception))

    def test_the_shipped_router_is_where_this_module_looks_for_it(self):
        # A path computed from __file__ is invisible when it is wrong: the module would raise
        # "the tenant router is missing" and every caller would read it as a broken install.
        self.assertEqual(tenants.ROUTER, REAL)
        self.assertTrue(REAL.exists(), REAL)
        self.assertTrue(os.access(REAL, os.X_OK), f"{REAL} is not executable")


class RouterFaultTests(unittest.TestCase):
    """Shapes a real tenants file cannot produce, and none of them may return a tenant."""

    def route(self, body, cwd="/tmp"):
        return tenants.route(Path(cwd), router=fake_router(body))

    def test_a_missing_router_is_named_and_never_guessed_around(self):
        with self.assertRaises(errors.Usage) as cm:
            tenants.route(Path("/tmp"), router=Path("/no/such/router"))
        self.assertIn("tenant router is missing", str(cm.exception))

    def test_a_non_zero_exit_carries_the_routers_own_reason_through(self):
        # Three different faults hide behind a non-zero exit — git-error, bad-table and none —
        # with three different fixes, so the text is carried verbatim rather than summarised.
        with self.assertRaises(errors.Usage) as cm:
            self.route('echo "tenant-route: no tenant (state bad-table): entry is not x=y" >&2\nexit 2')
        self.assertIn("bad-table", str(cm.exception))
        self.assertIn("entry is not x=y", str(cm.exception))

    def test_a_silent_non_zero_exit_still_raises_and_says_the_code(self):
        with self.assertRaises(errors.Usage) as cm:
            self.route("exit 3")
        self.assertIn("exit 3", str(cm.exception))

    def test_output_that_is_not_json_raises(self):
        with self.assertRaises(errors.Usage) as cm:
            self.route('echo "personal"')
        self.assertIn("no JSON object", str(cm.exception))

    def test_a_json_list_raises_rather_than_indexing_as_something_else(self):
        # A type check before indexing: `.get` on a list is an AttributeError from inside this
        # module, which reaches the operator as a traceback rather than a named fault.
        with self.assertRaises(errors.Usage) as cm:
            self.route('echo "[]"')
        self.assertIn("not an object", str(cm.exception))

    def test_an_object_naming_no_tenant_raises(self):
        for body in ('echo \'{"state": "matched"}\'',
                     'echo \'{"tenant": "", "state": "matched"}\'',
                     'echo \'{"tenant": null, "state": "matched"}\'',
                     'echo \'{"tenant": 7, "state": "matched"}\''):
            with self.subTest(body=body):
                with self.assertRaises(errors.Usage) as cm:
                    self.route(body)
                self.assertIn("named no tenant", str(cm.exception))

    def test_an_unknown_state_is_refused_even_with_a_tenant_beside_it(self):
        # The router promises to exit non-zero for every state it cannot answer from, so one
        # arriving here means the two sides have drifted — and guessing which way is how the
        # wrong tenant gets used with nothing printed.
        with self.assertRaises(errors.Usage) as cm:
            self.route('echo \'{"tenant": "personal", "state": "probably-fine"}\'')
        self.assertIn("probably-fine", str(cm.exception))
        self.assertIn("will not guess", str(cm.exception))

    def test_every_state_the_router_promises_is_accepted(self):
        for state in tenants.USABLE_STATES:
            with self.subTest(state=state):
                answer = self.route('echo \'{"tenant": "personal", "state": "%s", "why": "w"}\'' % state)
                self.assertEqual(answer, {"tenant": "personal", "state": state, "why": "w"})

    def test_a_missing_why_becomes_an_empty_string_not_the_word_none(self):
        # `why` is pasted into operator-facing messages; `str(None)` there reads as a reason.
        answer = self.route('echo \'{"tenant": "personal", "state": "default"}\'')
        self.assertEqual(answer["why"], "")

    def test_a_timeout_is_a_named_error_not_a_hang_or_a_traceback(self):
        with mock.patch.object(tenants.subprocess, "run",
                               side_effect=tenants.subprocess.TimeoutExpired("x", 15)):
            with self.assertRaises(errors.Usage) as cm:
                tenants.route(Path("/tmp"), router=REAL)
        self.assertIn("timed out", str(cm.exception))

    def test_a_router_that_cannot_be_executed_is_a_named_error(self):
        d = Path(tempfile.mkdtemp())
        p = d / "not-executable"
        p.write_text("#!/usr/bin/env bash\ntrue\n")   # exists, but no +x
        with self.assertRaises(errors.Usage) as cm:
            tenants.route(Path("/tmp"), router=p)
        self.assertIn("could not run", str(cm.exception))

    def test_the_directory_is_what_gets_asked_about(self):
        # Without this, a router invoked with no argument would answer about the CALLER's cwd and
        # every row above would still pass — the tenant would just be somebody else's.
        answer = self.route('printf \'{"tenant": "personal", "state": "default", "why": "%s"}\' "$1"',
                            cwd="/tmp/some/where")
        self.assertEqual(answer["why"], "/tmp/some/where")
