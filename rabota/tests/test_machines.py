"""The machine registry rabota asks for rather than keeps (DO-665).

Every row here is about ONE property: a fault must never arrive as an empty registry. rabota's
seat gate reads "this machine has no seat" as a configuration choice and refuses the lane with a
message naming a file — so a renderer that returned ``{}`` on an error would turn "the renderer is
missing" into "you forgot to configure dev", and the operator would go and edit a file that is
already correct. The registry is small; the ways of getting nothing back are not.
"""
import json
import stat
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from rabota import config, errors, machines

FIX = Path(__file__).parent / "fixtures" / "config"
REAL = Path(__file__).resolve().parents[2] / "scripts" / "machines-render"


def fake_renderer(body: str) -> Path:
    """A stand-in renderer with a chosen exit status and output.

    Used ONLY for the failure shapes, which a real tenants file cannot produce (a renderer that
    prints a list, or nothing, or times out). The success path below runs the REAL script against
    a fixture tenants file, because a stub of that is a claim about the tool rather than a test
    of it.
    """
    d = Path(tempfile.mkdtemp())
    p = d / "render.sh"
    p.write_text("#!/usr/bin/env bash\n" + body + "\n")
    p.chmod(p.stat().st_mode | stat.S_IEXEC)
    return p


class RegistryTests(unittest.TestCase):
    def test_the_real_renderer_answers_from_the_fixture_tenants_file(self):
        # The end-to-end path, with no stub anywhere: the script this ships, the fork it does,
        # and the fixture file tests/__init__ points CLAUDE_TENANTS_FILE at.
        reg = machines.registry()
        self.assertEqual(reg, {"dev": {"profile": "quantivly-0", "label": "dev (EC2)"}})
        self.assertEqual(machines.seats(), {"dev": "quantivly-0"})

    def test_the_shipped_renderer_is_where_this_module_looks_for_it(self):
        # A path computed from __file__ is exactly the kind that survives every test and breaks
        # on a real checkout layout, so it is asserted rather than assumed.
        self.assertEqual(machines.RENDERER, REAL)
        self.assertTrue(REAL.exists(), f"{REAL} does not exist")

    def test_an_empty_registry_is_a_real_answer_and_does_not_raise(self):
        # The modular adopter owns no machine. This is the one case that legitimately yields
        # nothing, and it must be distinguishable from every failure below.
        self.assertEqual(machines.registry(fake_renderer('echo "{}"')), {})

    def test_a_missing_renderer_raises_rather_than_returning_nothing(self):
        with self.assertRaises(errors.Usage) as cm:
            machines.registry(Path("/nonexistent/machines-render"))
        self.assertIn("DO-665", str(cm.exception))

    def test_a_nonzero_exit_carries_the_renderers_own_message(self):
        # The renderer's stderr names the machine or profile at fault; summarising it into
        # "could not read the registry" would drop the only actionable part.
        r = fake_renderer('echo "machine \'dev\' is claimed by two profiles" >&2; exit 1')
        with self.assertRaises(errors.Usage) as cm:
            machines.registry(r)
        self.assertIn("claimed by two profiles", str(cm.exception))

    def test_a_nonzero_exit_with_no_message_still_raises(self):
        with self.assertRaises(errors.Usage) as cm:
            machines.registry(fake_renderer("exit 3"))
        self.assertIn("exit 3", str(cm.exception))

    def test_output_that_is_not_json_raises(self):
        with self.assertRaises(errors.Usage):
            machines.registry(fake_renderer('echo "not json"'))

    def test_json_that_is_not_an_object_raises(self):
        # A list would index as something else entirely downstream; `.get` on it is an
        # AttributeError three frames away from the cause.
        with self.assertRaises(errors.Usage) as cm:
            machines.registry(fake_renderer('echo "[]"'))
        self.assertIn("not an object", str(cm.exception))

    def test_an_entry_without_a_profile_raises_naming_the_machine(self):
        r = fake_renderer('echo \'{"dev": {"label": "dev (EC2)"}}\'')
        with self.assertRaises(errors.Usage) as cm:
            machines.registry(r)
        self.assertIn("dev", str(cm.exception))

    def test_a_timeout_raises_rather_than_hanging(self):
        old = machines.TIMEOUT
        machines.TIMEOUT = 1
        try:
            with self.assertRaises(errors.Usage) as cm:
                machines.registry(fake_renderer("sleep 5"))
            self.assertIn("timed out", str(cm.exception))
        finally:
            machines.TIMEOUT = old


class ConfigWiringTests(unittest.TestCase):
    def test_machine_profile_comes_from_the_registry_not_the_toml(self):
        cfg = config.load(FIX, seats_by_machine={"dev": "seat-from-registry"})
        self.assertEqual(cfg.tenants["quantivly"].machines["dev"].profile, "seat-from-registry")

    def test_a_machine_the_registry_does_not_name_gets_no_seat(self):
        # Not an error here: rabota's own gate (budget.seat_for) is what refuses, with a message
        # naming the machine. Filling a wrong seat would be far worse than filling none.
        cfg = config.load(FIX, seats_by_machine={})
        self.assertIsNone(cfg.tenants["quantivly"].machines["dev"].profile)

    def test_a_leftover_profile_key_in_the_toml_is_refused_not_ignored(self):
        # THE MIGRATION GUARD. Ignoring the key would leave a second copy of the fact that merely
        # loses — and the losing copy is the one somebody edits, which is the whole defect.
        import tomllib
        with (FIX / "tenants" / "quantivly.toml").open("rb") as f:
            d = tomllib.load(f)
        d["machines"]["dev"]["profile"] = "quantivly-0"
        with self.assertRaises(errors.Usage) as cm:
            config._tenant("quantivly", d, {"dev": "quantivly-0"})
        self.assertIn("DO-665", str(cm.exception))
        self.assertIn("quantivly-0", str(cm.exception))

    def test_a_renderer_failure_propagates_out_of_config_load(self):
        """THE SEAM, not the function.

        Every other row in this file proves ``machines.registry`` raises. None proved that
        ``config.load`` lets the exception through — and that is the only place a well-meaning
        ``except errors.RabotaError: seats_by_machine = {}`` would ever be written. Measured: such
        a swallow passes all 436 rows in this suite while turning "the renderer is missing" into
        "no machine has a seat", which rabota reports as a configuration choice and which disables
        every remote seat gate without a word. That is the exact failure this module's docstring
        claims to prevent, so it is asserted where it would actually be broken.
        """
        with mock.patch.object(machines, "RENDERER", Path("/nonexistent/machines-render")):
            with self.assertRaises(errors.Usage):
                config.load(FIX)

    def test_load_without_the_seam_asks_the_real_renderer(self):
        # The default argument is the production path; a test that only ever passes the seam
        # would leave `seats_by_machine=None` untested and the module's one caller unexercised.
        cfg = config.load(FIX)
        self.assertEqual(cfg.tenants["quantivly"].machines["dev"].profile, "quantivly-0")


if __name__ == "__main__":
    unittest.main()
