import json, tempfile, unittest
from pathlib import Path
from rabota import errors
from rabota.lanes import brief, verdict

GOOD_BRIEF = """# Smoke: prove the lane substrate
## Common rules
Read /home/zvi/quantivly/handoffs/rabota/_common-rules.md.
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
