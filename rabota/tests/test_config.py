import unittest
from pathlib import Path
from rabota import config, errors

FIX = Path(__file__).parent / "fixtures" / "config"

class ConfigTests(unittest.TestCase):
    def setUp(self):
        self.cfg = config.load(FIX)

    def test_loads_three_tenants_with_defaults(self):
        self.assertEqual(set(self.cfg.tenants), {"quantivly", "toysim", "personal"})
        q = self.cfg.tenants["quantivly"]
        self.assertEqual(q.budget.max_lanes_local, 3)
        self.assertEqual(q.machines["dev"].tenants, ["quantivly"])
        t = self.cfg.tenants["toysim"]
        self.assertEqual(t.lanes.machines, ["local"])
        self.assertEqual(t.linear.dead_state_types, ["completed", "canceled", "duplicate"])  # default
        self.assertEqual(t.budget.max_lanes_local, 3)  # default

    def test_override_wins(self):
        t = config.resolve_tenant(self.cfg, Path.home() / "quantivly", {}, "toysim")
        self.assertEqual(t.name, "toysim")

    def test_env_beats_path(self):
        t = config.resolve_tenant(self.cfg, Path.home() / "quantivly", {"CLAUDE_ACCOUNT_TENANT": "personal"}, None)
        self.assertEqual(t.name, "personal")

    def test_longest_prefix_then_default(self):
        self.assertEqual(config.resolve_tenant(self.cfg, Path.home() / "quantivly" / "hub", {}, None).name, "quantivly")
        self.assertEqual(config.resolve_tenant(self.cfg, Path("/tmp/elsewhere"), {}, None).name, "personal")

    def test_unknown_override_is_usage(self):
        with self.assertRaises(errors.Usage):
            config.resolve_tenant(self.cfg, Path("/"), {}, "nope")

    def test_paths_are_expanded(self):
        self.assertEqual(self.cfg.tenants["quantivly"].root, Path.home() / "quantivly")
        self.assertEqual(self.cfg.tenants["personal"].excludes, [Path.home() / "Projects" / "nanoclaw"])

    def test_empty_dead_state_types_is_a_usage_error_at_resolve(self):
        # DO-764 review F3: an explicit empty list used to be honoured verbatim with no
        # validation, silently flipping reconcile.py's found_open/found_closed split (and sync.py's
        # and inbox/buckets.py's notion of "closed") the wrong way for the whole tenant.
        bad = config._tenant("bad", {"root": "~/t", "state_dir": "~/t/s", "linear": {"dead_state_types": []}})
        cfg = config.Config(routes=[], default="bad", tenants={"bad": bad})
        with self.assertRaises(errors.Usage):
            config.resolve_tenant(cfg, Path("/"), {}, "bad")

    def test_a_sibling_tenants_empty_dead_state_types_does_not_break_load_or_another_tenant(self):
        # DO-764 review G1: config.load() globs every tenants/*.toml before any command picks the
        # one it needs, so validating this at BUILD time (the pre-G1 shape) took down every
        # tenant's every command over one unrelated tenant's stray toml. It must not raise here.
        good = config._tenant("good", {"root": "~/g", "state_dir": "~/g/s"})
        bad = config._tenant("bad", {"root": "~/b", "state_dir": "~/b/s", "linear": {"dead_state_types": []}})
        cfg = config.Config(routes=[], default="good", tenants={"good": good, "bad": bad})
        # the healthy tenant still resolves and works even though "bad" is broken
        self.assertEqual(config.resolve_tenant(cfg, Path("/"), {}, "good").name, "good")
        # but asking for the broken one by name still fails, loudly, naming its own file
        with self.assertRaises(errors.Usage):
            config.resolve_tenant(cfg, Path("/"), {}, "bad")
