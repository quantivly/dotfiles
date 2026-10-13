"""SQLite state. Human prose stays in YYYY-MM-DD/*.md; structure lives here."""
import contextlib
import json
import os
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

from rabota import errors, secrets

SCHEMA_VERSION = 5
# One spelling, used by both the v4 → v5 step and the fresh-database SCHEMA below, so the two can
# never describe different tables. Field meanings: design §3 and ``commands/schedule.py``.
SCHEDULES_DDL = """CREATE TABLE IF NOT EXISTS schedules(id TEXT PRIMARY KEY, tenant TEXT NOT NULL,
  kind TEXT NOT NULL, title TEXT NOT NULL, cwd TEXT NOT NULL, payload_source TEXT, payload_path TEXT NOT NULL,
  payload_sha256 TEXT NOT NULL, args TEXT, not_before TEXT NOT NULL, expires_at TEXT NOT NULL,
  seat TEXT, model TEXT, effort TEXT, est_minutes INTEGER, allow TEXT, read TEXT, record TEXT,
  ask TEXT, options TEXT, then_prompt_path TEXT, then_prompt_sha256 TEXT, then_on TEXT,
  timeout_s INTEGER NOT NULL, memory_max TEXT NOT NULL, max_budget_usd REAL, max_attempts INTEGER NOT NULL,
  status TEXT NOT NULL, attempt INTEGER NOT NULL DEFAULT 0, last_reason TEXT, unit TEXT, lane_id TEXT,
  out_dir TEXT, outcome TEXT, cost_usd REAL, escalation_id INTEGER, created_at TEXT NOT NULL,
  updated_at TEXT, started_at TEXT, ended_at TEXT, created_from_cwd TEXT, created_from_session TEXT)"""
# v(N) → v(N+1) steps, keyed by the version they upgrade FROM. Each list runs in one
# transaction and restamps. A fresh database gets the final shape from SCHEMA directly.
MIGRATIONS = {
    1: [  # v1 → v2 (design §4.3): lane accounting columns; escalation kind/subject
        "ALTER TABLE lanes ADD COLUMN seat TEXT", "ALTER TABLE lanes ADD COLUMN effort TEXT",
        "ALTER TABLE lanes ADD COLUMN cost_usd REAL", "ALTER TABLE lanes ADD COLUMN five_h_pct_at_start INTEGER",
        "ALTER TABLE lanes ADD COLUMN five_h_pct_at_end INTEGER", "ALTER TABLE lanes ADD COLUMN abandoned_at TEXT",
        "ALTER TABLE escalations ADD COLUMN kind TEXT", "ALTER TABLE escalations ADD COLUMN subject TEXT",
    ],
    2: [  # v2 → v3 (DO-747): why a lane settled the way it did, when that isn't self-evident from
          # status/cost_usd alone -- namely a lane census settled `failed` for writing no known
          # output file at all, distinct from an agent-reported failure.
        "ALTER TABLE lanes ADD COLUMN settle_reason TEXT",
    ],
    3: [  # v3 → v4 (DO-728 fix round): a lane's own requested runtime, persisted at start time, so
          # the budget gate can later project a STILL-RUNNING lane's remaining burn instead of
          # treating it as invisible. A row written before this migration has no value here; the
          # gate falls back to the seat's own median lane duration for those (budget.py).
        "ALTER TABLE lanes ADD COLUMN est_minutes INTEGER",
    ],
    4: [  # v4 → v5 (DO-816): the `schedules` table, scheduled-runs design §3. Purely additive: no
          # existing table or row is touched, so the one thing this step changes for an older
          # rabota is that it now refuses the store -- which is intended, since a queue it cannot
          # see is a queue it cannot list, cancel or report on.
        SCHEDULES_DDL,
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
  abandoned_at TEXT, settle_reason TEXT, est_minutes INTEGER);
CREATE TABLE IF NOT EXISTS escalations(id INTEGER PRIMARY KEY, tenant TEXT, first_seen TEXT NOT NULL,
  ts TEXT, question TEXT, evidence TEXT, options TEXT, disposition TEXT, resolved_at TEXT, resolution TEXT,
  kind TEXT, subject TEXT);
CREATE TABLE IF NOT EXISTS gate_answers(id INTEGER PRIMARY KEY, tenant TEXT, ts TEXT, subject TEXT, label TEXT);
CREATE TABLE IF NOT EXISTS inbox_decisions(batch_id TEXT, tenant TEXT, ts TEXT, tier TEXT, bucket TEXT,
  entity_type TEXT, entity_id TEXT, action TEXT, prior TEXT, verified INTEGER DEFAULT 0, rolled_back_at TEXT);
CREATE TABLE IF NOT EXISTS pins(tenant TEXT, item_key TEXT, bucket INTEGER, rationale TEXT, ts TEXT,
  PRIMARY KEY(tenant, item_key));
CREATE TABLE IF NOT EXISTS pins_meta(tenant TEXT PRIMARY KEY, version INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS fireflies_freeze_faults(tenant TEXT PRIMARY KEY, fails INTEGER NOT NULL,
  last_error TEXT, last_failed_at TEXT);
""" + SCHEDULES_DDL + ";\n"
# `fireflies_freeze_faults` (DO-768) reaches a pre-existing v4 store through the trailing
# `executescript(SCHEMA)` at the end of `migrate()`, not a migration step -- `SCHEMA_VERSION` stayed 4
# for it, a table add with no column on an existing table and nothing for old rows to backfill. See
# `test_migrate_adds_fireflies_freeze_faults_to_a_pre_do768_v4_store`. `schedules` (DO-816) is the
# same shape and DID bump, to 5, through `MIGRATIONS[4]`: the design asks for the stamp, because an
# older rabota must refuse a store holding a queue it cannot see rather than run beside it blind.
# The trailing `executescript(SCHEMA)` would create it on a v4 store anyway; the step is the stamp.
LANE_FIELDS = ("id", "tenant", "kind", "brief", "repo", "worktree", "out_dir", "machine", "unit",
               "session_id", "model", "status", "started_at", "ended_at", "held_reason", "of_lane", "attached",
               "seat", "effort", "cost_usd", "five_h_pct_at_start", "five_h_pct_at_end", "abandoned_at",
               "settle_reason", "est_minutes")
SCHEDULE_FIELDS = ("id", "tenant", "kind", "title", "cwd", "payload_source", "payload_path", "payload_sha256",
                   "args", "not_before", "expires_at", "seat", "model", "effort", "est_minutes", "allow", "read",
                   "record", "ask", "options", "then_prompt_path", "then_prompt_sha256", "then_on", "timeout_s",
                   "memory_max", "max_budget_usd", "max_attempts", "status", "attempt", "last_reason", "unit",
                   "lane_id", "out_dir", "outcome", "cost_usd", "escalation_id", "created_at", "updated_at",
                   "started_at", "ended_at", "created_from_cwd", "created_from_session")
# Stored as JSON text, decoded on the way out, so no caller ever sees half of the encoding.
SCHEDULE_JSON_FIELDS = ("args", "allow", "read", "options")


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

    @classmethod
    def open_current(cls, state_dir: Path) -> "Store":
        """Open an EXISTING store that is already at ``SCHEMA_VERSION``: never create one, never migrate.

        For a reader of ANOTHER tenant's store (the schedule export, DO-817), which must not be the
        thing that creates its file or moves its schema. A store at any other version is refused,
        naming it; ``open`` is how a command for that tenant migrates it.
        """
        db = Path(state_dir) / "rabota.db"
        if not db.is_file():
            raise errors.RabotaError(f"no store at {db}")
        conn = sqlite3.connect(f"{db.resolve().as_uri()}?mode=rw", uri=True, isolation_level=None)
        try:
            conn.execute("PRAGMA busy_timeout=5000")
            row = conn.execute("SELECT version FROM schema_version").fetchone()
            if row is None or row[0] != SCHEMA_VERSION:
                raise errors.Refused(f"{db} is at schema {row[0] if row else 'none'}, not this rabota's "
                                     f"{SCHEMA_VERSION}; any rabota command for that tenant migrates it")
        except BaseException:
            with contextlib.suppress(sqlite3.Error):
                conn.close()
            raise
        return cls(conn)

    def close(self): self.conn.close()

    @contextlib.contextmanager
    def transaction(self, immediate: bool = False):
        """Run the enclosed writes atomically: one ``COMMIT`` on success, ``ROLLBACK`` and re-raise on failure.

        ``isolation_level=None`` means every ``_exec`` call is otherwise its own autocommitted
        statement; this is the one place multiple writes are made all-or-nothing (import-v1, F2:
        a damaged row used to leave the rows before it committed). ``immediate`` takes the write
        lock at ``BEGIN`` rather than at the first write. The schedule tick's claim uses it because
        the design asks for it (§4), but what makes that claim single is its one conditional
        ``UPDATE``, which is atomic on its own; with no read inside the block, ``immediate`` changes
        no outcome there today (DO-817's mutation sweep declares that mutant equivalent).
        """
        self.conn.execute("BEGIN IMMEDIATE" if immediate else "BEGIN")
        try:
            yield
        except BaseException:
            self.conn.execute("ROLLBACK")
            raise
        else:
            self.conn.execute("COMMIT")

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

    # fireflies bootstrap-anchor freeze health (DO-768)
    def record_freeze_result(self, tenant, error):
        """Track consecutive Fireflies bootstrap-anchor freeze failures for ``tenant``.

        ``error`` ``None`` (the freeze succeeded, or there was nothing to freeze) resets the
        streak to zero -- a fresh problem, not this one, must build its own count from scratch.
        A message extends the streak by one. ``reconcile.snapshot_health`` is the only reader, and
        only alerts once the streak reaches ``snapshots.FIREFLIES_FREEZE_ALERT_AFTER`` -- keeping
        the count here rather than only the latest result is what lets that decision be made
        without re-deriving "is this the second time in a row" from anything else.
        """
        if error is None:
            self._exec("DELETE FROM fireflies_freeze_faults WHERE tenant=?", (tenant,))
            return
        row = self._rows("SELECT fails FROM fireflies_freeze_faults WHERE tenant=?", (tenant,))
        fails = (row[0]["fails"] if row else 0) + 1
        self._exec("INSERT OR REPLACE INTO fireflies_freeze_faults VALUES (?,?,?,?)",
                          (tenant, fails, error, now()))
    def freeze_fault(self, tenant):
        """The current streak for ``tenant`` -- ``{"tenant", "fails", "last_error", "last_failed_at"}``
        -- or ``None`` when the last attempt (if any) succeeded."""
        r = self._rows("SELECT * FROM fireflies_freeze_faults WHERE tenant=?", (tenant,))
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
    def lanes_for_rate(self, tenant, seat, limit=30):
        """Recent settled lanes on ``seat`` with the columns a burn-rate sample needs, newest first.

        Read-only, for the budget gate's measured rate (DO-728). A row missing any of
        ``started_at``/``ended_at``/``five_h_pct_at_start``/``five_h_pct_at_end`` is not a lane
        the rate can be measured from (a ``started`` or ``abandoned`` row never gets these), and a
        non-empty ``settle_reason`` (DO-747) means ``ended_at`` is a ``now()`` fallback rather than
        the lane's real finish time — both are excluded here so ``budget.py`` never has to re-derive
        "was this row usable" from timestamps alone.
        """
        return self._rows(
            "SELECT * FROM lanes WHERE tenant=? AND seat=? AND started_at IS NOT NULL "
            "AND ended_at IS NOT NULL AND five_h_pct_at_start IS NOT NULL AND five_h_pct_at_end IS NOT NULL "
            "AND (settle_reason IS NULL OR settle_reason='') ORDER BY started_at DESC LIMIT ?",
            (tenant, seat, limit))

    # schedules (DO-816, scheduled-runs design §3)
    def insert_schedule(self, row: dict):
        """Insert one schedule row; JSON-shaped fields are encoded here, never by the caller."""
        vals = {k: row.get(k) for k in SCHEDULE_FIELDS}
        vals["attempt"] = int(vals["attempt"] or 0)    # an explicit NULL would bypass the column default
        for k in SCHEDULE_JSON_FIELDS:
            vals[k] = None if vals[k] is None else json.dumps(vals[k])
        cols = ",".join(SCHEDULE_FIELDS); qs = ",".join("?" for _ in SCHEDULE_FIELDS)
        self._exec(f"INSERT INTO schedules({cols}) VALUES ({qs})", tuple(vals[k] for k in SCHEDULE_FIELDS))
    def update_schedule(self, sched_id, **fields):
        """Update named schedule columns and ``updated_at``; an unknown field is a ``ValueError``."""
        self.update_schedule_where(sched_id, {}, **fields)
    def cancel_schedule(self, sched_id, stamp, reason) -> bool:
        """Cancel ``sched_id`` only if it is STILL pending, in one statement; False when it was not.

        Read-then-write would race the tick: a row it claimed between the two would be stamped
        cancelled while its unit runs on.
        """
        cur = self._exec("UPDATE schedules SET status='cancelled', ended_at=?, updated_at=?, last_reason=? "
                         "WHERE id=? AND status='pending'", (stamp, stamp, reason, sched_id))
        return cur.rowcount == 1
    def update_schedule_where(self, sched_id, where: dict, **fields) -> bool:
        """``update_schedule``, but only while every column in ``where`` still holds its value; False if not.

        One statement, so nothing can change the row between the check and the write (DO-817: the
        tick settles a run only while it is still ``running`` under the unit it is settling).
        """
        bad = (set(fields) | set(where)) - set(SCHEDULE_FIELDS)
        if bad: raise ValueError(f"unknown schedule fields {bad}")
        fields = {k: (json.dumps(v) if k in SCHEDULE_JSON_FIELDS and v is not None else v) for k, v in fields.items()}
        fields.setdefault("updated_at", now())
        sets = ",".join(f"{k}=?" for k in fields)
        conds = "".join(f" AND {k} IS ?" for k in where)
        cur = self._exec(f"UPDATE schedules SET {sets} WHERE id=?{conds}", (*fields.values(), sched_id, *where.values()))
        return cur.rowcount == 1
    def _decode_schedule(self, r):
        for k in SCHEDULE_JSON_FIELDS:
            r[k] = json.loads(r[k]) if r[k] is not None else None
        return r
    def get_schedule(self, sched_id):
        r = self._rows("SELECT * FROM schedules WHERE id=?", (sched_id,))
        return self._decode_schedule(r[0]) if r else None
    def list_schedules(self, tenant=None, status=None):
        sql, args = "SELECT * FROM schedules WHERE 1=1", []
        if tenant: sql += " AND tenant=?"; args.append(tenant)
        if status: sql += " AND status=?"; args.append(status)
        return [self._decode_schedule(r) for r in self._rows(sql + " ORDER BY not_before, id", args)]

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
        return self.escalations(tenant, open_only=True)
    def find_escalation(self, tenant, kind, subject, evidence):
        """The oldest escalation with exactly this ``kind``, ``subject`` and ``evidence``, or None.

        The schedule tick's idempotence key (DO-817): it raises an escalation BEFORE the row write
        that records it, so a crash between the two is found here on the next tick and adopted,
        rather than raised (and notified) a second time.
        """
        r = self._rows("SELECT id FROM escalations WHERE tenant=? AND kind=? AND subject=? AND evidence=? "
                       "ORDER BY id LIMIT 1", (tenant, kind, subject, evidence))
        return self.escalation(r[0]["id"]) if r else None
    def escalations(self, tenant, open_only=False):
        """Every escalation for ``tenant``, oldest first; ``open_only`` keeps the unresolved ones.

        Free text is redacted AGAIN on the way out (DO-815), with THIS process's environment:
        ``_exec`` redacted it with the writer's, and a lane that escalated may not have held a value
        the reader holds. Every reader prints through a guard that would otherwise refuse the whole
        output, so one such escalation would take down ``brief`` -- the very screen meant to show it.
        """
        where = " AND resolved_at IS NULL" if open_only else ""
        rows = self._rows(f"SELECT * FROM escalations WHERE tenant=?{where} ORDER BY first_seen, id", (tenant,))
        for r in rows:
            for k in ("question", "evidence", "subject", "resolution", "disposition"):
                if isinstance(r[k], str):
                    r[k] = secrets.redact(r[k], os.environ)
            r["options"] = [secrets.redact(o, os.environ) for o in json.loads(r["options"] or "[]")]
        return rows
    def answer_escalation(self, esc_id, label, resolution=None):
        self._exec("UPDATE escalations SET disposition=?, resolved_at=?, resolution=? WHERE id=?",
                          (label, now(), resolution, esc_id))
    def unresolve_escalation(self, esc_id):
        """Undo ``answer_escalation`` — used to roll an answer back when its jsonl projection fails."""
        self._exec("UPDATE escalations SET disposition=NULL, resolved_at=NULL, resolution=NULL WHERE id=?",
                          (esc_id,))
    def delete_escalation(self, esc_id):
        """Remove an escalation outright — used to roll back a create whose jsonl projection failed."""
        self._exec("DELETE FROM escalations WHERE id=?", (esc_id,))
    def escalations_by_identity(self, tenant):
        """Every escalation for ``tenant`` keyed by ``(first_seen, question)`` — import-v1's identity
        for a record. ``first_seen`` alone collides: v1 can log several distinct questions under one
        shared ``firstSeen``, so the pair is what is stable and unique across re-imports."""
        rows = self._rows("SELECT * FROM escalations WHERE tenant=?", (tenant,))
        return {(r["first_seen"], r["question"]): r for r in rows}
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
        self._bump_pins_version(tenant)
    def pins(self, tenant):
        return self._rows("SELECT * FROM pins WHERE tenant=? ORDER BY bucket, ts", (tenant,))
    def clear_pin(self, tenant, item_key):
        self._exec("DELETE FROM pins WHERE tenant=? AND item_key=?", (tenant, item_key))
        self._bump_pins_version(tenant)
    def _bump_pins_version(self, tenant):
        """Advance ``tenant``'s pins version by one, creating the row at 1 if this is its first pin write.

        A row's own ``ts`` (set on insert, untouched by delete) cannot stand in for "did the pins
        table change": a delete of any row but the max-``ts`` one leaves ``MAX(ts)`` unchanged, and a
        delete is exactly as much a change as a set (a lesson from this project — mtime/hash
        comparisons over a multi-writer file prove nothing; the same is true of a derived aggregate
        that a delete can leave untouched). This counter increments on both mutations, so any change
        — set or clear — is visible to a caller polling it, never just some of them.
        """
        self._exec("INSERT INTO pins_meta(tenant, version) VALUES (?, 1) "
                   "ON CONFLICT(tenant) DO UPDATE SET version = version + 1", (tenant,))
    def pins_version(self, tenant) -> int:
        """``tenant``'s pins version: 0 until the first ``set_pin``/``clear_pin``, then a strictly
        increasing counter bumped by both — the real signal ``rank``'s inputs are checked against."""
        rows = self._rows("SELECT version FROM pins_meta WHERE tenant=?", (tenant,))
        return rows[0]["version"] if rows else 0
