import tempfile, unittest
from pathlib import Path
from unittest import mock
from rabota import emit, errors


class AppendFileTests(unittest.TestCase):
    def test_two_calls_produce_two_lines(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        path = Path(tmp.name) / "log.jsonl"
        emit.append_file(path, "one\n")
        emit.append_file(path, "two\n")
        self.assertEqual(path.read_text().splitlines(), ["one", "two"])

    def test_protected_value_raises_and_appends_nothing(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        path = Path(tmp.name) / "log.jsonl"
        secret = "lin_api_" + "canary" + "0123456789"
        with mock.patch.dict("os.environ", {"LINEAR_API_KEY": secret}):
            with self.assertRaises(errors.SecretLeak):
                emit.append_file(path, f"leaked: {secret}\n")
        self.assertFalse(path.exists())
