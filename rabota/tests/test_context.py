import sqlite3, tempfile, unittest
from pathlib import Path
from rabota.context import Context


def _closed(conn):
    """True when ``conn`` refuses work: sqlite3 raises ProgrammingError on a closed connection."""
    try:
        conn.execute("SELECT 1")
    except sqlite3.ProgrammingError:
        return True
    return False


class ContextLifecycleTests(unittest.TestCase):
    """A Context owns at most one store connection and closes it exactly once."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        self.state_dir = Path(tmp.name) / "state"

    def make_ctx(self):
        # Only ``state_dir`` matters to the store; the collaborators are irrelevant here.
        return Context(cfg=None, tenant=None, state_dir=self.state_dir, runner=None, env={}, dry_run=False)

    def test_close_closes_the_store_connection(self):
        ctx = self.make_ctx()
        conn = ctx.store.conn
        self.assertFalse(_closed(conn))
        ctx.close()
        self.assertTrue(_closed(conn))

    def test_close_is_idempotent(self):
        ctx = self.make_ctx()
        ctx.store   # open it
        ctx.close(); ctx.close()   # the second call must not raise

    def test_close_without_ever_opening_the_store_is_safe(self):
        ctx = self.make_ctx()
        ctx.close()
        self.assertFalse((self.state_dir / "rabota.db").exists())   # closing did not open one

    def test_context_manager_closes_on_exit(self):
        with self.make_ctx() as ctx:
            conn = ctx.store.conn
            self.assertFalse(_closed(conn))
        self.assertTrue(_closed(conn))

    def test_context_manager_closes_when_the_body_raises(self):
        with self.assertRaises(RuntimeError):
            with self.make_ctx() as ctx:
                conn = ctx.store.conn
                raise RuntimeError("body failed")
        self.assertTrue(_closed(conn))


if __name__ == "__main__":
    unittest.main()
