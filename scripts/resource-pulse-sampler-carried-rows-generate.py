#!/usr/bin/env python3
"""Regenerate resource-pulse-sampler/tests/carried-rows.txt.

The list names every row of the gjs sampler's tests that the compiled sampler
must carry over: the title (the JavaScript string's value) of each ``test(``
call in the six files below, one per line under a ``# <file>`` heading.
scripts/resource-pulse-sampler-carried-rows.sh checks the crate against it.

Usage: scripts/resource-pulse-sampler-carried-rows-generate.py [output-path]
Without an output path the list is printed on stdout. Exit 1 when a file's
count differs from the expected one or a title repeats; exit 2 on a file
that cannot be read.
"""
from __future__ import annotations

import ast
import re
import sys
from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
TESTS_DIRECTORY = REPOSITORY_ROOT / "gnome-shell" / "tests"
# File stem -> number of titles it must hold. The counts are the design's; a
# different count is reported, never adjusted to.
EXPECTED_TITLE_COUNTS: dict[str, int] = {
    "service-sampler": 55,
    "service-dbus": 9,
    "parsers": 16,
    "math": 22,
    "apps": 41,
    "cadence": 36,
}
# One single-quoted JavaScript string literal; \\. keeps an escaped quote inside it.
STRING_LITERAL_PATTERN = r"'(?:[^'\\]|\\.)*'"
# A test( call at the start of a line whose first argument is one string literal or several joined by `+`
# (a long title is split over lines that way).
TEST_TITLE_PATTERN = re.compile(
    rf"^\s*test\(\s*({STRING_LITERAL_PATTERN}(?:\s*\+\s*{STRING_LITERAL_PATTERN})*)", re.MULTILINE
)
LITERAL_PATTERN = re.compile(STRING_LITERAL_PATTERN)


def titles_in(test_file: Path) -> list[str]:
    """Return the title values of every ``test(`` call in ``test_file``.

    Parameters
    ----------
    test_file : Path
        A gjs test file.

    Returns
    -------
    list[str]
        The titles, in file order, with JavaScript escapes resolved.
    """
    source_text = test_file.read_text(encoding="utf-8")
    return [
        "".join(ast.literal_eval(literal) for literal in LITERAL_PATTERN.findall(first_argument))
        for first_argument in TEST_TITLE_PATTERN.findall(source_text)
    ]


def build_list() -> tuple[str, list[str]]:
    """Build the list text and the problems found while building it.

    Returns
    -------
    tuple[str, list[str]]
        The file text and a list of problems (empty when all is well).
    """
    problems: list[str] = []
    lines: list[str] = []
    seen_titles: dict[str, str] = {}
    for file_stem, expected_count in EXPECTED_TITLE_COUNTS.items():
        titles = titles_in(TESTS_DIRECTORY / f"{file_stem}.test.js")
        if len(titles) != expected_count:
            problems.append(f"{file_stem}: expected {expected_count} titles, found {len(titles)}")
        lines.append(f"# {file_stem}")
        for title in titles:
            if title in seen_titles:
                problems.append(f"title in both {seen_titles[title]} and {file_stem}, or twice: {title}")
            seen_titles[title] = file_stem
            lines.append(title)
    return "\n".join(lines) + "\n", problems


def main(arguments: list[str]) -> int:
    """Write or print the list; return the exit status."""
    try:
        list_text, problems = build_list()
    except OSError as error:
        print(f"cannot read a test file: {error}", file=sys.stderr)
        return 2
    for problem in problems:
        print(f"PROBLEM: {problem}", file=sys.stderr)
    if arguments:
        Path(arguments[0]).write_text(list_text, encoding="utf-8")
    else:
        sys.stdout.write(list_text)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
