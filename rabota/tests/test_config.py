import shutil
import tempfile
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

    def test_a_directory_with_no_override_is_routed_by_the_router(self):
        """DO-773: rabota no longer holds a route table. The tenant for a directory is whatever
        ``scripts/tenant-route`` says, and this pins that the answer is USED rather than
        recomputed — the fake returns a tenant no path rule of the old shape would have chosen
        for that directory."""
        seen = []
        def fake(cwd):
            seen.append(cwd)
            return {"tenant": "toysim", "state": "matched", "why": "owner route"}
        t = config.resolve_tenant(self.cfg, Path.home() / "quantivly" / "hub", {}, None, route_fn=fake)
        self.assertEqual(t.name, "toysim")
        self.assertEqual(seen, [Path.home() / "quantivly" / "hub"])

    def test_an_override_or_the_env_never_reaches_the_router(self):
        """Both short-circuits are load-bearing, not optimisations: every scripted caller passes
        ``--tenant``, and a command that names its tenant must keep working in a directory git
        cannot read at all."""
        def boom(cwd):
            raise AssertionError("the router was consulted although a tenant was named")
        self.assertEqual(config.resolve_tenant(self.cfg, Path("/"), {}, "toysim", route_fn=boom).name, "toysim")
        self.assertEqual(config.resolve_tenant(
            self.cfg, Path("/"), {"CLAUDE_ACCOUNT_TENANT": "personal"}, None, route_fn=boom).name, "personal")

    def test_a_router_answer_with_no_tenant_file_here_names_both_sides(self):
        """The routing tables and the tenant files are two halves of one configuration, in two
        repositories. When they disagree the reader has to be told which file to edit, so the
        message carries the router's own reason as well as what this overlay knows."""
        def fake(cwd):
            return {"tenant": "ghost", "state": "matched", "why": "remote owner 'ghost-co'"}
        with self.assertRaises(errors.Usage) as cm:
            config.resolve_tenant(self.cfg, Path("/"), {}, None, route_fn=fake)
        msg = str(cm.exception)
        self.assertIn("ghost", msg)
        self.assertIn("tenants/ghost.toml", msg)
        self.assertIn("ghost-co", msg)          # the router's WHY, not just its answer

    def test_a_repos_table_in_the_toml_reaches_the_tenant(self):
        """END TO END, from a file on disk. Found by mutation: every other [repos] row sets
        ``tenant.repos`` in Python, so replacing the loader's ``d.get("repos", {})`` with ``{}``
        — the table declared in the toml and never read — survived the entire suite. The feature
        could have been wired to nothing and shipped green."""
        base = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, base, ignore_errors=True)
        (base / "config.toml").write_text("")
        (base / "tenants").mkdir()
        (base / "tenants" / "solo.toml").write_text(
            'root = "~/code"\nstate_dir = "~/code/state"\n\n'
            '[repos]\ndotfiles = "~/.dotfiles"\nhub = "~/elsewhere/hub"\n')
        cfg = config.load(base, seats_by_machine={})
        self.assertEqual(cfg.tenants["solo"].repos,
                         {"dotfiles": "~/.dotfiles", "hub": "~/elsewhere/hub"})

    def test_a_tenant_declaring_no_repos_table_gets_an_empty_one(self):
        # Not None: every reader does `repo in tenant.repos` and `if tenant.repos`, and None
        # would raise inside the lane rather than fall back to the root form.
        self.assertEqual(self.cfg.tenants["personal"].repos, {})

    def test_the_config_carries_no_routes_or_default_of_its_own(self):
        """A regression row for the move itself: re-adding either field to Config is how the two
        tables come back, and it would pass every other row here."""
        self.assertFalse(hasattr(self.cfg, "routes"))
        self.assertFalse(hasattr(self.cfg, "default"))

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
        cfg = config.Config(tenants={"bad": bad})
        with self.assertRaises(errors.Usage):
            config.resolve_tenant(cfg, Path("/"), {}, "bad")

    def test_a_sibling_tenants_empty_dead_state_types_does_not_break_load_or_another_tenant(self):
        # DO-764 review G1: config.load() globs every tenants/*.toml before any command picks the
        # one it needs, so validating this at BUILD time (the pre-G1 shape) took down every
        # tenant's every command over one unrelated tenant's stray toml. It must not raise here.
        good = config._tenant("good", {"root": "~/g", "state_dir": "~/g/s"})
        bad = config._tenant("bad", {"root": "~/b", "state_dir": "~/b/s", "linear": {"dead_state_types": []}})
        cfg = config.Config(tenants={"good": good, "bad": bad})
        # the healthy tenant still resolves and works even though "bad" is broken
        self.assertEqual(config.resolve_tenant(cfg, Path("/"), {}, "good").name, "good")
        # but asking for the broken one by name still fails, loudly, naming its own file
        with self.assertRaises(errors.Usage):
            config.resolve_tenant(cfg, Path("/"), {}, "bad")
