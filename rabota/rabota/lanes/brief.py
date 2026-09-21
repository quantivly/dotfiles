"""The seven-part brief (spec §C6) and the evaluate-brief renderer."""
from pathlib import Path
from rabota import errors

REQUIRED_HEADINGS = ("## Common rules", "## Role", "## Assignment", "## Ownership", "## Outputs", "## Summary")
TEMPLATE = Path(__file__).resolve().parent.parent.parent / "briefs" / "evaluate.md.tmpl"


def validate(path: Path) -> dict:
    try:
        text = Path(path).read_text()
    except OSError as e:
        raise errors.Usage(f"brief unreadable: {e}")
    lines = text.splitlines()
    title = next((l[2:].strip() for l in lines if l.startswith("# ")), None)
    missing = [h for h in REQUIRED_HEADINGS if not any(l.strip() == h for l in lines)]
    if title is None:
        missing.insert(0, "# <title>")
    if missing:
        raise errors.Usage("brief is missing sections: " + ", ".join(missing))
    out_dir = None
    for l in lines:
        if l.strip().lower().startswith("out_dir:"):
            out_dir = l.split(":", 1)[1].strip()
    return {"title": title, "sections": list(REQUIRED_HEADINGS), "out_dir": out_dir}


def render_evaluate(of_lane: dict, verdict_path: Path, out_dir: Path) -> str:
    return (TEMPLATE.read_text()
            .replace("{lane_id}", of_lane["id"]).replace("{lane_brief}", str(of_lane["brief"]))
            .replace("{verdict_path}", str(verdict_path)).replace("{out_dir}", str(out_dir)))
