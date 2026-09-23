#!/usr/bin/env python3
"""Scrub credentials out of Claude Code JSONL transcripts, in place.

The file-at-rest half of the pair whose other half is scripts/redact-secrets.sh.
That one is a pipe filter and stops a credential on its way to the terminal;
this one removes the ones already written to disk. Both exist because the
emission, not the rotation, is the loop worth optimising -- see
docs/TRANSCRIPT_SCRUB.md for the audit that produced this.

WHY THIS IS NOT ANOTHER RULE IN redact-secrets.sh
-------------------------------------------------
Its shape rules are reused verbatim below and need no change: a shape matches
anywhere, including inside a JSON string. Its NAME rules do not transfer, and
BOTH ends of them are wrong at rest, not just one:

    (^|[[:space:]])[A-Z][A-Z0-9_]*(TOKEN|SECRET|API_?KEY|...)=[^[:space:]]+

The leading boundary never matches, because a transcript's newlines are escaped
`\\n` INSIDE a JSON string and there is no real whitespace before the name. And
`[^[:space:]]+` would run to the next REAL space -- i.e. swallow the rest of the
JSON line -- so loosening the anchor alone would mangle transcripts rather than
redact them. A JSON string is a different value grammar, and it is what the name
rules here are written against: the value ends at a quote, a backslash,
whitespace or a separator. That is why this is a second tool and not a
seventeenth `-e`.

WHAT IT WILL NOT DO
-------------------
Scrubbing is a DISK measure. Transcripts are conversation context, so anything
captured has already left the host; for a credential that is still live,
rotation is the part that revokes. This stops the next reader of the disk, not
the last one.

SAFETY RULES, in order of how much they matter
----------------------------------------------
 1. Never prints a matched value. Output is counts and filenames.
 2. Refuses any file whose scrubbed form would not parse as JSON, per line.
    Replacements are `<REDACTED:kind>` -- no quote, no backslash -- so a value
    inside a JSON string stays a valid JSON string.
 3. Re-checks (size, mtime) immediately before writing. A transcript a live
    session is appending to WILL have changed, and is skipped rather than
    rewritten from a stale read -- that race silently drops whatever was
    appended between the read and the write. A scheduled run hits live sessions
    routinely, so skips are the normal case and are NOT a failure: the next run
    catches them, this being idempotent.
 4. Backs each file up, writes, re-reads, verifies, and shreds the backup at
    once. The backup is a second copy of the same secrets, so it must not
    outlive the verification -- and a backup that survives is reported, never
    ignored, which is why a failed `shred` is a non-zero exit.
 5. Skips its own session's transcript if SCRUB_SELF_TRANSCRIPT is set. Nothing
    sets it automatically, so it is inert unless you pass it; under systemd
    there is no session and rule 3 covers the live case.

ROOTS ARE DERIVED, NEVER HARDCODED
----------------------------------
`~/.claude/projects` is not the only transcript tree on a machine running these
dotfiles: `claude()` gives every session its own account dir, and each of those
has a `projects/` of its own. Measured 2026-09-23 on cilantro, 58 transcripts
lived under ~/.local/state/claude-account-dirs/*/projects and no audit had ever
looked at them. A hardcoded root is how the next one gets missed.

Usage:
    scrub-transcript-secrets.py [--dry-run]     survey; writes nothing
    scrub-transcript-secrets.py --apply         do it
    scrub-transcript-secrets.py --root DIR ...  override discovery (repeatable)
    scrub-transcript-secrets.py --json          machine-readable summary

Environment:
    SCRUB_TRANSCRIPT_ROOTS   colon-separated roots, overriding discovery
    SCRUB_TRANSCRIPT_STATE   state dir (default $XDG_STATE_HOME/scrub-transcript-secrets)
    SCRUB_SELF_TRANSCRIPT    substring; any path containing it is left alone
    SCRUB_TRANSCRIPT_PRE_WRITE_HOOK
                             TEST SEAM ONLY -- a command run between the read
                             and the re-stat, so the state table can exercise
                             rule 3. Never set this in production.

Exit codes:
    0  ran clean. Skips are included here: a skipped live session is the
       mechanism working, not a fault.
    1  a file was REFUSED, ROLLED BACK, or left with an unshredded backup.
    2  COULD NOT RUN -- no transcript root exists, `shred` is missing, or the
       state directory could not be created. Never a pass: "0 credentials
       found" and "I never looked" are the same sentence otherwise, and the
       second one reads as success.
"""

import argparse
import collections
import datetime
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import time

# Shape rules: lifted from scripts/redact-secrets.sh so the two agree. A shape
# finds a credential wherever it appears, including bare in prose, so these
# need no adaptation to a JSON string. Keep them in step with that file; the
# state table pins the spelling of each.
SHAPES = [
    (re.compile(rb"gh[pousr]_[A-Za-z0-9]{30,}"),    b"<REDACTED:github-token>"),
    (re.compile(rb"github_pat_[A-Za-z0-9_]{20,}"),  b"<REDACTED:github-pat>"),
    (re.compile(rb"sk-ant-[A-Za-z0-9_-]{20,}"),     b"<REDACTED:anthropic-key>"),
    (re.compile(rb"xox[baprse]-[A-Za-z0-9-]{10,}"), b"<REDACTED:slack-token>"),
    (re.compile(rb"glpat-[A-Za-z0-9_-]{20,}"),      b"<REDACTED:gitlab-pat>"),
    (re.compile(rb"ntn_[A-Za-z0-9]{40,}"),          b"<REDACTED:notion-token>"),
    (re.compile(rb"lin_api_[A-Za-z0-9]{30,}"),      b"<REDACTED:linear-key>"),
]

# Name rules: for credentials with no distinctive shape. Add to this list
# rather than inventing a shape for something that has none -- a shape invented
# to fit one value is a false-positive generator, and a redactor that mangles
# ordinary text is one somebody stops running.
NAMES = [
    "SONIOX_API_KEY", "LINEAR_API_KEY", "GH_TOKEN",
    "GITHUB_PERSONAL_ACCESS_TOKEN", "ANTHROPIC_API_KEY",
    "CLAUDE_CODE_MESSAGING_TOKEN", "ANTHROPIC_AUTH_TOKEN",
]
# The value ends at a quote, a backslash, whitespace or a separator: what a
# JSON string actually gives you, and the whole reason this file exists.
NAME_RE = {n: re.compile((n + r"=([^\"\s\\,;)}\]]{8,})").encode()) for n in NAMES}

# A value already redacted, or a shell variable, or documentation filler. Left
# alone so a second run is a byte-for-byte no-op and so `GH_TOKEN=$GH_TOKEN`
# stays readable.
PLACEHOLDER = re.compile(rb"^(<|\$|\*|x{3,}|your[-_]|REDACTED|\.\.\.|&lt;|%)", re.I)

BACKUP_SUFFIX = ".prescrub"


def die_cannot_run(msg: str) -> int:
    """Exit 2. Every caller of this is a precondition, checked before any write."""
    sys.stderr.write("scrub-transcript-secrets: %s\n" % msg)
    return 2


def discover_roots():
    """Every transcript tree on this machine, deduplicated and un-nested.

    Nesting matters: two roots where one contains the other would scan and
    rewrite the same file twice in one run, and the second pass would see the
    mtime the first pass just set and report a spurious live-session skip.
    """
    home = pathlib.Path.home()
    found = [home / ".claude" / "projects"]
    found += sorted((home / ".local" / "state" / "claude-account-dirs").glob("*/projects"))
    return found


def usable_roots(candidates):
    """Resolve, drop what does not exist, deduplicate, and drop nested roots."""
    resolved = []
    for c in candidates:
        p = pathlib.Path(c).expanduser()
        try:
            p = p.resolve()
        except OSError:
            continue
        if p.is_dir() and p not in resolved:
            resolved.append(p)
    out = []
    for p in sorted(resolved, key=lambda q: len(q.parts)):
        if any(q == p or q in p.parents for q in out):
            continue
        out.append(p)
    return out


def scrub(data: bytes):
    """Return the scrubbed bytes and a Counter keyed by credential kind.

    Never returns, logs or raises a matched value -- the counter keys are rule
    names, and that property is a row in the state table.
    """
    counts = collections.Counter()
    for rx, repl in SHAPES:
        data, k = rx.subn(repl, data)
        if k:
            counts[repl.decode().strip("<>").replace("REDACTED:", "")] += k
    for name, rx in NAME_RE.items():
        hits = 0

        def rep(m, _name=name):
            nonlocal hits
            if PLACEHOLDER.match(m.group(1)):
                return m.group(0)
            hits += 1
            return _name.encode() + b"=<REDACTED:by-name>"

        data = rx.sub(rep, data)
        if hits:
            counts[name] += hits
    return data, counts


def unparseable(data: bytes) -> int:
    """How many non-blank lines would not parse as JSON."""
    bad = 0
    for line in data.split(b"\n"):
        if not line.strip():
            continue
        try:
            json.loads(line)
        except Exception:
            bad += 1
    return bad


def display(p: pathlib.Path) -> str:
    """A path safe to print: never a value, and unambiguous across roots."""
    try:
        return "~/" + str(p.relative_to(pathlib.Path.home()))
    except ValueError:
        return str(p)


def shred(path: pathlib.Path) -> bool:
    """Remove a backup irrecoverably. True if it is gone afterwards."""
    subprocess.run(["shred", "-u", str(path)], check=False)
    if not path.exists():
        return True
    try:
        path.unlink()
    except OSError:
        pass
    return not path.exists()


def sweep_backups(roots, apply: bool):
    """Deal with backups an interrupted earlier run left behind.

    A surviving .prescrub is a second copy of the same credentials, sitting at
    0600 next to the file it was taken from. Reported always; removed only by
    an --apply run, because a dry run must write nothing under the roots.
    """
    left = []
    for root in roots:
        left += sorted(root.rglob("*" + BACKUP_SUFFIX))
    failed = 0
    for bak in left:
        if not apply:
            print("LEFTOVER BACKUP %s -- a second copy of the same secrets; "
                  "--apply shreds it" % display(bak))
            continue
        if shred(bak):
            print("shredded leftover backup %s" % display(bak))
        else:
            print("FAILED to shred leftover backup %s" % display(bak))
            failed += 1
    return len(left), failed


def write_log(state: pathlib.Path, line: str) -> None:
    try:
        with (state / "log").open("a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except OSError as exc:
        sys.stderr.write("scrub-transcript-secrets: could not append to the log: %s\n" % exc)


def run(roots, apply: bool, self_marker: str):
    total = collections.Counter()
    scanned = done = skipped = refused = shred_failed = 0
    now = time.time()

    files = []
    for root in roots:
        files += sorted(root.rglob("*.jsonl"))

    for p in files:
        if self_marker and self_marker in str(p):
            continue
        try:
            st0 = p.stat()
            data = p.read_bytes()
        except OSError as exc:
            print("SKIP (unreadable) %s: %s" % (display(p), exc))
            skipped += 1
            continue
        scanned += 1

        new, counts = scrub(data)
        if not counts:
            continue

        bad = unparseable(new)
        if bad:
            print("REFUSED %s: %d line(s) would not parse as JSON" % (display(p), bad))
            refused += 1
            continue

        if not apply:
            total.update(counts)
            done += 1
            fresh = "  <-- modified recently, may be a LIVE session" \
                if (now - st0.st_mtime) < 3600 else ""
            print("would scrub %s: %d replacement(s)%s"
                  % (display(p), sum(counts.values()), fresh))
            continue

        # Test seam, and the only one. Rule 3 guards a race that nothing can
        # provoke on purpose, and an untestable branch is an untested branch --
        # this repo's records say so in three places. The hook runs between the
        # read and the re-stat, which is exactly the window rule 3 exists for.
        hook = os.environ.get("SCRUB_TRANSCRIPT_PRE_WRITE_HOOK", "")
        if hook:
            subprocess.run(["sh", "-c", hook], check=False,
                           env=dict(os.environ, SCRUB_TRANSCRIPT_FILE=str(p)))

        try:
            st1 = p.stat()
        except OSError as exc:
            print("SKIP (vanished while reading) %s: %s" % (display(p), exc))
            skipped += 1
            continue
        if (st1.st_size, st1.st_mtime_ns) != (st0.st_size, st0.st_mtime_ns):
            print("SKIP (changed while reading -- live session) %s" % display(p))
            skipped += 1
            continue

        bak = p.with_name(p.name + BACKUP_SUFFIX)
        try:
            shutil.copy2(p, bak)
            bak.chmod(0o600)
            p.write_bytes(new)
        except OSError as exc:
            print("REFUSED %s: %s" % (display(p), exc))
            refused += 1
            if bak.exists() and not shred(bak):
                shred_failed += 1
            continue

        back = p.read_bytes()
        if back != new or unparseable(back):
            shutil.copy2(bak, p)
            print("ROLLED BACK %s: verification failed" % display(p))
            refused += 1
        else:
            total.update(counts)
            done += 1
        if not shred(bak):
            print("FAILED to shred %s -- it holds the same credentials" % display(bak))
            shred_failed += 1

    return {
        "scanned": scanned, "scrubbed": done, "skipped": skipped,
        "refused": refused, "shred_failed": shred_failed,
        "replacements": sum(total.values()), "by_kind": dict(total),
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--apply", action="store_true",
                    help="write the scrubbed files (default: survey only)")
    ap.add_argument("--dry-run", action="store_true",
                    help="survey only; the default, accepted for symmetry")
    ap.add_argument("--root", action="append", default=[], metavar="DIR",
                    help="a transcript root, overriding discovery (repeatable)")
    ap.add_argument("--json", action="store_true",
                    help="print the summary as one JSON object")
    args = ap.parse_args()

    if args.apply and args.dry_run:
        return die_cannot_run("--apply and --dry-run are mutually exclusive")
    apply = args.apply

    env_roots = os.environ.get("SCRUB_TRANSCRIPT_ROOTS", "")
    if args.root:
        asked, source = args.root, "--root"
    elif env_roots:
        asked, source = env_roots.split(":"), "SCRUB_TRANSCRIPT_ROOTS"
    else:
        asked, source = discover_roots(), "discovery"

    roots = usable_roots(asked)
    if not roots:
        return die_cannot_run(
            "no transcript root exists (%s: %s) -- refusing to report a clean "
            "sweep of nothing" % (source, ", ".join(str(a) for a in asked)))

    if apply and shutil.which("shred") is None:
        return die_cannot_run(
            "shred is not on PATH, and every backup this takes is a second copy "
            "of the same credentials -- refusing to write")

    state = pathlib.Path(os.environ.get(
        "SCRUB_TRANSCRIPT_STATE",
        os.path.join(os.environ.get("XDG_STATE_HOME",
                                    str(pathlib.Path.home() / ".local" / "state")),
                     "scrub-transcript-secrets")))
    try:
        state.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        return die_cannot_run("cannot create the state directory %s: %s" % (state, exc))

    for r in roots:
        print("root %s" % display(r))
    leftover, leftover_failed = sweep_backups(roots, apply)

    res = run(roots, apply, os.environ.get("SCRUB_SELF_TRANSCRIPT", ""))
    res["shred_failed"] += leftover_failed
    res["leftover_backups"] = leftover
    res["mode"] = "apply" if apply else "dry"
    res["roots"] = len(roots)

    # mode= is in the log line for the reason wt-gc-sweep.sh has it: a dry run
    # logging scrubbed=0 otherwise reads exactly like an apply that did nothing.
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    write_log(state, "%s mode=%s roots=%d scanned=%d scrubbed=%d replacements=%d "
                     "skipped=%d refused=%d shred_failed=%d"
              % (stamp, res["mode"], res["roots"], res["scanned"], res["scrubbed"],
                 res["replacements"], res["skipped"], res["refused"],
                 res["shred_failed"]))

    if args.json:
        print(json.dumps(res, sort_keys=True))
    else:
        print("\n%s: %d of %d transcript(s), %d replacement(s); skipped %d; "
              "refused/rolled back %d"
              % ("APPLIED" if apply else "DRY RUN", res["scrubbed"], res["scanned"],
                 res["replacements"], res["skipped"], res["refused"]))
        for k, v in sorted(res["by_kind"].items(), key=lambda kv: -kv[1]):
            print("    %-32s %d" % (k, v))
        if res["shred_failed"]:
            print("    %d backup(s) could not be shredded -- they hold the same "
                  "credentials" % res["shred_failed"])
        if not apply and res["scrubbed"]:
            print("\nRe-run with --apply to write.")

    return 1 if (res["refused"] or res["shred_failed"]) else 0


if __name__ == "__main__":
    sys.exit(main())
