"""Fireflies over its GraphQL API, fetched server-side by the timer like Linear (DO-746).

**Why server-side.** The ``claude.ai`` Fireflies connector needs a per-seat authorization grant
that can silently lapse (DO-744 research); a static per-user API key from Settings → Developer
settings (Personal tab) needs neither a consent screen nor an admin action, on every plan. So
Fireflies joins ``linear``/``github`` in ``sync.FETCHED_SOURCES`` instead of staying a
session-fetched connector.

**Parsing, not extraction.** ``docs.fireflies.ai`` types ``Summary.action_items`` as a plain
``String``. Driven live against real meetings (DO-744), it is markdown with structure::

    **Alex Russo**
    Verify alignment of calendar edit modal with existing design system and report findings (00:14)

    **Wesley Mendes**
    Continue testing on the staging environment ... (07:20)

with an ``**Unassigned**`` header for items Fireflies' own AI could not attribute to a speaker.
``parse_action_items`` turns that string into ``[{"speaker", "item", "timestamp"}, ...]`` — the
``(speaker, item, timestamp)`` shape the ``promised-untracked`` reconcile class wants (golden case
``g08``). That shape came from one lane's observation of a handful of meetings and is UNVERIFIED
beyond that, so the parser degrades rather than raises on anything that does not match it:

- ``None`` or an empty/whitespace-only string → ``[]`` (nothing to report, honestly).
- No ``**Name**`` header anywhere → every line becomes an item with ``speaker: None``, rather
  than guessing an attribution the text does not carry.
- A header followed immediately by another header (or by nothing) → that speaker contributes no
  items; the loop just never appends any line for them.
- A line with no trailing ``(MM:SS)``/``(HH:MM:SS)`` → ``timestamp: None``, item text kept as-is.
- A header spelled ``**Alex:**`` (trailing colon) → the colon is stripped from ``speaker``, not
  kept as part of the name.

No branch below raises: the four cases above already fall out of one loop with no special-casing,
which is the point — a shape observed in a handful of meetings should not be enforced as a schema.

**Known limitation, not fixed here (DO-746 fix round, finding F3).** A long action item that
wraps onto a second markdown line with no blank line between — the timestamp then trailing the
*second* line, not the first — is parsed as two separate items, and the first loses its
timestamp. Joining consecutive non-header lines would fix that case, but nothing in this string
distinguishes it from two genuinely separate one-line items with no timestamp of their own
(``test_item_with_no_timestamp_keeps_the_full_text_and_a_none_timestamp`` exists because that
case is real) — a join that guesses wrong silently merges two unrelated commitments into one,
which is worse than the current split. Left as a known limit and pinned by
``test_a_wrapped_two_line_item_is_a_known_pinned_limitation`` in ``tests/test_fireflies.py``
rather than guessed at.
"""
import json
import re
import urllib.error
import urllib.request
from datetime import datetime, timezone
from typing import Callable

from rabota import errors

ENDPOINT = "https://api.fireflies.ai/graphql"
TIMEOUT_SECONDS = 60

# A bare integer at or above this is read as epoch milliseconds; below it, as epoch seconds
# (DO-749 hazard 1). Real transcript dates are ~1.7e12 ms (2026) vs ~1.7e9 s -- this threshold
# stays unambiguous until epoch seconds themselves reach 1e12, i.e. the year 33658.
_EPOCH_MS_THRESHOLD = 10**12

PAGE_SIZE = 50
# Measured live 2026-09-28 (DO-772): a 90-day window and a 365-day window both returned exactly
# 50 transcripts with no `limit` given -- 50 is the server's silent default page size, so an
# explicit `limit: 50` matches the one page size the live API is confirmed to honor.
MAX_PAGES = 40
# At PAGE_SIZE transcripts per page that is 2000 transcripts -- at the measured live rate of
# ~0.8 meetings/day (DO-772), roughly 7 years of continuous meetings. A window that would page
# past this is refused (`errors.RabotaError`) rather than looped on forever or silently capped.

Q_TRANSCRIPTS = """query($fromDate: DateTime, $limit: Int, $skip: Int) {
  transcripts(fromDate: $fromDate, limit: $limit, skip: $skip) {
    id title date
    summary { action_items }
  }
}"""

_HEADER_RE = re.compile(r"^\*\*(.+?)\*\*$")
_TIMESTAMP_RE = re.compile(r"\((\d{1,2}:\d{2}(?::\d{2})?)\)\s*$")


def parse_action_items(text: str | None) -> list[dict]:
    """``[{"speaker", "item", "timestamp"}, ...]`` from a ``Summary.action_items`` string.

    See the module docstring for the shape this is driven from and how each malformed input
    degrades. ``speaker`` is ``None`` for an ``**Unassigned**`` header or for any line seen before
    the first header; ``timestamp`` is ``None`` when a line carries no trailing ``(MM:SS)``.
    """
    if not text or not text.strip():
        return []
    speaker = None
    items = []
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        header = _HEADER_RE.match(line)
        if header:
            name = header.group(1).strip()
            if name.endswith(":"):     # minor: **Alex:** must not leak the colon into the name
                name = name[:-1].strip()
            speaker = None if name == "Unassigned" else name
            continue
        match = _TIMESTAMP_RE.search(line)
        timestamp = match.group(1) if match else None
        item = line[:match.start()].rstrip() if match else line
        items.append({"speaker": speaker, "item": item, "timestamp": timestamp})
    return items


def _epoch_to_iso(n: int | float) -> str | None:
    """``n`` (epoch seconds or milliseconds, see ``_EPOCH_MS_THRESHOLD``) as ``...Z`` UTC, or
    ``None`` for a value ``datetime`` cannot represent."""
    seconds = n / 1000 if abs(n) >= _EPOCH_MS_THRESHOLD else n
    try:
        return datetime.fromtimestamp(seconds, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except (OverflowError, OSError, ValueError):
        return None


def normalize_date(value) -> str | None:
    """A Fireflies transcript's ``date`` as ``YYYY-MM-DDTHH:MM:SSZ`` UTC, or ``None`` (DO-749).

    Fireflies' docs type ``transcripts[].date`` as ``DateTime`` but a live read on 2026-09-25
    returned epoch milliseconds (see the module docstring) -- an int or a numeric string is
    read as an epoch (see ``_EPOCH_MS_THRESHOLD`` for seconds vs. milliseconds). An ISO string
    is accepted as given and reformatted to the same ``Z`` form. Anything else -- ``None``,
    an unparseable string, a value ``datetime`` cannot represent -- becomes ``None``, never the
    raw value, so a downstream reader never has to guess the shape of what it got.
    """
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, (int, float)):
        return _epoch_to_iso(value)
    if not isinstance(value, str):
        return None
    stripped = value.strip()
    if re.fullmatch(r"-?\d+", stripped):
        return _epoch_to_iso(int(stripped))
    try:
        dt = datetime.fromisoformat(stripped.replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _urllib_post(api_key: str) -> Callable[[dict], dict]:
    """Return a transport that POSTs a GraphQL body with ``api_key`` as a bearer token.

    Mirrors ``linear._urllib_post``: transport failures come back as a reply carrying ``errors``
    so ``query`` has one failure path, and the key is never part of the message.
    """
    def post(body: dict) -> dict:
        req = urllib.request.Request(ENDPOINT, data=json.dumps(body).encode(),
                                     headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT_SECONDS) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            return {"errors": [{"message": f"HTTP {e.code} from Fireflies (key or query)"}]}
        except urllib.error.URLError as e:
            return {"errors": [{"message": f"cannot reach Fireflies: {e.reason}"}]}
        except json.JSONDecodeError as e:
            return {"errors": [{"message": f"Fireflies reply is not JSON: {e.msg}"}]}
    return post


class FirefliesClient:
    """One Fireflies identity: a static per-user API key, and the one read ``sync`` needs."""

    def __init__(self, api_key: str, post: Callable[[dict], dict] | None = None):
        self._post = post or _urllib_post(api_key)

    @classmethod
    def from_context(cls, ctx) -> "FirefliesClient":
        """Read the key from the env var ``ctx.tenant.fireflies_key_env`` names, default
        ``FIREFLIES_API_KEY`` — chosen so this lands without @zvi editing his tenant file (hazard
        2); an override is still possible, for symmetry with ``linear_key_env``. Refuses, rather
        than fetching, when either the name or the value is missing — exactly ``linear.py``'s
        precedent, so a missing key is a recorded failed source, not a crash (hazard 1).
        """
        name = getattr(ctx.tenant, "fireflies_key_env", None) or "FIREFLIES_API_KEY"
        key = ctx.env.get(name)
        if not key:
            raise errors.Refused(f"tenant has no Fireflies key (env var {name})")
        return cls(key)

    def query(self, gql: str, variables: dict | None = None) -> dict:
        """POST one operation and return its ``data``; any ``errors`` in the reply is a ``RabotaError``."""
        reply = self._post({"query": gql, "variables": variables or {}})
        if "errors" in reply:
            msgs = "; ".join(str(e.get("message", "?")) for e in reply["errors"])
            raise errors.RabotaError(f"Fireflies query failed: {msgs}")
        if "data" not in reply:
            raise errors.RabotaError("Fireflies reply has neither data nor errors")
        return reply["data"]

    def recent_transcripts(self, since: datetime) -> list[dict]:
        """Transcripts since ``since``, each with ``action_items`` already parsed.

        Pages explicitly with ``limit``/``skip`` -- ``transcripts`` returns a plain list, not a
        ``pageInfo`` connection like Linear's queries, so this follows ``linear.py``'s spirit
        (ask for a bounded page, keep going while the server hands back more) rather than its
        cursor mechanics, which do not apply here. A page shorter than ``PAGE_SIZE`` is the only
        signal this API gives that there is no more to fetch; a page *longer* than ``PAGE_SIZE``
        means ``limit`` was not honored and the reply cannot be trusted, exactly
        ``linear.find_by_identifiers``'s precedent for a filter that silently did not apply.
        Paging past ``MAX_PAGES`` is refused rather than truncated silently -- see its comment
        for the bound.

        **Duplicates only, not gaps (DO-772 fix round).** ``transcripts`` gives no cursor, so each
        page is a fresh query at a fixed ``skip`` against whatever order the server holds *right
        now* -- if that order changes between two calls (a meeting's ``date`` corrected, a
        transcript finishing processing mid-run), an id can shift across the page boundary and
        come back twice. Every id already added is tracked, so a second occurrence is dropped
        rather than appended, keeping the first occurrence's position. An id that shifts the other
        way -- out of every page's window entirely -- cannot be told apart from an id that was
        simply never in range: nothing in a reply says how many ids exist or which ones a stable
        server would have shown, so a skip is not detected here, and a page containing a duplicate
        is not evidence of one either (it is only evidence of *this* duplicate).

        **Unverified against a schema.** DO-772's brief could not confirm ``limit``/``skip`` are
        Fireflies' real argument names from anything checked into this repo -- there is no
        Fireflies schema here, and this lane has no live access to check them against the API
        directly. They match the shape documented at docs.fireflies.ai, which is the best
        available signal, but a live run is what actually confirms or refutes them.
        """
        from_date = since.strftime("%Y-%m-%dT%H:%M:%SZ")
        out = []
        seen_ids = set()
        for page_num in range(MAX_PAGES):
            data = self.query(Q_TRANSCRIPTS, {"fromDate": from_date, "limit": PAGE_SIZE, "skip": page_num * PAGE_SIZE})
            page = data.get("transcripts")
            if not isinstance(page, list):
                raise errors.RabotaError("Fireflies reply lacks transcripts")
            if len(page) > PAGE_SIZE:
                raise errors.RabotaError(f"Fireflies returned {len(page)} transcripts for a page of "
                                         f"{PAGE_SIZE}: limit was not honored")
            for t in page:
                tid = t.get("id")
                if tid in seen_ids:     # a reordered server can hand the same id back on a later page
                    continue
                seen_ids.add(tid)
                summary = t.get("summary") or {}
                out.append({"id": tid, "title": t.get("title"), "date": normalize_date(t.get("date")),
                            "action_items": parse_action_items(summary.get("action_items"))})
            if len(page) < PAGE_SIZE:
                return out
        raise errors.RabotaError(f"Fireflies transcripts since {from_date} still paging full pages after "
                                 f"{MAX_PAGES} pages ({len(out)} transcripts): refusing rather than truncating")
