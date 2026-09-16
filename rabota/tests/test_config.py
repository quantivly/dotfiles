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
