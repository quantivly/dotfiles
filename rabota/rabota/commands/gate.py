"""``rabota gate``: record that a gate was answered — the skill's own words: "Durable records say
'the gate was answered: <label>', never who answered." ``Store.record_gate`` writes ``(tenant, ts,
subject, label)`` with no identity column at all, so there is nothing here to accidentally carry a
person through. A plain ``INSERT`` (no upsert): each answered gate is its own event in an
append-only log, so re-running the same ``--subject``/``--label`` records a second, independent
answer rather than overwriting the first.
"""
from rabota import cli, errors
from rabota.context import Context


def run_gate(ctx: Context, subject: str, label: str) -> dict:
    """Append a gate-answered event; with ``ctx.dry_run`` (DO-753) no ``gate_answers`` row is written."""
    if ctx.dry_run:
        return {"subject": subject, "label": label, "ts": None, "dry_run": "nothing written (gate_answers row)"}
    ctx.store.record_gate(ctx.tenant.name, subject, label)
    row = ctx.store.gates(ctx.tenant.name)[-1]
    return {"subject": row["subject"], "label": row["label"], "ts": row["ts"]}


def _build(sub):
    g = sub.add_parser("gate", help="record that a gate was answered (label only, never who)")
    g.add_argument("--subject", required=True)
    g.add_argument("--label", required=True)


def _run(ns):
    # A blank subject or label makes a durable record that says nothing: "the gate was answered: ".
    if not ns.subject.strip():
        raise errors.Usage("--subject must not be empty; it is what the record says was gated")
    if not ns.label.strip():
        raise errors.Usage("--label must not be empty; it is the answer the record preserves")
    return run_gate(Context.from_namespace(ns), ns.subject, ns.label)


cli.register("gate", _build, _run)
