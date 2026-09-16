import os, unittest
from rabota.runner import Result, SubprocessRunner, FakeRunner

class RunnerTests(unittest.TestCase):
    def test_subprocess_runner_captures(self):
        r = SubprocessRunner(env={"PATH": os.environ["PATH"]})
        res = r.run(["sh", "-c", "echo hi; echo bad >&2; exit 3"])
        self.assertEqual((res.code, res.out.strip(), res.err.strip()), (3, "hi", "bad"))
        self.assertFalse(res.ok)

    def test_subprocess_runner_env_is_exactly_what_was_given(self):
        # HOME is always in the parent env; the child must not inherit it.
        r = SubprocessRunner(env={"PATH": os.environ["PATH"], "ONLY": "1"})
        res = r.run(["sh", "-c", "echo ${HOME:-unset} $ONLY"])
        self.assertEqual(res.out.strip(), "unset 1")

    def test_fake_runner_matches_prefix_and_records(self):
        f = FakeRunner([(["gh", "api", "user"], Result(0, '{"login":"zvi-quantivly"}', ""))])
        res = f.run(["gh", "api", "user", "--jq", ".login"])
        self.assertEqual(res.code, 0)
        self.assertEqual(f.calls, [["gh", "api", "user", "--jq", ".login"]])

    def test_fake_runner_unmatched_raises(self):
        f = FakeRunner([])
        with self.assertRaises(AssertionError):
            f.run(["herdr", "api", "snapshot"])
