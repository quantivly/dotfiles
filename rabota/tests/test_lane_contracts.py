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

    def test_verdict_ok_and_oversize(self):
        v = {"lane": "l1", "status": "done", "claims": [{"id": "c1", "text": "t", "evidence": {"cmd": "true", "expected": "", "observed": ""}, "confidence": "high"}],
             "deliverables": [], "followups": []}
        p = self.tmpfile(json.dumps(v))
        self.assertEqual(verdict.validate(p, 4096)["lane"], "l1")
        with self.assertRaises(verdict.VerdictError) as cm:
            verdict.validate(p, 10)
        self.assertIn("bytes", str(cm.exception))

    def test_verdict_bad_shape(self):
        with self.assertRaises(verdict.VerdictError):
            verdict.validate(self.tmpfile('{"lane": "l1", "status": "maybe", "claims": [], "deliverables": [], "followups": []}'), 4096)
        with self.assertRaises(verdict.VerdictError):
            verdict.validate(Path("/nonexistent/verdict.json"), 4096)

    def test_render_evaluate_names_lane_and_paths(self):
        text = brief.render_evaluate({"id": "smoke", "brief": "/b/smoke.md"}, Path("/o/smoke/verdict.json"), Path("/o/smoke-eval"))
        self.assertIn("/o/smoke/verdict.json", text); self.assertIn("out_dir: /o/smoke-eval", text)
        brief.validate(self.tmpfile(text))   # the evaluate brief is itself a valid brief
