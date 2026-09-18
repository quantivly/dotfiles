"""Task 5.3 Step 1c (design §9.12): the reconcile golden set parses and is well-formed.

A shell check bolted onto scripts/test-rabota.sh would run on every -k <subset> invocation
and could be neither selected nor skipped (test-rabota.sh passes "$@" straight through to
python3 -m unittest); a unittest is picked up by CI's three legs exactly like everything
else. Recorded as a deviation from §3.3's literal "add to scripts/test-rabota.sh a check".

This test does NOT grade the classification (design §9.12's evaluate lane does that,
blind, against a human-set bar); it only asserts the fixture is a faithful, parseable,
well-formed extraction.
"""
import json
import unittest
from pathlib import Path

GOLDEN = Path(__file__).parent / "fixtures" / "reconcile" / "golden.json"
SIX_CLASSES = {"promised-untracked", "tracked-satisfied", "spoken-already-done",
               "question-owed", "state-contradiction", "stale-blocked"}
ENTRY_KEYS = {"id", "source", "text", "class", "outcome", "evidence"}


class ReconcileGoldenTests(unittest.TestCase):
    def setUp(self):
        self.data = json.loads(GOLDEN.read_text())

    def test_parses_and_has_at_least_ten_entries(self):
        self.assertIn("entries", self.data)
        self.assertGreaterEqual(len(self.data["entries"]), 10)

    def test_every_class_is_one_of_the_six(self):
        for e in self.data["entries"]:
            self.assertIn(e["class"], SIX_CLASSES, e)

    def test_every_entry_has_all_six_keys_non_empty(self):
        for e in self.data["entries"]:
            self.assertEqual(set(e.keys()), ENTRY_KEYS, e)
            for k in ENTRY_KEYS:
                self.assertTrue(str(e[k]).strip(), (e["id"], k))

    def test_ids_are_unique(self):
        ids = [e["id"] for e in self.data["entries"]]
        self.assertEqual(len(ids), len(set(ids)), ids)

    def test_missing_classes_if_present_names_only_the_six(self):
        missing = self.data.get("missing_classes", [])
        for name in missing:
            self.assertIn(name, SIX_CLASSES, name)

    def test_classes_field_is_self_describing(self):
        self.assertEqual(set(self.data.get("classes", [])), SIX_CLASSES)
