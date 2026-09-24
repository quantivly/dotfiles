"""The seven-part brief (spec §C6) and the evaluate-brief renderer."""
import re
from pathlib import Path
from rabota import errors

REQUIRED_HEADINGS = ("## Common rules", "## Role", "## Assignment", "## Ownership", "## Outputs", "## Summary")
BRIEFS = Path(__file__).resolve().parent.parent.parent / "briefs"
TEMPLATE = BRIEFS / "evaluate.md.tmpl"

# The lane rules, shipped INTO the lane's out_dir beside brief.md rather than named by an absolute
# path (DO-711). The laptop path the briefs used to name exists on no other machine, and `dev` --
# the only machine where `--run` works -- has neither `/home/zvi` nor a copy under its own `$HOME`,
# so every lane dispatched there failed its first instruction and carried on without the hard
# rails. A copy made fresh per dispatch cannot go stale, and out_dir is the one directory the lane
# is guaranteed to reach (`--add-dir`).
RULES = BRIEFS / "_common-rules.md"

# A path a lane cannot be assumed to have: absolute, or home-relative on a machine whose $HOME is
# not this process's. Two or more segments are required so that a lone `/` in prose (`pass/fail`)
# is not read as a path; the lookbehind keeps `and/or` and the `//` of a URL out for the same
# reason. `\b`-style boundaries are not used -- `~` is not a word character.
ABSOLUTE_PATH = re.compile(r"(?<![\w/~])(?:~?/[\w.+-]*[\w+-]){2,}")


def _section(lines: list[str], heading: str) -> list[str]:
    """The lines under ``heading``, up to the next ``## `` heading. Empty when it is absent."""
    out = []
    inside = False
    for line in lines:
        if line.strip() == heading:
            inside = True
            continue
        if inside and line.startswith("## "):
            break
        if inside:
            out.append(line)
    return out


def read_rules(path: Path | None = None) -> str:
    """The lane rules text. Absent, unreadable or EMPTY is a refusal naming the path.

    Empty counts as a failure rather than as "no rules": a lane handed an empty rules file is a
    lane running without rails, which is the whole of what DO-711 was about, and it would arrive
    looking exactly like a success.
    """
    p = Path(path) if path is not None else RULES
    try:
        text = p.read_text()
    except OSError as e:
        raise errors.Refused(f"the lane rules file is unreadable: {e}") from None
    if not text.strip():
        raise errors.Refused(f"the lane rules file is empty: {p}")
    return text


def validate(path: Path) -> dict:
    """Validate the brief at ``path``. See ``validate_text`` for the rules."""
    try:
        text = Path(path).read_text()
    except OSError as e:
        raise errors.Usage(f"brief unreadable: {e}")
    return validate_text(text, where=str(path))


def validate_text(text: str, where: str = "brief") -> dict:
    """The brief contract, applied to text someone else produced.

    Split out from ``validate`` (DO-711) so the evaluate brief — which is RENDERED from
    ``evaluate.md.tmpl`` and never exists as a file on this machine — is held to the same rules as
    a work brief before it is shipped. A second, laxer implementation for the rendered form is the
    shape ``verdict.validate`` / ``validate_text`` already exists to avoid.
    """
    lines = text.splitlines()
    title = next((l[2:].strip() for l in lines if l.startswith("# ")), None)
    missing = [h for h in REQUIRED_HEADINGS if not any(l.strip() == h for l in lines)]
    if title is None:
        missing.insert(0, "# <title>")
    if missing:
        raise errors.Usage(f"{where} is missing sections: " + ", ".join(missing))
    # The rules must be named the way they actually arrive -- beside the brief, in out_dir. An
    # absolute path here is the DO-711 defect itself, and it is silent: the lane reports the
    # failure in `followups` if it is conscientious, and otherwise just proceeds without the
    # rails. This refuses the CLASS (any absolute path), not the one path that was wrong.
    for l in _section(lines, "## Common rules"):
        m = ABSOLUTE_PATH.search(l)
        if m:
            raise errors.Usage(
                f"{where} names {m.group(0)!r} under '## Common rules': that path exists only on the "
                f"machine the brief was written on. The rules are shipped into the lane's out_dir, "
                f"so name them relatively -- `{RULES.name}`, in this brief's own directory")
    out_dir = None
    for l in lines:
        if l.strip().lower().startswith("out_dir:"):
            out_dir = l.split(":", 1)[1].strip()
    return {"title": title, "sections": list(REQUIRED_HEADINGS), "out_dir": out_dir}


def render_evaluate(of_lane: dict, verdict_path: Path, out_dir: Path) -> str:
    return (TEMPLATE.read_text()
            .replace("{lane_id}", of_lane["id"]).replace("{lane_brief}", str(of_lane["brief"]))
            .replace("{verdict_path}", str(verdict_path)).replace("{out_dir}", str(out_dir)))
