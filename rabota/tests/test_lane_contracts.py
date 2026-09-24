import json, tempfile, unittest
from pathlib import Path
from rabota import errors
from rabota.lanes import brief, verdict

GOOD_BRIEF = """# Smoke: prove the lane substrate
## Common rules
Read `_common-rules.md`, in this brief's own directory.
## Role
You investigate; you do not implement.
## Assignment
1. Run `rabota version` and record the output.
## Ownership
Write only under out_dir.
## Outputs
out_dir: /tmp/lane-out
verdict.json as in spec §C6.
## Summary
One line.
"""


class ContractTests(unittest.TestCase):
    def tmpfile(self, text):
        d = tempfile.TemporaryDirectory(); self.addCleanup(d.cleanup)
        p = Path(d.name) / "f"; p.write_text(text); return p

    def test_brief_ok(self):
        meta = brief.validate(self.tmpfile(GOOD_BRIEF))
        self.assertEqual(meta["out_dir"], "/tmp/lane-out"); self.assertEqual(meta["title"], "Smoke: prove the lane substrate")

    def test_brief_missing_sections_named(self):
        with self.assertRaises(errors.Usage) as cm:
            brief.validate(self.tmpfile("# t\n## Role\n"))
        self.assertIn("## Ownership", str(cm.exception)); self.assertIn("## Outputs", str(cm.exception))

    def test_shipped_smoke_brief_validates(self):
        smoke = Path(__file__).parent.parent / "briefs" / "smoke.md"
        self.assertEqual(brief.validate(smoke)["title"], "Smoke: prove the lane substrate")

    def test_an_unreadable_verdict_is_a_verdict_error_not_an_oserror(self):
        """DO-670 review: a mode-0 verdict escaped as PermissionError, which `lane recipe` does
        not catch — the CLI exited 5 with a traceback instead of refusing. Unreadable is a
        refusal like absent is."""
        import os
        if os.geteuid() == 0:
            self.skipTest("root reads a mode-0 file, so this row cannot hold")
        p = self.tmpfile(json.dumps({"lane": "l1", "status": "done", "claims": [],
                                     "deliverables": [], "followups": []}))
        p.chmod(0o000)
        self.addCleanup(p.chmod, 0o600)
        with self.assertRaises(verdict.VerdictError):
            verdict.validate(p, 4096)

    def test_verdict_text_and_file_apply_the_same_rules(self):
        """The remote path validates content someone else fetched; it must not be a second,
        laxer implementation of the shape rules."""
        bad = '{"lane": "x"}'
        with self.assertRaises(verdict.VerdictError):
            verdict.validate_text(bad, 4096, where="dev:/o/verdict.json")
        with self.assertRaises(verdict.VerdictError):
            verdict.validate(self.tmpfile(bad), 4096)

    def test_verdict_ok_and_oversize(self):
        v = {"lane": "l1", "status": "done", "claims": [{"id": "c1", "text": "t", "evidence": {"cmd": "true", "expected": "", "observed": ""}, "confidence": "high"}],
             "deliverables": [], "followups": []}
        p = self.tmpfile(json.dumps(v))
        self.assertEqual(verdict.validate(p, 4096)["lane"], "l1")
        with self.assertRaises(verdict.VerdictError) as cm:
            verdict.validate(p, 10)
        self.assertIn("bytes", str(cm.exception))

    def test_a_refused_claim_names_the_keys_it_wanted(self):
        """DO-710: the refusal said "claim malformed" and printed the claim back, so a lane that
        had followed a brief with the wrong key names could not tell which names were wrong. The
        shipped smoke brief did exactly that, and diagnosing it took four commands."""
        v = {"lane": "l1", "status": "done", "deliverables": [], "followups": [],
             "claims": [{"description": "t", "evidence": {"cmd": "true"}, "confidence": "medium"}]}
        with self.assertRaises(verdict.VerdictError) as cm:
            verdict.validate(self.tmpfile(json.dumps(v)), 4096)
        msg = str(cm.exception)
        self.assertIn("id", msg)
        self.assertIn("text", msg)

    def test_a_claim_missing_only_evidence_cmd_says_so(self):
        """The nested key is the other way a claim is refused, and it must be named too rather
        than reported as a whole-claim problem."""
        v = {"lane": "l1", "status": "done", "deliverables": [], "followups": [],
             "claims": [{"id": "c1", "text": "t", "evidence": {"expected": "x"}}]}
        with self.assertRaises(verdict.VerdictError) as cm:
            verdict.validate(self.tmpfile(json.dumps(v)), 4096)
        self.assertIn("evidence.cmd", str(cm.exception))

    def test_the_shipped_smoke_brief_names_every_key_this_validator_requires(self):
        """DO-710 review F1: the first version of this row grepped smoke.md for hand-written
        strings, so renaming verdict.py's required key from `text` to `description` left it
        passing — a guard that could not fail. It now reads the requirement from
        verdict.CLAIM_REQUIRED, so a rename there breaks this row until the brief follows."""
        brief_md = Path(__file__).resolve().parents[1] / "briefs" / "smoke.md"
        if not brief_md.exists():
            self.skipTest("smoke.md not present in this checkout")
        outputs = brief_md.read_text().split("## Outputs", 1)[1]
        import re
        for key in verdict.CLAIM_REQUIRED + tuple(n.split(".")[1] for n in verdict.CLAIM_REQUIRED_NESTED):
            self.assertRegex(outputs, rf"\b{re.escape(key)}\b",
                             f"smoke.md Outputs must name {key!r}, which verdict.py requires")

    def test_a_claim_built_from_the_brief_s_documented_shape_validates(self):
        """The other half of F1: assert the shape the brief asks for actually passes the
        validator, rather than only that the words appear."""
        claim = {k: "x" for k in verdict.CLAIM_REQUIRED}
        claim["evidence"] = {"cmd": "true", "expected": "", "observed": ""}
        claim["confidence"] = "high"
        v = {"lane": "l1", "status": "done", "claims": [claim], "deliverables": [], "followups": []}
        self.assertEqual(verdict.validate_text(json.dumps(v), 4096, where="x")["lane"], "l1")

    def test_verdict_bad_shape(self):
        with self.assertRaises(verdict.VerdictError):
            verdict.validate(self.tmpfile('{"lane": "l1", "status": "maybe", "claims": [], "deliverables": [], "followups": []}'), 4096)
        with self.assertRaises(verdict.VerdictError):
            verdict.validate(Path("/nonexistent/verdict.json"), 4096)

    def test_render_evaluate_names_lane_and_paths(self):
        text = brief.render_evaluate({"id": "smoke", "brief": "/b/smoke.md"}, Path("/o/smoke/verdict.json"), Path("/o/smoke-eval"))
        self.assertIn("/o/smoke/verdict.json", text); self.assertIn("out_dir: /o/smoke-eval", text)
        brief.validate(self.tmpfile(text))   # the evaluate brief is itself a valid brief


class CommonRulesTests(unittest.TestCase):
    """DO-711. Every brief opened with `Read /home/zvi/quantivly/handoffs/rabota/_common-rules.md`.

    That path exists on the laptop and on no other machine — and `dev`, the only machine where
    `lane recipe --run` works, has it under neither `/home/zvi` nor its own `$HOME`. So every lane
    dispatched there failed its first instruction and then carried on without the hard rails (the
    first of which is "nothing outward-facing, ever"). One lane reported it in `followups`; nothing
    in the substrate detected it, because `brief.validate` — which requires the `## Common rules`
    heading — was never called from the dispatch path at all.

    These rows hold the class, not the instance: any absolute path under that heading is refused,
    wherever it points.
    """

    def tmpfile(self, text):
        d = tempfile.TemporaryDirectory(); self.addCleanup(d.cleanup)
        p = Path(d.name) / "f"; p.write_text(text); return p

    def test_the_shipped_rules_file_exists_and_carries_the_outward_facing_rail(self):
        """Read from `brief.RULES`, not from a path spelled out here: the constant is what
        `run_recipe` ships, so moving the file without moving the constant must break this row.
        The needle is the one rail whose absence would be worst — a lane that merges or comments."""
        text = brief.read_rules()
        self.assertIn("Nothing outward-facing, ever", text)

    def test_read_rules_refuses_an_absent_file(self):
        with self.assertRaises(errors.Refused):
            brief.read_rules(Path("/nonexistent/_common-rules.md"))

    def test_read_rules_refuses_an_empty_file(self):
        """Empty is a lane with no rails, and it arrives looking exactly like success."""
        with self.assertRaises(errors.Refused) as cm:
            brief.read_rules(self.tmpfile("   \n\n"))
        self.assertIn("empty", str(cm.exception))

    def test_a_brief_naming_an_absolute_rules_path_is_refused(self):
        bad = GOOD_BRIEF.replace("Read `_common-rules.md`, in this brief's own directory.",
                                 "Read /home/zvi/quantivly/handoffs/rabota/_common-rules.md.")
        with self.assertRaises(errors.Usage) as cm:
            brief.validate(self.tmpfile(bad))
        # The message must NAME the path it refused — DO-710's lesson about a refusal that says
        # "malformed" and leaves the reader to guess which key it meant.
        self.assertIn("/home/zvi/quantivly/handoffs/rabota/_common-rules.md", str(cm.exception))
        self.assertIn(brief.RULES.name, str(cm.exception))

    def test_a_home_relative_rules_path_is_refused_too(self):
        """`~` is not a laptop-only path in the same way, it is worse: it expands against whichever
        home reads it, so the same string means a different file on dev and fails silently."""
        bad = GOOD_BRIEF.replace("Read `_common-rules.md`, in this brief's own directory.",
                                 "Read `~/quantivly/handoffs/rabota/_common-rules.md`.")
        with self.assertRaises(errors.Usage):
            brief.validate(self.tmpfile(bad))

    def test_an_absolute_path_outside_the_common_rules_section_is_allowed(self):
        """The negative control. `## Outputs` legitimately carries an absolute `out_dir:` — a
        rendered evaluate brief always does — so a check that scanned the whole brief would refuse
        every real dispatch while looking like a working guard."""
        self.assertIn("out_dir: /tmp/lane-out", GOOD_BRIEF)
        self.assertEqual(brief.validate(self.tmpfile(GOOD_BRIEF))["out_dir"], "/tmp/lane-out")

    def test_both_shipped_briefs_name_the_rules_the_way_they_actually_arrive(self):
        """smoke.md is shipped verbatim and evaluate.md.tmpl is rendered, so each is checked in
        the form the lane actually receives. The needle is `brief.RULES.name`, never a literal:
        renaming the shipped file without editing the briefs must break this row."""
        smoke = Path(__file__).resolve().parents[1] / "briefs" / "smoke.md"
        rendered = brief.render_evaluate({"id": "l1", "brief": "/o/l1/brief.md"},
                                         Path("/o/l1/verdict.json"), Path("/o/l1-eval"))
        for name, text in (("smoke.md", smoke.read_text()), ("evaluate.md.tmpl", rendered)):
            with self.subTest(brief=name):
                brief.validate_text(text, where=name)   # raises on an absolute path
                rules = "\n".join(brief._section(text.splitlines(), "## Common rules"))
                self.assertIn(brief.RULES.name, rules,
                              f"{name} must name {brief.RULES.name}, which run_recipe ships beside it")

    def test_a_lane_is_told_to_stop_when_the_rules_did_not_arrive(self):
        """The lane-side half of "say so loudly". The substrate refuses to dispatch a brief whose
        rules cannot reach it; this is what the lane does if they go missing anyway."""
        smoke = Path(__file__).resolve().parents[1] / "briefs" / "smoke.md"
        rules = " ".join(brief._section(smoke.read_text().splitlines(), "## Common rules"))
        self.assertIn("stop", rules.lower())
        self.assertIn("failed", rules)
