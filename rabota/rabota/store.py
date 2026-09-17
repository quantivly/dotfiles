"""SQLite state. Human prose stays in YYYY-MM-DD/*.md; structure lives here."""
import contextlib
import json
import os
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

from rabota import errors, secrets

SCHEMA_VERSION = 2
# v(N) → v(N+1) steps, keyed by the version they upgrade FROM. Each list runs in one
# transaction and restamps. A fresh database gets the final shape from SCHEMA directly.
MIGRATIONS = {
    1: [  # v1 → v2 (design §4.3): lane accounting columns; escalation kind/subject
        "ALTER TABLE lanes ADD COLUMN seat TEXT", "ALTER TABLE lanes ADD COLUMN effort TEXT",
        "ALTER TABLE lanes ADD COLUMN cost_usd REAL", "ALTER TABLE lanes ADD COLUMN five_h_pct_at_start INTEGER",
        "ALTER TABLE lanes ADD COLUMN five_h_pct_at_end INTEGER", "ALTER TABLE lanes ADD COLUMN abandoned_at TEXT",
        "ALTER TABLE escalations ADD COLUMN kind TEXT", "ALTER TABLE escalations ADD COLUMN subject TEXT",
    ],
}
SCHEMA = """
CREATE TABLE IF NOT EXISTS schema_version(version INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS runs(id INTEGER PRIMARY KEY, tenant TEXT, started_at TEXT, mode TEXT,
  preflight_ok INTEGER, notes TEXT, finished_at TEXT);
CREATE TABLE IF NOT EXISTS source_syncs(tenant TEXT, source TEXT, fetched_at TEXT, ok INTEGER,
  error TEXT, path TEXT, PRIMARY KEY(tenant, source));
CREATE TABLE IF NOT EXISTS lanes(id TEXT PRIMARY KEY, tenant TEXT, kind TEXT, brief TEXT, repo TEXT,
  worktree TEXT, out_dir TEXT, machine TEXT, unit TEXT, session_id TEXT, model TEXT, status TEXT,
  started_at TEXT, ended_at TEXT, held_reason TEXT, of_lane TEXT, attached INTEGER DEFAULT 0,
  seat TEXT, effort TEXT, cost_usd REAL, five_h_pct_at_start INTEGER, five_h_pct_at_end INTEGER,
  abandoned_at TEXT);
CREATE TABLE IF NOT EXISTS escalations(id INTEGER PRIMARY KEY, tenant TEXT, first_seen TEXT NOT NULL,
  ts TEXT, question TEXT, evidence TEXT, options TEXT, disposition TEXT, resolved_at TEXT, resolution TEXT,
  kind TEXT, subject TEXT);
CREATE TABLE IF NOT EXISTS gate_answers(id INTEGER PRIMARY KEY, tenant TEXT, ts TEXT, subject TEXT, label TEXT);
CREATE TABLE IF NOT EXISTS inbox_decisions(batch_id TEXT, tenant TEXT, ts TEXT, tier TEXT, bucket TEXT,
  entity_type TEXT, entity_id TEXT, action TEXT, prior TEXT, verified INTEGER DEFAULT 0, rolled_back_at TEXT);
CREATE TABLE IF NOT EXISTS pins(tenant TEXT, item_key TEXT, bucket INTEGER, rationale TEXT, ts TEXT,
  PRIMARY KEY(tenant, item_key));
"""
LANE_FIELDS = ("id", "tenant", "kind", "brief", "repo", "worktree", "out_dir", "machine", "unit",
               "session_id", "model", "status", "started_at", "ended_at", "held_reason", "of_lane", "attached",
               "seat", "effort", "cost_usd", "five_h_pct_at_start", "five_h_pct_at_end", "abandoned_at")


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
        # From here the connection exists and is ours until it is handed to the caller. Any
        # failure on the way — a PRAGMA, ``migrate()`` refusing a newer schema — must close it
        # before the exception leaves, or it is leaked (F17: two of these in the suite, on the
        # ``Refused`` path). The exception itself is part of the exit-code contract, so a close
        # that fails on the way out is suppressed rather than allowed to replace it.
        try:
            conn.execute("PRAGMA journal_mode=WAL"); conn.execute("PRAGMA busy_timeout=5000")
            store = cls(conn); store.migrate()
        except BaseException:
            with contextlib.suppress(sqlite3.Error):
                conn.close()
            raise
        return store

    def close(self): self.conn.close()

    def migrate(self):
        """Create the schema on a fresh DB; walk MIGRATIONS from the stamped version on an older one.

        A database stamped NEWER than ``SCHEMA_VERSION`` was written by a future rabota and is
        refused before anything is touched. Each migration step runs inside one transaction and
        restamps, so a crash mid-step leaves the old stamp and the old columns together. A stamp
        this code has NO step for (e.g. 0) is left exactly as it is — restamping would claim a
        migration had run — and ``doctor`` reports the drift.
        """
        has_version = self.conn.execute(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='schema_version'").fetchone()
        current = None
        if has_version:
            row = self.conn.execute("SELECT version FROM schema_version").fetchone()
            current = row[0] if row else None
            if current is not None and current > SCHEMA_VERSION:
                raise errors.Refused(f"rabota.db schema is {current}, newer than this rabota's {SCHEMA_VERSION}; "
                                     "upgrade rabota rather than letting an older one write to it")
        if current is None:
            self.conn.executescript(SCHEMA)
            if self.conn.execute("SELECT COUNT(*) FROM schema_version").fetchone()[0] == 0:
                self.conn.execute("INSERT INTO schema_version VALUES (?)", (SCHEMA_VERSION,))
            return
        while current < SCHEMA_VERSION and current in MIGRATIONS:
            self.conn.execute("BEGIN")
            try:
                for stmt in MIGRATIONS[current]:
                    self.conn.execute(stmt)
                self.conn.execute("UPDATE schema_version SET version=?", (current + 1,))
                self.conn.execute("COMMIT")
            except sqlite3.Error:
                self.conn.execute("ROLLBACK")
                raise
            current += 1
        self.conn.executescript(SCHEMA)   # idempotent CREATE IF NOT EXISTS for any table added later

    def schema_version(self) -> int:
        return self.conn.execute("SELECT version FROM schema_version").fetchone()[0]

    def _rows(self, sql, args=()):
        return [dict(r) for r in self.conn.execute(sql, args).fetchall()]

    def _exec(self, sql, args=()):
        """Every INSERT/UPDATE runs through here: a protected value in any text parameter is redacted first.

        ``rabota.db`` is a file, and a token in it outlives the process that wrote it (k2, the store
        route: gh's stderr echoed the minted token into ``source_syncs.error``). The row is kept and
        the value replaced — see ``secrets.redact`` for why not refuse.
        """
        return self.conn.execute(sql, tuple(secrets.redact(a, os.environ) if isinstance(a, str) else a for a in args))

    # runs / syncs
    def begin_run(self, tenant, mode) -> int:
        cur = self._exec("INSERT INTO runs(tenant, started_at, mode) VALUES (?,?,?)", (tenant, now(), mode))
        return cur.lastrowid
    def finish_run(self, run_id, preflight_ok, notes=""):
        self._exec("UPDATE runs SET preflight_ok=?, notes=?, finished_at=? WHERE id=?",
                          (int(preflight_ok), notes, now(), run_id))
    def record_sync(self, tenant, source, ok, error, path):
        self._exec("INSERT OR REPLACE INTO source_syncs VALUES (?,?,?,?,?,?)",
                          (tenant, source, now(), int(ok), error, path))
    def last_sync(self, tenant, source):
        r = self._rows("SELECT * FROM source_syncs WHERE tenant=? AND source=?", (tenant, source))
        return r[0] if r else None

    # lanes
    def insert_lane(self, lane: dict):
        row = {k: lane.get(k) for k in LANE_FIELDS}
        row["attached"] = int(row["attached"] or 0)
        cols = ",".join(LANE_FIELDS); qs = ",".join("?" for _ in LANE_FIELDS)
        self._exec(f"INSERT INTO lanes({cols}) VALUES ({qs})", tuple(row[k] for k in LANE_FIELDS))
    def update_lane(self, lane_id, **fields):
        """Update named lane columns; an unknown field name is a ``ValueError``, never a silent no-op."""
        bad = set(fields) - set(LANE_FIELDS)
        if bad: raise ValueError(f"unknown lane fields {bad}")
        sets = ",".join(f"{k}=?" for k in fields)
        self._exec(f"UPDATE lanes SET {sets} WHERE id=?", (*fields.values(), lane_id))
    def get_lane(self, lane_id):
        r = self._rows("SELECT * FROM lanes WHERE id=?", (lane_id,)); return r[0] if r else None
    def list_lanes(self, tenant=None, status=None):
        sql, args = "SELECT * FROM lanes WHERE 1=1", []
        if tenant: sql += " AND tenant=?"; args.append(tenant)
        if status: sql += " AND status=?"; args.append(status)
        return self._rows(sql + " ORDER BY started_at", args)

    # escalations / gates
    def add_escalation(self, tenant, question, evidence, options, first_seen=None, kind=None, subject=None) -> int:
        """Insert an escalation; ``first_seen`` is preserved when given so re-raising never resets it.

        ``kind`` and ``subject`` (schema 2) are written from the first row — design §4.2 wants them
        present from the first write, never back-filled.
        """
        ts = now()
        cur = self._exec(
            "INSERT INTO escalations(tenant, first_seen, ts, question, evidence, options, kind, subject) "
            "VALUES (?,?,?,?,?,?,?,?)",
            (tenant, first_seen or ts, ts, question, evidence, json.dumps(list(options)), kind, subject))
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
        self._exec("UPDATE escalations SET disposition=?, resolved_at=?, resolution=? WHERE id=?",
                          (label, now(), resolution, esc_id))
    def record_gate(self, tenant, subject, label):
        """Record a gate answer as a label only — never who answered (Rule 0)."""
        self._exec("INSERT INTO gate_answers(tenant, ts, subject, label) VALUES (?,?,?,?)",
                          (tenant, now(), subject, label))
    def gates(self, tenant):
        return self._rows("SELECT * FROM gate_answers WHERE tenant=? ORDER BY ts", (tenant,))

    # inbox decisions
    def record_decision(self, batch_id, tenant, tier, bucket, entity_type, entity_id, action, prior: dict):
        """Record one applied inbox action with the prior values needed to roll it back."""
        self._exec("INSERT INTO inbox_decisions VALUES (?,?,?,?,?,?,?,?,?,0,NULL)",
                          (batch_id, tenant, now(), tier, bucket, entity_type, entity_id, action, json.dumps(prior)))
    def decisions(self, batch_id):
        rows = self._rows("SELECT * FROM inbox_decisions WHERE batch_id=? ORDER BY ts", (batch_id,))
        for r in rows: r["prior"] = json.loads(r["prior"] or "{}")
        return rows
    def mark_verified(self, batch_id, entity_id):
        self._exec("UPDATE inbox_decisions SET verified=1 WHERE batch_id=? AND entity_id=?", (batch_id, entity_id))
    def mark_rolled_back(self, batch_id):
        self._exec("UPDATE inbox_decisions SET rolled_back_at=? WHERE batch_id=?", (now(), batch_id))

    # pins
    def set_pin(self, tenant, item_key, bucket, rationale):
        self._exec("INSERT OR REPLACE INTO pins VALUES (?,?,?,?,?)", (tenant, item_key, bucket, rationale, now()))
    def pins(self, tenant):
        return self._rows("SELECT * FROM pins WHERE tenant=? ORDER BY bucket, ts", (tenant,))
    def clear_pin(self, tenant, item_key):
        self._exec("DELETE FROM pins WHERE tenant=? AND item_key=?", (tenant, item_key))
