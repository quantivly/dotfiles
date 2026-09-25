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

No branch below raises: the four cases above already fall out of one loop with no special-casing,
which is the point — a shape observed in a handful of meetings should not be enforced as a schema.
"""
import json
import re
import urllib.error
import urllib.request
from datetime import datetime
from typing import Callable

from rabota import errors

ENDPOINT = "https://api.fireflies.ai/graphql"
TIMEOUT_SECONDS = 60

Q_TRANSCRIPTS = """query($fromDate: DateTime) {
  transcripts(fromDate: $fromDate) {
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
            speaker = None if name == "Unassigned" else name
            continue
        match = _TIMESTAMP_RE.search(line)
        timestamp = match.group(1) if match else None
        item = line[:match.start()].rstrip() if match else line
        items.append({"speaker": speaker, "item": item, "timestamp": timestamp})
    return items


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
        """Transcripts since ``since``, each with ``action_items`` already parsed."""
        data = self.query(Q_TRANSCRIPTS, {"fromDate": since.strftime("%Y-%m-%dT%H:%M:%SZ")})
        out = []
        for t in data.get("transcripts") or []:
            summary = t.get("summary") or {}
            out.append({"id": t.get("id"), "title": t.get("title"), "date": t.get("date"),
                        "action_items": parse_action_items(summary.get("action_items"))})
        return out
