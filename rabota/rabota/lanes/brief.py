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

# HOW THE RULES ARE NAMED, not "does this prose contain a path". The first cut of this check was a
# regex for an absolute path anywhere under `## Common rules`, and an adversarial review lane
# (2026-09-24) broke it in BOTH directions in under a minute: it refused `./scripts/test-rabota.sh`
# and `../other/verdict.json` (the lookbehind omitted `.`, so the match began at the slash) with a
# message telling the author to name the path relatively -- which they had -- and it refused
# `/etc/hosts` and a markdown link `[x](/a/b)` with the false explanation that they exist only on
# one machine. Worse, it ACCEPTED `~/rules.md` and `/rules.md`, because it demanded two or more
# segments, and `~/…` is the exact DO-711 class: the same string, a different file on every
# machine that reads it.
#
# So the question is not "is there a path here". It is "is the rules file named the way it
# actually arrives" -- by basename, beside the brief -- which is a fact about ONE token and needs
# no prose heuristics. Anything ending in a separator immediately before that basename is a path
# prefix, wherever it points and whatever syntax it uses; a Windows `\` is caught by the same rule
# that catches `/`, which the regex could not do at all.
# `[^\s`'"()\[\]]*` so a fence, a quote or a markdown link's punctuation ends the prefix rather
# than being swallowed into it; the prefix must END in a separator to count at all.
RULES_WITH_A_PREFIX = re.compile(r"""[^\s`'"()\[\]]*[/\\]""" + re.escape(RULES.name))


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
    # The rules must be named the way they actually arrive -- by basename, beside the brief.
    #
    # The join is for convenience, NOT correctness, and the mutation sweep is what established
    # that: swapping "\n" for " " here kills no row, because the prefix class excludes ALL
    # whitespace and so a match can never span a line break either way. A reference split exactly
    # AT its separator (`/home/zvi/` then `_common-rules.md` on the next line) is therefore not
    # caught, in any join. That limit is recorded rather than papered over -- like the secret
    # guard, this is a papercut guard and not a boundary: a brief that evades it still gets the
    # real rules, because `run_recipe` ships them whatever the brief says.
    rules_section = "\n".join(_section(lines, "## Common rules"))
    m = RULES_WITH_A_PREFIX.search(rules_section)
    if m:
        raise errors.Usage(
            f"{where} names {m.group(0)!r} under '## Common rules': a path prefix resolves against "
            f"whichever machine reads it, and a lane does not run on this one. `lane recipe` ships "
            f"the rules into the lane's out_dir, so name them by basename alone -- "
            f"`{RULES.name}`, in this brief's own directory")
    if RULES.name not in rules_section:
        # Not merely "no absolute path": a section that never names the rules at all is a lane
        # that will not read them, which is the outcome DO-711 was about. Absence used to pass.
        raise errors.Usage(
            f"{where} does not name {RULES.name} under '## Common rules': `lane recipe` ships it "
            f"beside the brief, and a lane that is not told to read it will not")
    out_dir = None
    for l in lines:
        if l.strip().lower().startswith("out_dir:"):
            out_dir = l.split(":", 1)[1].strip()
    return {"title": title, "sections": list(REQUIRED_HEADINGS), "out_dir": out_dir}


def substitute(text: str, **placeholders) -> str:
    """Replace each ``{name}`` in ``text`` with its keyword value, by literal substring
    replacement -- never ``str.format``.

    A brief may legitimately contain ``{`` and ``}`` for reasons that have nothing to do with
    this substitution: a JSON example in the Assignment section, or a shell ``${VAR}`` snippet.
    ``str.format`` would choke on the former (an unescaped ``{`` in a JSON blob is a
    ``KeyError``/``IndexError`` waiting to happen) and has no reason to ever see the latter. A
    plain ``.replace()`` per named placeholder touches only the exact tokens it is given and
    leaves everything else byte for byte untouched, which is what ``render_evaluate`` already
    relied on before this helper existed to name the technique.
    """
    for name, value in placeholders.items():
        text = text.replace("{" + name + "}", str(value))
    return text


def render_evaluate(of_lane: dict, verdict_path: Path, out_dir: Path) -> str:
    return substitute(TEMPLATE.read_text(), lane_id=of_lane["id"], lane_brief=of_lane["brief"],
                       verdict_path=str(verdict_path), out_dir=str(out_dir))
