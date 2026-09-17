"""Structural guard: no module outside ``emit.py`` may write a file directly.

Three times in this epic a write path skipped ``secrets.assert_clean`` — WS1 D1, the WS4′
``write_text`` deviation, and WS2 k2 (``brief.py``, then ``rank.py`` a round later). Each was
patched at the site; this test is what stops a fourth round. It greps the package for every
spelling of "write a file" and fails on any hit that is not on the allow-list below, where each
exemption names the line it excuses and why that line is safe.
"""
import re
import unittest
from pathlib import Path

PKG = Path(__file__).resolve().parent.parent / "rabota"

# Every spelling of "bytes leave the process onto disk". ``json.dumps`` is deliberately NOT here:
# it returns a string, and a string is harmless until something in this list writes it.
WRITE_PATTERNS = {
    "Path.write_text":          re.compile(r"\.write_text\b"),      # the attribute, not the call: `_wt = p.write_text; _wt(x)` is a write too
    "Path.write_bytes":         re.compile(r"\.write_bytes\b"),
    "json.dump(obj, fp)":       re.compile(r"\bjson\.dump\("),
    "open(..., 'w'|'a'|'x')":   re.compile(r"\bopen\((?:[^()\n]|\([^()\n]*\))*['\"][rbt+]*[wax]"),   # one level of ( ) in the path: open(str(p), "w")
    "os.fdopen":                re.compile(r"\bos\.fdopen\("),
    "file.write":               re.compile(r"(?<!snapshots)\.write\("),   # snapshots.write guards its payload; its own lines are allow-listed below
    "os.replace/os.rename":     re.compile(r"\bos\.(replace|rename)\("),
    "shutil.copy*/move":        re.compile(r"\bshutil\.(copy\w*|move)\("),
    "tempfile.mkstemp/Named…":  re.compile(r"\btempfile\.(mkstemp|NamedTemporaryFile)\("),
}

# The one module allowed to write: it is the guard. Every helper in it calls ``assert_clean`` first.
EXEMPT_MODULES = {"emit.py"}

# (module, regex the offending line must match, why it is safe). Each entry MUST still match a
# line — a stale exemption is a failure, so an excuse cannot outlive the line it excused.
ALLOWED_LINES = [
    ("snapshots.py", re.compile(r"tempfile\.mkstemp\(dir=path\.parent"),
     "atomic write: the temp file is created next to the snapshot; the payload was already passed "
     "through secrets.assert_clean on the line above, before anything exists on disk"),
    ("snapshots.py", re.compile(r'os\.fdopen\(fd, "w"\) as f'),
     "the mkstemp fd being turned into a file object; same guarded text"),
    ("snapshots.py", re.compile(r"^\s*f\.write\(text\)$"),
     "writes the guarded ``text`` variable and nothing else"),
    ("snapshots.py", re.compile(r"os\.replace\(tmp, path\)"),
     "renames the guarded temp file into place; no new bytes"),
    ("cli.py", re.compile(r"sys\.stderr\.write\(_LEAK_FALLBACK\)"),
     "the fallback when even reporting a SecretLeak would leak: a constant string with no "
     "interpolation, so there is nothing for the guard to check"),
    ("cli.py", re.compile(r'sys\.stderr\.write\(f"usage: \{e\}\\n"\)'),
     "argparse's own message about argv; it can echo a bad argument, which is argv the caller "
     "typed and never a value rabota holds. cli.py is outside the ws2-fix2 fence — recorded as a "
     "followup rather than rerouted here"),
]


def _hits():
    """``(module, lineno, line, pattern name)`` for every write-shaped line outside the exempt module."""
    out = []
    for path in sorted(PKG.rglob("*.py")):
        rel = str(path.relative_to(PKG))
        if path.name in EXEMPT_MODULES:
            continue
        for lineno, line in enumerate(path.read_text().splitlines(), 1):
            code = line.split("#", 1)[0] if not line.lstrip().startswith("#") else ""
            for name, rx in WRITE_PATTERNS.items():
                if rx.search(code):
                    out.append((rel, lineno, line.strip(), name))
    return out


class WriteGuardTests(unittest.TestCase):
    def test_package_is_where_this_test_thinks_it_is(self):
        # An empty scan would pass every assertion below; make sure the scan saw the package.
        modules = {p.name for p in PKG.rglob("*.py")}
        self.assertTrue({"emit.py", "snapshots.py", "cli.py", "rank.py", "brief.py", "sync.py"} <= modules, modules)

    def test_only_emit_writes_files(self):
        unexplained, used = [], set()
        for rel, lineno, line, name in _hits():
            for i, (mod, rx, _why) in enumerate(ALLOWED_LINES):
                if Path(rel).name == mod and rx.search(line):
                    used.add(i); break
            else:
                unexplained.append(f"{rel}:{lineno}: {line}    [{name}]")
        self.assertFalse(unexplained,
                         "file writes outside emit.py — route them through emit.write_file (which calls "
                         "secrets.assert_clean and writes nothing on a leak):\n  " + "\n  ".join(unexplained))
        stale = [f"{mod}: {rx.pattern}" for i, (mod, rx, _) in enumerate(ALLOWED_LINES) if i not in used]
        self.assertFalse(stale, "allow-list entries that no longer match any line (remove them):\n  " + "\n  ".join(stale))

    def test_patterns_catch_each_spelling(self):
        # The regexes are the guard; pin what each must catch and what it must leave alone.
        rx = WRITE_PATTERNS
        for name, sample in (("Path.write_text", 'p.write_text(json.dumps(x))'), ("json.dump(obj, fp)", "json.dump(seq, fh)"),
                             ("open(..., 'w'|'a'|'x')", 'with open(p, "w") as f:'), ("open(..., 'w'|'a'|'x')", 'path.open("wb")'),
                             ("open(..., 'w'|'a'|'x')", 'open(p, mode="a+")'), ("file.write", "fh.write(text)"),
                             # round-4 gate: a call inside the path argument, and an aliased bound method — both evaded
                             ("open(..., 'w'|'a'|'x')", 'open(str(p), "w")'), ("open(..., 'w'|'a'|'x')", 'open(os.path.join(d, n), "wb")'),
                             ("Path.write_text", "_wt = p.write_text"), ("Path.write_bytes", "w = out.write_bytes"),
                             ("os.replace/os.rename", "os.replace(tmp, p)")):
            self.assertTrue(rx[name].search(sample), f"{name} misses {sample!r}")
        for sample in ('with path.open("rb") as f:', "json.dumps(body).encode()", 'open(p, "r")', "json.loads(path.read_text())"):
            self.assertFalse(any(r.search(sample) for r in rx.values()), f"false positive on {sample!r}")
