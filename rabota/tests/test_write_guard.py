"""Structural guard: no module outside ``emit.py`` may write a file directly.

Three times in this epic a write path skipped ``secrets.assert_clean`` — WS1 D1, the WS4′
``write_text`` deviation, and WS2 k2 (``brief.py``, then ``rank.py`` a round later). Each was
patched at the site; this test is what stops a fourth round. It greps the package for every
spelling of "write a file" and fails on any hit that is not on the allow-list below, where each
exemption names the line it excuses and why that line is safe. A second list, ``GUARDED_LINES``,
excuses a write that calls ``secrets.assert_clean`` itself — and only while the module's AST shows
the written name is that call's result and nothing else.
"""
import ast
import re
import tempfile
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

# Writes that guard the text THEMSELVES rather than through ``emit.write_file``: the module calls
# ``secrets.assert_clean`` and writes its result, and nothing else. An entry here is an allow-list
# entry with a precondition — the excused line is accepted only while ``_guarded_write`` can prove,
# from the module's AST, that the written name is bound exactly once in its function, that the
# binding IS the ``assert_clean`` call, and that the write cannot be reached without passing it
# (same block or an enclosing one, earlier). Delete the guard line above the write and the write goes red
# again; a third module using the same shape is unexplained until it is named here and its reason
# given. Both entries are #154's, merged after this branch was cut; their pattern predates this
# gate and is deliberate ("Written through the same guard emit applies to stdout"), so the test
# learned the shape rather than the files learning the test.
GUARDED_LINES = [
    ("census.py", re.compile(r'\(ctx\.state_dir / "census\.json"\)\.write_text\(text\)'),
     "census.json is a contract file written through assert_clean directly; the guarded ``text`` "
     "is the only thing written"),
    ("budget.py", re.compile(r'\(ctx\.state_dir / "budget\.json"\)\.write_text\(text\)'),
     "budget.json, same shape: assert_clean binds ``text`` on the line above and ``text`` alone is written"),
]


def _hits(pkg=PKG):
    """``(module, lineno, line, pattern name)`` for every write-shaped line outside the exempt module."""
    out = []
    for path in sorted(pkg.rglob("*.py")):
        rel = str(path.relative_to(pkg))
        if path.name in EXEMPT_MODULES:
            continue
        for lineno, line in enumerate(path.read_text().splitlines(), 1):
            code = line.split("#", 1)[0] if not line.lstrip().startswith("#") else ""
            for name, rx in WRITE_PATTERNS.items():
                if rx.search(code):
                    out.append((rel, lineno, line.strip(), name))
    return out


def _is_assert_clean(call):
    f = call.func
    return (isinstance(f, ast.Attribute) and f.attr == "assert_clean") or (isinstance(f, ast.Name) and f.id == "assert_clean")


def _block_chains(fn):
    """``{id(stmt): chain}`` for every statement under ``fn``: the tuple of ``(compound node, field)`` blocks
    from the function body down to the block that holds the statement (``()`` for the body itself).
    ``except`` handlers and ``match`` cases are blocks too, so a statement in one has the handler in
    its chain. Statement identity, not line numbers: two statements on one line are still two."""
    chains = {}
    def visit(stmts, chain):
        for s in stmts:
            chains[id(s)] = chain
            for field, value in ast.iter_fields(s):
                if not isinstance(value, list) or not value:
                    continue
                if all(isinstance(v, ast.stmt) for v in value):
                    visit(value, chain + ((s, field),))
                elif all(isinstance(v, (ast.ExceptHandler, ast.match_case)) for v in value):
                    for h in value:
                        visit(h.body, chain + ((s, field), (h, "body")))
    visit(fn.body, ())
    return chains


def _guard_dominates(fn, guard, write_call):
    """Is ``guard`` (a statement) on every path from the function's entry to ``write_call``, in the
    brief's syntactic sense? Its block must be the write's block or an enclosing one — the chain of
    blocks holding the guard is a prefix of the chain holding the write — and within that shared block
    the guard must come before the statement that leads to the write. A guard under an ``if``, in a
    ``try`` the write follows, in a sibling branch, or in a loop body the write sits outside all fail
    the prefix test; a guard after the write in one block fails the order test. Not a CFG: ``return``,
    ``break`` and raised exceptions are not modelled, in the direction of refusing (a guard that only
    LOOKS skippable is refused, never one that IS skippable accepted)."""
    chains = _block_chains(fn)
    holders = [s for s in ast.walk(fn) if isinstance(s, ast.stmt) and id(s) in chains and any(n is write_call for n in ast.walk(s))]
    if not holders or id(guard) not in chains:
        return False
    write_stmt = max(holders, key=lambda s: len(chains[id(s)]))      # the innermost statement holding the call
    gchain, wchain = chains[id(guard)], chains[id(write_stmt)]
    if wchain[:len(gchain)] != gchain:
        return False
    lead = write_stmt if len(wchain) == len(gchain) else wchain[len(gchain)][0]   # the write's ancestor in the guard's block
    block = getattr(*gchain[-1]) if gchain else fn.body
    return block.index(guard) < block.index(lead)


def _bindings_of(fn, name):
    """Every AST node under ``fn`` that binds ``name`` — the constructs, not the statement types
    that usually carry them (eval-5 k8: counting ``Assign`` nodes with a plain ``Name`` target let
    ``text, _n = json.dumps(out), 1`` rebind the guarded name invisibly). A ``Name`` in Store context
    covers an assignment target at any nesting (tuple, list, starred), ``for``/``async for``, ``with … as``
    (bare or tuple), comprehension targets, ``:=`` and augmented/annotated assignment; the rest bind
    without a ``Name`` node: ``except … as``, ``import``/``from … import`` with or without ``as``, the
    ``match`` capture forms (``MatchAs``, ``MatchStar``, ``MatchMapping``'s ``**rest`` — sub-patterns of
    ``MatchSequence``/``MatchClass``/``MatchOr`` are reached by the walk), a nested ``def``/``class`` of
    that name, and a ``global``/``nonlocal`` declaration, which makes the guard bind a name some other
    scope can rebind. Parameters are not counted: the guard rebinding its own parameter is the shape
    ``_guard_dominates`` judges."""
    out = []
    for n in ast.walk(fn):
        if isinstance(n, ast.Name) and isinstance(n.ctx, ast.Store) and n.id == name:
            out.append(n)
        elif isinstance(n, ast.ExceptHandler) and n.name == name:
            out.append(n)
        elif isinstance(n, ast.alias) and (n.asname or n.name.split(".", 1)[0]) == name:
            out.append(n)
        elif isinstance(n, (ast.MatchAs, ast.MatchStar)) and n.name == name:
            out.append(n)
        elif isinstance(n, ast.MatchMapping) and n.rest == name:
            out.append(n)
        elif isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)) and n is not fn and n.name == name:
            out.append(n)
        elif isinstance(n, (ast.Global, ast.Nonlocal)) and name in n.names:
            out.append(n)
    return out


def _guarded_write(path, lineno):
    """True iff the ``.write_text``/``.write_bytes`` call on ``lineno`` writes one bare name, that name
    is bound exactly once in the innermost enclosing function — by any construct that binds a name
    (``_bindings_of``) — that one binding is ``x = secrets.assert_clean(...)`` with ``x`` its whole
    target, and it dominates the write (``_guard_dominates``): the write cannot be reached without it.

    Anything the AST cannot vouch for — no enclosing function, an expression argument, a name
    with no binding in the function (a parameter, a global), a second binding anywhere in the
    function however it is spelled (a rebinding after the guard is a new value; a guard on one
    branch only is one; ``text, _n = …``, ``except E as text``, ``import x as text`` and a ``match``
    capture are all rebindings — eval-5 k8), or a single guard binding the write can bypass (eval-4
    mutant A: the written name is a parameter and the one binding sits under an ``if``, so counting
    bindings saw exactly one and it was the guard), or the write's innermost enclosing scope is a
    ``lambda`` rather than a ``def`` (eval-6 k8: a lambda body is one expression and can bind no
    guard of its own, and its own parameter can shadow the outer name by nothing more than sharing
    a spelling, which this AST match cannot tell apart from real lexical scoping) — is False, and
    the line falls through to "unexplained". False on a doubt, never True. Keyword arguments
    (``encoding=``, ``newline=``) are ignored: the content is the one positional argument.
    """
    tree = ast.parse(path.read_text())
    scopes = [n for n in ast.walk(tree) if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda))
              and n.lineno <= lineno <= n.end_lineno]
    if not scopes:
        return False
    scope = min(scopes, key=lambda n: n.end_lineno - n.lineno)    # innermost
    if isinstance(scope, ast.Lambda):
        # eval-6 k8: a lambda body is one expression, so it cannot itself contain an
        # `assert_clean` assignment, and a name inside one may be the lambda's own
        # (unguarded) parameter rather than the outer scope's guarded variable — the AST
        # match is by name only, not real lexical scoping, so it cannot tell the two apart.
        # False on a doubt, never True.
        return False
    fn = scope
    writes = [n for n in ast.walk(fn) if isinstance(n, ast.Call) and n.lineno == lineno
              and isinstance(n.func, ast.Attribute) and n.func.attr in ("write_text", "write_bytes")]
    if len(writes) != 1 or len(writes[0].args) != 1 or not isinstance(writes[0].args[0], ast.Name):
        return False
    name = writes[0].args[0].id
    bound = _bindings_of(fn, name)
    if len(bound) != 1 or not isinstance(bound[0], ast.Name):
        return False
    # the one binding must be the WHOLE target of a plain assignment whose value is the guard call —
    # ``text, _n = assert_clean(...), 1`` binds ``text`` once too, to a tuple element
    guard = next((s for s in ast.walk(fn) if isinstance(s, ast.Assign) and len(s.targets) == 1 and s.targets[0] is bound[0]), None)
    return (guard is not None and isinstance(guard.value, ast.Call) and _is_assert_clean(guard.value)
            and _guard_dominates(fn, guard, writes[0]))


def _classify(pkg=PKG):
    """``(unexplained, used ALLOWED_LINES indexes, used GUARDED_LINES indexes)`` for every hit under ``pkg``."""
    unexplained, used_allowed, used_guarded = [], set(), set()
    for rel, lineno, line, name in _hits(pkg):
        base = Path(rel).name
        for i, (mod, rx, _why) in enumerate(ALLOWED_LINES):
            if base == mod and rx.search(line):
                used_allowed.add(i); break
        else:
            for i, (mod, rx, _why) in enumerate(GUARDED_LINES):
                if base == mod and rx.search(line) and _guarded_write(pkg / rel, lineno):
                    used_guarded.add(i); break
            else:
                unexplained.append(f"{rel}:{lineno}: {line}    [{name}]")
    return unexplained, used_allowed, used_guarded


class WriteGuardTests(unittest.TestCase):
    def test_package_is_where_this_test_thinks_it_is(self):
        # An empty scan would pass every assertion below; make sure the scan saw the package.
        modules = {p.name for p in PKG.rglob("*.py")}
        self.assertTrue({"emit.py", "snapshots.py", "cli.py", "rank.py", "brief.py", "sync.py"} <= modules, modules)

    def test_only_emit_writes_files(self):
        unexplained, used_allowed, used_guarded = _classify(PKG)
        self.assertFalse(unexplained,
                         "file writes outside emit.py — route them through emit.write_file (which calls "
                         "secrets.assert_clean and writes nothing on a leak), or write the result of "
                         "secrets.assert_clean and nothing else and name the line in GUARDED_LINES:\n  " + "\n  ".join(unexplained))
        stale = [f"{mod}: {rx.pattern}" for i, (mod, rx, _) in enumerate(ALLOWED_LINES) if i not in used_allowed]
        stale += [f"{mod}: {rx.pattern} (guarded)" for i, (mod, rx, _) in enumerate(GUARDED_LINES) if i not in used_guarded]
        self.assertFalse(stale, "allow-list entries that no longer match any line (remove them):\n  " + "\n  ".join(stale))

    # --- the guarded-write exemption (GUARDED_LINES) -------------------------------------------
    # A fixture package with one module; ``_classify`` runs the same rules the real scan does.
    CENSUS_WRITE = '    (ctx.state_dir / "census.json").write_text(text)\n'

    def _fixture(self, module, body):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        pkg = Path(tmp.name) / "rabota"; (pkg / "commands").mkdir(parents=True)
        (pkg / module).write_text("import json, os\nfrom rabota import secrets\n\n" + body)
        return pkg

    def _unexplained(self, pkg):
        return _classify(pkg)[0]

    def test_guarded_exemption_holds_only_for_an_assert_clean_binding(self):
        # The excused shape, exactly as census.py spells it: assert_clean binds ``text``, ``text``
        # is the only thing written. This is the one case the exemption may accept.
        guarded = ("def write(ctx, out):\n"
                   "    text = secrets.assert_clean(json.dumps(out) + '\\n', os.environ)\n" + self.CENSUS_WRITE)
        self.assertEqual(self._unexplained(self._fixture("census.py", guarded)), [])

    def test_guarded_exemption_fails_a_write_with_no_assert_clean_in_its_function(self):
        # The bypass this exemption must never excuse: same line, same module, and the value never
        # went through the guard. Removing the assert_clean line must turn the write red again.
        bare = "def write(ctx, out):\n    text = json.dumps(out) + '\\n'\n" + self.CENSUS_WRITE
        un = self._unexplained(self._fixture("census.py", bare))
        self.assertEqual(len(un), 1, un); self.assertIn("census.py:", un[0]); self.assertIn("write_text", un[0])

    def test_guarded_exemption_fails_when_the_guarded_name_is_rebound_or_not_what_is_written(self):
        head = "def write(ctx, out):\n    text = secrets.assert_clean(json.dumps(out), os.environ)\n"
        cases = {
            "rebound after the guard":   head + "    text = text + os.environ.get('X', '')\n" + self.CENSUS_WRITE,
            "guard result not written":  head + '    (ctx.state_dir / "census.json").write_text(text + "\\n")\n',
            "guard in another function": "def guard(out):\n    text = secrets.assert_clean(json.dumps(out), os.environ)\n"
                                         "def write(ctx, out):\n    text = json.dumps(out)\n" + self.CENSUS_WRITE,
            "written name is a parameter, never bound by the guard":
                                         "def write(ctx, text):\n    text2 = secrets.assert_clean(text, os.environ)\n" + self.CENSUS_WRITE,
            # Two bindings, the guard LAST in source order and on one branch only: at run time the
            # other branch writes the unguarded value. "Last binding wins" would excuse it.
            "guard on one branch only":  "def write(ctx, out):\n    text = json.dumps(out)\n    if ctx.dry_run:\n"
                                         "        text = secrets.assert_clean(text, os.environ)\n" + self.CENSUS_WRITE,
            # The guard binds a module global and the function writes it with no binding of its own:
            # the rule is per function, and a module-level binding is not in the function.
            "guarded name bound at module level": "text = secrets.assert_clean('x', os.environ)\n"
                                         "def write(ctx, out):\n" + self.CENSUS_WRITE,
            # eval-6 k8: the write sits inside a lambda whose own parameter is spelled the same as
            # the guarded name. The AST match is by name only, so without lambda handling this
            # credits the outer guard for a value the lambda's caller supplies directly.
            "write is inside a lambda whose own parameter shadows the guarded name":
                                         head + '    cb = lambda text: (ctx.state_dir / "census.json").write_text(text)\n'
                                         "    cb(str(out))\n",
        }
        for label, body in cases.items():
            with self.subTest(label):
                un = self._unexplained(self._fixture("census.py", body))
                self.assertEqual(len(un), 1, (label, un)); self.assertIn("census.py:", un[0])

    def test_a_third_module_using_the_guarded_shape_must_still_be_listed(self):
        # The exemption is an allow-LIST, not a pattern: a correctly guarded write is still
        # unexplained until someone names it and says why. An entry is a (module, line) pair and
        # each half is tested alone — the excused LINE in another module, and another line in the
        # excused MODULE — so neither half can be dropped without a row noticing.
        head = "def write(ctx, out):\n    text = secrets.assert_clean(json.dumps(out), os.environ)\n"
        other_line = '    (ctx.state_dir / "other.json").write_text(text)\n'
        for label, module, body in (("new module, new file", "other.py", head + other_line),
                                    ("new module, the excused line", "other.py", head + self.CENSUS_WRITE),
                                    ("excused module, another line", "census.py", head + other_line)):
            with self.subTest(label):
                un = self._unexplained(self._fixture(module, body))
                self.assertEqual(len(un), 1, (label, un)); self.assertIn(f"{module}:", un[0])

    def test_guarded_write_judges_the_call_not_the_line(self):
        # ``_guarded_write`` is the precondition behind every GUARDED_LINES entry, including a
        # future one whose regex is looser than the two shipped — so its own verdicts are pinned
        # directly, not only through regexes that happen to end in ``(text)``.
        head = "def write(ctx, out):\n    text = secrets.assert_clean(json.dumps(out), os.environ)\n"
        for label, body, want in (
                ("one bare guarded name",            head + '    p.write_text(text)\n', True),
                ("keyword arguments carry no content", head + '    p.write_text(text, encoding="utf-8")\n', True),
                ("an expression, not the name",      head + '    p.write_text(text + "\\n")\n', False),
                ("two writes on the line",           head + '    p.write_text(text); q.write_text(text)\n', False),
                ("no enclosing function",            "text = secrets.assert_clean('x', os.environ)\np.write_text(text)\n", False),
                # The innermost function is the scope: the closure's own single binding is the guard,
                # and the outer function's plain binding of the same name is not its.
                ("innermost scope decides",          "def outer(ctx, out):\n    text = json.dumps(out)\n    def inner():\n"
                                                     "        text = secrets.assert_clean(json.dumps(out), os.environ)\n"
                                                     "        p.write_text(text)\n    inner()\n", True)):
            with self.subTest(label):
                pkg = self._fixture("m.py", body); path = pkg / "m.py"
                lineno = next(i for i, l in enumerate(path.read_text().splitlines(), 1) if "p.write_text(" in l)
                self.assertIs(_guarded_write(path, lineno), want, label)

    def test_guarded_write_requires_the_guard_to_dominate_the_write(self):
        # eval-4 mutant A: the written name is a PARAMETER and the guard binds it on one branch —
        # exactly one binding, and it is the guard call, so "bound exactly once by assert_clean" was
        # True while the other branch wrote the raw parameter. Counting bindings cannot see this;
        # the guard's statement has to sit in a block the write cannot be reached without passing
        # through — the write's own block or an enclosing one — and come before it. Not sibling
        # branches, not the ``try`` when the write follows it, not a loop body that may run no times.
        top = '    text = secrets.assert_clean(text, os.environ)\n'
        write = '    p.write_text(text)\n'
        for label, body, want in (
                ("A: guard under if, write after it",       "def write(ctx, text):\n    if ctx.dry_run:\n    " + top + write, False),
                ("A2: guard under try/except pass",         "def write(ctx, text):\n    try:\n    " + top + "    except Exception:\n        pass\n" + write, False),
                ("A3: guard in a for that may not run",     "def write(ctx, text):\n    for _ in ctx.items:\n    " + top + write, False),
                ("guard in if, write in its else",          "def write(ctx, text):\n    if ctx.dry_run:\n    " + top + "    else:\n    " + write, False),
                ("guard in try, write in its finally",      "def write(ctx, text):\n    try:\n    " + top + "    finally:\n    " + write, False),
                ("write before the guard in one block",     "def write(ctx, text):\n" + write + top, False),
                ("guard at top level, write under if",      "def write(ctx, text):\n" + top + "    if ctx.dry_run:\n    " + write, True),
                ("guard and write in the same if body",     "def write(ctx, text):\n    if ctx.dry_run:\n    " + top + "    " + write, True),
                ("guard at top level, write in an except",  "def write(ctx, text):\n" + top + "    try:\n        pass\n    except Exception:\n    " + write, True),
                # a handler body and a case body are blocks of their own: both statements inside one is
                # the same-block shape, accepted — without that, the enclosing try/match stands in as the
                # write's holder and a legitimate guard in the handler is refused (mutant D4 survived)
                ("guard and write in the same except body", "def write(ctx, text):\n    try:\n        pass\n    except Exception:\n    " + top + "    " + write, True),
                ("guard and write in the same case body",   "def write(ctx, text):\n    match ctx.mode:\n        case 'x':\n        " + top + "        " + write, True),
                ("guard in one case, write in another",     "def write(ctx, text):\n    match ctx.mode:\n        case 'x':\n        " + top + "        case _:\n        " + write, False),
                ("C: assert_clean(...).upper() is not the guard", "def write(ctx, out):\n    text = secrets.assert_clean(json.dumps(out), os.environ).upper()\n" + write, False)):
            with self.subTest(label):
                pkg = self._fixture("m.py", body); path = pkg / "m.py"
                lineno = next(i for i, l in enumerate(path.read_text().splitlines(), 1) if "p.write_text(" in l)
                self.assertIs(_guarded_write(path, lineno), want, label)

    def test_guarded_write_sees_every_construct_that_binds_the_written_name(self):
        # eval-5 k8: "bound exactly once" counted only ``ast.Assign`` nodes with a plain ``ast.Name``
        # target, so a rebinding spelled any other way was invisible and the write stayed excused —
        # ``text, _n = json.dumps(out), 1`` after the guard reported True, 0 unexplained, against the
        # REAL census.py. Every construct Python has for binding a name is a second binding here,
        # and any one of them beside the guard must refuse the write the way a second ``Assign`` does.
        head = "def write(ctx, out):\n    text = secrets.assert_clean(json.dumps(out), os.environ)\n"
        ahead = "async def write(ctx, out):\n    text = secrets.assert_clean(json.dumps(out), os.environ)\n"
        write = '    p.write_text(text)\n'
        cases = {
            "tuple target":                  head + "    text, _n = json.dumps(out), 1\n",
            "list target":                   head + "    [text, _n] = [json.dumps(out), 1]\n",
            "starred target":                head + "    _h, *text = [1, 2]\n",
            "name nested in a tuple target": head + "    (_a, text), _b = (1, 2), 3\n",
            "for tuple target":              head + "    for text, _i in ctx.items:\n        pass\n",
            "async for target":              ahead + "    async for text in ctx.items:\n        pass\n",
            "with as":                       head + "    with ctx.lock() as text:\n        pass\n",
            "with as tuple":                 head + "    with ctx.lock() as (text, _fh):\n        pass\n",
            "async with as":                 ahead + "    async with ctx.lock() as text:\n        pass\n",
            "except as":                     head + "    try:\n        pass\n    except Exception as text:\n        pass\n",
            "import as":                     head + "    import json as text\n",
            "from import as":                head + "    from os import environ as text\n",
            "bare import":                   head + "    import text\n",
            "from import, no alias":         head + "    from os import text\n",
            "match capture":                 head + "    match ctx.mode:\n        case text:\n            pass\n",
            "match as":                      head + "    match ctx.mode:\n        case [1, 2] as text:\n            pass\n",
            "match star":                    head + "    match ctx.mode:\n        case [_first, *text]:\n            pass\n",
            "match mapping rest":            head + "    match ctx.mode:\n        case {'k': 1, **text}:\n            pass\n",
            "match sequence sub-pattern":    head + "    match ctx.mode:\n        case [text, _second]:\n            pass\n",
            "match class sub-pattern":       head + "    match ctx.mode:\n        case Point(x=text):\n            pass\n",
            "match or sub-patterns":         head + "    match ctx.mode:\n        case [text] | [text, _]:\n            pass\n",
            "nested def of that name":       head + "    def text():\n        pass\n",
            "nested class of that name":     head + "    class text:\n        pass\n",
            "global declaration":            "def write(ctx, out):\n    global text\n    text = secrets.assert_clean(json.dumps(out), os.environ)\n",
            # the guard's result bound to the name UNPACKED — the one binding is the Name, the whole target
            # is not: ``text`` holds a list of characters, not what assert_clean returned
            "starred unpack of the guard call": "def write(ctx, out):\n    *text, = secrets.assert_clean(json.dumps(out), os.environ)\n",
            "nonlocal declaration":          "def outer():\n    text = 1\n    def write(ctx, out):\n        nonlocal text\n"
                                             "        text = secrets.assert_clean(json.dumps(out), os.environ)\n        p.write_text(text)\n",
        }
        for label, body in cases.items():
            if not body.rstrip().endswith("p.write_text(text)"):
                body += write
            with self.subTest(label):
                pkg = self._fixture("m.py", body); path = pkg / "m.py"
                lineno = next(i for i, l in enumerate(path.read_text().splitlines(), 1) if "p.write_text(" in l)
                self.assertIs(_guarded_write(path, lineno), False, label)
        # the control: the same head and write with no second binding is the one accepted shape
        pkg = self._fixture("m.py", head + write); path = pkg / "m.py"
        lineno = next(i for i, l in enumerate(path.read_text().splitlines(), 1) if "p.write_text(" in l)
        self.assertIs(_guarded_write(path, lineno), True)

    def test_a_tuple_rebinding_in_the_real_census_write_is_unexplained(self):
        # The report's own repro (eval-5 k8), against a COPY of the real census.py: the guard line
        # stays, a tuple assignment rebinds ``text`` between it and the write, and the write must be
        # unexplained. The edit is asserted to have applied, so a fixture whose hook line has moved
        # fails here rather than passing against the unmodified module.
        with tempfile.TemporaryDirectory() as tmp:
            pkg = Path(tmp) / "rabota"
            import shutil; shutil.copytree(PKG, pkg, ignore=shutil.ignore_patterns("__pycache__"))
            census = pkg / "census.py"; src = census.read_text()
            hook = 'json.dumps(out, indent=1, sort_keys=True) + "\\n", os.environ)\n'
            self.assertEqual(src.count(hook), 1, "census.py no longer has the guard line this fixture hooks; update the fixture")
            census.write_text(src.replace(hook, hook + "    text, _n = json.dumps(out), 1\n"))
            un = self._unexplained(pkg)
            self.assertEqual(len(un), 1, un); self.assertIn("census.py:", un[0]); self.assertIn("write_text(text)", un[0])

    def test_guarded_entries_name_a_real_line_and_the_scan_uses_them(self):
        # Both shipped entries must match a live line (stale exemptions are failures, as for
        # ALLOWED_LINES) and each excused line must satisfy the binding rule on the real package.
        _un, used_allowed, used_guarded = _classify(PKG)
        self.assertEqual(sorted(used_guarded), list(range(len(GUARDED_LINES))))
        self.assertEqual({mod for mod, _rx, _why in GUARDED_LINES}, {"census.py", "budget.py"})

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
