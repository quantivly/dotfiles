"""SQLite state. Human prose stays in YYYY-MM-DD/*.md; structure lives here."""
import json
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

from rabota import errors

SCHEMA_VERSION = 1
SCHEMA = """
CREATE TABLE IF NOT EXISTS schema_version(version INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS runs(id INTEGER PRIMARY KEY, tenant TEXT, started_at TEXT, mode TEXT,
  preflight_ok INTEGER, notes TEXT, finished_at TEXT);
CREATE TABLE IF NOT EXISTS source_syncs(tenant TEXT, source TEXT, fetched_at TEXT, ok INTEGER,
  error TEXT, path TEXT, PRIMARY KEY(tenant, source));
CREATE TABLE IF NOT EXISTS lanes(id TEXT PRIMARY KEY, tenant TEXT, kind TEXT, brief TEXT, repo TEXT,
  worktree TEXT, out_dir TEXT, machine TEXT, unit TEXT, session_id TEXT, model TEXT, status TEXT,
  started_at TEXT, ended_at TEXT, held_reason TEXT, of_lane TEXT, attached INTEGER DEFAULT 0);
CREATE TABLE IF NOT EXISTS escalations(id INTEGER PRIMARY KEY, tenant TEXT, first_seen TEXT NOT NULL,
  ts TEXT, question TEXT, evidence TEXT, options TEXT, disposition TEXT, resolved_at TEXT, resolution TEXT);
CREATE TABLE IF NOT EXISTS gate_answers(id INTEGER PRIMARY KEY, tenant TEXT, ts TEXT, subject TEXT, label TEXT);
CREATE TABLE IF NOT EXISTS inbox_decisions(batch_id TEXT, tenant TEXT, ts TEXT, tier TEXT, bucket TEXT,
  entity_type TEXT, entity_id TEXT, action TEXT, prior TEXT, verified INTEGER DEFAULT 0, rolled_back_at TEXT);
CREATE TABLE IF NOT EXISTS pins(tenant TEXT, item_key TEXT, bucket INTEGER, rationale TEXT, ts TEXT,
  PRIMARY KEY(tenant, item_key));
"""
LANE_FIELDS = ("id", "tenant", "kind", "brief", "repo", "worktree", "out_dir", "machine", "unit",
               "session_id", "model", "status", "started_at", "ended_at", "held_reason", "of_lane", "attached")


def now() -> str:
    """Current UTC time as ISO-8601 seconds with a ``Z`` suffix."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class Store:
    """Thin wrapper over ``<state_dir>/rabota.db``; every method is one autocommitted statement."""

    def __init__(self, conn: sqlite3.Connection):
        self.conn = conn
        self.conn.row_factory = sqlite3.Row

    @classmethod
    def open(cls, state_dir: Path) -> "Store":
        """Create ``state_dir`` and ``rabota.db`` if needed, migrate, and return an open store.

        An unusable ``state_dir`` is a ``RabotaError`` naming it (exit 5), not a traceback.
        """
        state_dir = Path(state_dir)
        try:
            state_dir.mkdir(parents=True, exist_ok=True)
            conn = sqlite3.connect(state_dir / "rabota.db", isolation_level=None)
        except (OSError, sqlite3.Error) as e:
            raise errors.RabotaError(f"cannot open state dir {state_dir}: {getattr(e, 'strerror', None) or e}") from None
        conn.execute("PRAGMA journal_mode=WAL"); conn.execute("PRAGMA busy_timeout=5000")
        s = cls(conn); s.migrate(); return s

    def close(self): self.conn.close()

    def migrate(self):
        """Apply the schema idempotently and stamp the version on first creation."""
        self.conn.executescript(SCHEMA)
        if self.conn.execute("SELECT COUNT(*) FROM schema_version").fetchone()[0] == 0:
            self.conn.execute("INSERT INTO schema_version VALUES (?)", (SCHEMA_VERSION,))

    def schema_version(self) -> int:
        return self.conn.execute("SELECT version FROM schema_version").fetchone()[0]

    def _rows(self, sql, args=()):
        return [dict(r) for r in self.conn.execute(sql, args).fetchall()]

    # runs / syncs
    def begin_run(self, tenant, mode) -> int:
        cur = self.conn.execute("INSERT INTO runs(tenant, started_at, mode) VALUES (?,?,?)", (tenant, now(), mode))
        return cur.lastrowid
    def finish_run(self, run_id, preflight_ok, notes=""):
        self.conn.execute("UPDATE runs SET preflight_ok=?, notes=?, finished_at=? WHERE id=?",
                          (int(preflight_ok), notes, now(), run_id))
    def record_sync(self, tenant, source, ok, error, path):
        self.conn.execute("INSERT OR REPLACE INTO source_syncs VALUES (?,?,?,?,?,?)",
                          (tenant, source, now(), int(ok), error, path))
    def last_sync(self, tenant, source):
        r = self._rows("SELECT * FROM source_syncs WHERE tenant=? AND source=?", (tenant, source))
        return r[0] if r else None

    # lanes
    def insert_lane(self, lane: dict):
        row = {k: lane.get(k) for k in LANE_FIELDS}
        row["attached"] = int(row["attached"] or 0)
        cols = ",".join(LANE_FIELDS); qs = ",".join("?" for _ in LANE_FIELDS)
        self.conn.execute(f"INSERT INTO lanes({cols}) VALUES ({qs})", tuple(row[k] for k in LANE_FIELDS))
    def update_lane(self, lane_id, **fields):
        """Update named lane columns; an unknown field name is a ``ValueError``, never a silent no-op."""
        bad = set(fields) - set(LANE_FIELDS)
        if bad: raise ValueError(f"unknown lane fields {bad}")
        sets = ",".join(f"{k}=?" for k in fields)
        self.conn.execute(f"UPDATE lanes SET {sets} WHERE id=?", (*fields.values(), lane_id))
    def get_lane(self, lane_id):
        r = self._rows("SELECT * FROM lanes WHERE id=?", (lane_id,)); return r[0] if r else None
    def list_lanes(self, tenant=None, status=None):
        sql, args = "SELECT * FROM lanes WHERE 1=1", []
        if tenant: sql += " AND tenant=?"; args.append(tenant)
        if status: sql += " AND status=?"; args.append(status)
        return self._rows(sql + " ORDER BY started_at", args)

    # escalations / gates
    def add_escalation(self, tenant, question, evidence, options, first_seen=None) -> int:
        """Insert an escalation; ``first_seen`` is preserved when given so re-raising never resets it."""
        ts = now()
        cur = self.conn.execute(
            "INSERT INTO escalations(tenant, first_seen, ts, question, evidence, options) VALUES (?,?,?,?,?,?)",
            (tenant, first_seen or ts, ts, question, evidence, json.dumps(list(options))))
        return cur.lastrowid
    def escalation(self, esc_id):
        r = self._rows("SELECT * FROM escalations WHERE id=?", (esc_id,))
        if not r: return None
        r[0]["options"] = json.loads(r[0]["options"] or "[]"); return r[0]
    def open_escalations(self, tenant):
        rows = self._rows("SELECT * FROM escalations WHERE tenant=? AND resolved_at IS NULL ORDER BY first_seen", (tenant,))
        for r in rows: r["options"] = json.loads(r["options"] or "[]")
        return rows
    def answer_escalation(self, esc_id, label, resolution=None):
        self.conn.execute("UPDATE escalations SET disposition=?, resolved_at=?, resolution=? WHERE id=?",
                          (label, now(), resolution, esc_id))
    def record_gate(self, tenant, subject, label):
        """Record a gate answer as a label only — never who answered (Rule 0)."""
        self.conn.execute("INSERT INTO gate_answers(tenant, ts, subject, label) VALUES (?,?,?,?)",
                          (tenant, now(), subject, label))
    def gates(self, tenant):
        return self._rows("SELECT * FROM gate_answers WHERE tenant=? ORDER BY ts", (tenant,))

    # inbox decisions
    def record_decision(self, batch_id, tenant, tier, bucket, entity_type, entity_id, action, prior: dict):
        """Record one applied inbox action with the prior values needed to roll it back."""
        self.conn.execute("INSERT INTO inbox_decisions VALUES (?,?,?,?,?,?,?,?,?,0,NULL)",
                          (batch_id, tenant, now(), tier, bucket, entity_type, entity_id, action, json.dumps(prior)))
    def decisions(self, batch_id):
        rows = self._rows("SELECT * FROM inbox_decisions WHERE batch_id=? ORDER BY ts", (batch_id,))
        for r in rows: r["prior"] = json.loads(r["prior"] or "{}")
        return rows
    def mark_verified(self, batch_id, entity_id):
        self.conn.execute("UPDATE inbox_decisions SET verified=1 WHERE batch_id=? AND entity_id=?", (batch_id, entity_id))
    def mark_rolled_back(self, batch_id):
        self.conn.execute("UPDATE inbox_decisions SET rolled_back_at=? WHERE batch_id=?", (now(), batch_id))

    # pins
    def set_pin(self, tenant, item_key, bucket, rationale):
        self.conn.execute("INSERT OR REPLACE INTO pins VALUES (?,?,?,?,?)", (tenant, item_key, bucket, rationale, now()))
    def pins(self, tenant):
        return self._rows("SELECT * FROM pins WHERE tenant=? ORDER BY bucket, ts", (tenant,))
    def clear_pin(self, tenant, item_key):
        self.conn.execute("DELETE FROM pins WHERE tenant=? AND item_key=?", (tenant, item_key))
