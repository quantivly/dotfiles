import tempfile, unittest
from pathlib import Path
from rabota import context
from rabota.context import Context, track_contexts
from tests.support import connection_is_closed as _closed


class _ContextTestCase(unittest.TestCase):
    """A fresh state dir per test and a Context builder; no tests of its own."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        self.state_dir = Path(tmp.name) / "state"

    def make_ctx(self):
        # Only ``state_dir`` matters to the store; the collaborators are irrelevant here.
        return Context(cfg=None, tenant=None, state_dir=self.state_dir, runner=None, env={}, dry_run=False)


class ContextLifecycleTests(_ContextTestCase):
    """A Context owns at most one store connection and closes it exactly once."""

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


class TrackContextsTests(_ContextTestCase):
    """Collectors nest, and leaving one must drop exactly that collector — by identity.

    Two empty lists compare equal, so a collector dropped with ``list.remove`` can take the
    OUTER list with it: the next Context then lands in the already-exited inner list, which
    nobody will close, and the outer exit raises ``ValueError`` on top of it.
    """

    def test_nested_collectors_with_an_empty_inner_one_exit_cleanly_and_lose_no_context(self):
        depth = len(context._collectors)
        with track_contexts() as outer:
            with track_contexts() as inner:
                pass                        # nothing built inside: ``inner`` stays == []
            ctx = self.make_ctx()           # must land in ``outer``, the list its owner will close
            conn = ctx.store.conn
            self.assertEqual(inner, [])
            self.assertIs(outer[-1], ctx)
        # Reaching here means the outer exit did not raise ValueError.
        self.assertEqual(len(context._collectors), depth)   # both collectors gone, nothing else
        for c in outer:
            c.close()
        self.assertTrue(_closed(conn))

    def test_a_context_built_inside_the_inner_collector_is_the_inner_ones(self):
        with track_contexts() as outer:
            with track_contexts() as inner:
                ctx = self.make_ctx()
            self.assertEqual((inner, outer), ([ctx], []))
        ctx.close()


if __name__ == "__main__":
    unittest.main()
