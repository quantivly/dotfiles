#!/usr/bin/env python3
"""Emit the SHELL and the ${{ }} placements of a GitHub Actions YAML file.

WHY THIS EXISTS (DO-608). scripts/check-workflow-apt.sh needs to know which
lines of a workflow or action are shell, and where every `${{ }}` sits. It did
that by hand in awk, and three rounds of independent review found six separate
ways the hand parser went QUIET -- each one printing a full row of green ticks
over a complete restoration of the outage this guard exists to prevent:

  - `run: |  # refresh, then install` is valid YAML, but a comment after the
    block indicator meant the block never opened and the whole script was
    dropped. Three rules went silent at once.
  - A step's sibling keys (`name:`, `env:`) are indented deeper than the `- `
    of `- run: |`, so they were read as part of the block body -- which made a
    `name:` describing the forbidden shape a false violation.
  - A multi-line string inside a run block had its continuation lines scanned
    as unquoted shell, because quote state reset per line.
  - The install-strict check read the whole file, so an unquoted `description:`
    mentioning `apt-get install -y` satisfied it while the action installed
    nothing.
  - CRLF line endings broke block detection the same way as the header comment.

Every one of those is a YAML question, and the answer to a YAML question is a
YAML parser. What is left after this -- operator position, apt's option forms,
heredoc bodies -- is genuinely shell-level and lives in the caller.

The dependency is deliberate and LOUD. PyYAML absent, the file unreadable, or
the YAML unparseable all exit 2 with a message; none of them prints nothing and
lets the caller read silence as "no shell here". That is the one property the
awk version could not offer, and this repo already records what a quiet
dependency costs a checker ("a new external tool is a new way for a check to go
quiet"). python3-yaml is a stock Ubuntu package and the CI job installs it.

Usage:
  gha-yaml-shell.py --shell  FILE   ->  <lineno>\\t<stripped shell>
  gha-yaml-shell.py --interp FILE   ->  <lineno>\\t(env|other)
"""

from __future__ import annotations

import sys

try:
    import yaml
except ModuleNotFoundError:
    sys.stderr.write(
        "gha-yaml-shell: PyYAML is required (Debian/Ubuntu: python3-yaml).\n"
        "Refusing to guess at the YAML by hand: this file exists because six\n"
        "separate defects came from doing exactly that.\n"
    )
    raise SystemExit(2)


def strip_shell(text: str) -> list[tuple[int, str]]:
    """Return (offset, code) for the shell lines of one run scalar.

    Comments and the CONTENTS of quoted strings are removed, so a line that
    merely NAMES a command is not mistaken for running it -- `git commit -m
    "stop apt-get update failing CI"` has to pass. Quote state is carried
    ACROSS lines, because a multi-line string's continuation lines are data:
    resetting per line is what made them read as commands.

    Heredoc bodies are dropped for the same reason. They are the likeliest
    place for someone to document this very rule, and this repo has already
    been bitten by a guard tripping on its own source quoted in a heredoc.
    """
    out: list[tuple[int, str]] = []
    sq = dq = False
    heredoc: str | None = None
    # A trailing backslash continues the logical line. The caller's rules are
    # per-line, so `sudo apt-get update \` followed by `|| true` was split
    # across two records and the refresh read as fatal -- a false positive on
    # a correct action.
    pending_line: str | None = None
    pending_off = 0
    for offset, raw in enumerate(text.split("\n")):
        line = raw.rstrip("\r")

        if heredoc is not None:
            if line.strip() == heredoc:
                heredoc = None
            continue

        code_chars: list[str] = []
        i, n = 0, len(line)
        while i < n:
            c = line[i]
            if not sq and not dq and c == "#" and (i == 0 or line[i - 1] in " \t"):
                break
            if not dq and c == "'":
                sq = not sq
                i += 1
                continue
            if not sq and c == '"':
                dq = not dq
                i += 1
                continue
            if sq or dq:
                i += 1
                continue
            code_chars.append(c)
            i += 1
        code = "".join(code_chars)

        if pending_line is not None:
            code = pending_line + " " + code.lstrip()
        else:
            pending_off = offset
        if code.rstrip().endswith("\\"):
            pending_line = code.rstrip()[:-1].rstrip()
            continue
        pending_line = None

        # A heredoc introducer opens on the NEXT line; the introducer line is
        # still code (it may carry a command before the `<<`).
        marker = _heredoc_marker(code)
        if marker is not None:
            heredoc = marker
        out.append((pending_off, code))
    if pending_line is not None:
        out.append((pending_off, pending_line))
    return out


def _heredoc_marker(code: str) -> str | None:
    """The delimiter word of a heredoc introducer on this line, or None."""
    idx = code.rfind("<<")
    if idx < 0:
        return None
    rest = code[idx + 2 :]
    if rest.startswith("<"):  # `<<<` is a here-STRING, not a heredoc
        return None
    rest = rest.lstrip("-").strip()
    if not rest:
        return None
    word = rest.split()[0].strip("'\"")
    return word or None


def walk(node, path, runs, interps):
    """Collect run scalars and ${{ }} placements from a composed node tree."""
    if isinstance(node, yaml.MappingNode):
        for key, value in node.value:
            name = key.value if isinstance(key, yaml.ScalarNode) else ""
            if name == "run" and isinstance(value, yaml.ScalarNode):
                runs.append((value.start_mark.line, value.value))
            if isinstance(value, yaml.ScalarNode) and "${{" in (value.value or ""):
                # `env:` is the only placement that keeps an interpolation out
                # of a shell line. `run` is a valid key name too, so it is
                # classified as `other` however it is spelled.
                kind = "env" if (path and path[-1] == "env") else "other"
                interps.append((value.start_mark.line, kind))
            walk(value, path + [name], runs, interps)
    elif isinstance(node, yaml.SequenceNode):
        for item in node.value:
            walk(item, path, runs, interps)


def main() -> int:
    if len(sys.argv) != 3 or sys.argv[1] not in ("--shell", "--interp"):
        sys.stderr.write(__doc__.split("Usage:")[-1])
        return 2
    mode, path = sys.argv[1], sys.argv[2]
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError as exc:
        sys.stderr.write(f"gha-yaml-shell: cannot read {path}: {exc}\n")
        return 2
    try:
        docs = list(yaml.compose_all(text))
    except yaml.YAMLError as exc:
        first = str(exc).split("\n")[0]
        sys.stderr.write(f"gha-yaml-shell: {path} is not parseable YAML: {first}\n")
        return 2

    runs: list[tuple[int, str]] = []
    interps: list[tuple[int, str]] = []
    for doc in docs:
        if doc is not None:
            walk(doc, [], runs, interps)

    if mode == "--shell":
        for start, scalar in runs:
            for offset, code in strip_shell(scalar or ""):
                if code.strip():
                    print(f"{start + offset + 1}\t{code}")
    else:
        for line, kind in interps:
            print(f"{line + 1}\t{kind}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
