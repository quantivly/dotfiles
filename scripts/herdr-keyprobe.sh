#!/usr/bin/env bash
#
# scripts/herdr-keyprobe.sh
# =========================
#
# Answer one question before any herdr keybinding is written: does this terminal
# actually speak the kitty keyboard protocol?
#
# herdr requests kitty progressive enhancement (flags 7) and binds chords like
# `ctrl+shift+e` on the assumption the terminal reports them as CSI-u escapes.
# Alacritty does speak it — but only the *application* asks for it, and nothing
# in a plain shell does. So this wrapper asks for it itself, dumps whatever the
# keyboard produces as raw hex, and drops the request again on the way out.
#
# Read the result against the table it prints:
#   - Positive   -> Tier 1 chords are safe; write them into config.toml.
#   - Negative A -> the protocol is not honoured; fall back to Alacritty
#                   `[keyboard.bindings]` `chars = "[<code>;<mod>u"` entries
#                   (the idiom already used for tmux in
#                   examples/alacritty.toml.template).
#   - Negative B -> not a protocol problem at all: an xkb layout-group toggle is
#                   eating one modifier of every Alt+Shift chord. Fixed by
#                   clearing xkb-options — see apply-gnome-settings.sh
#                   `apply_input_sources`.
#
# Usage:
#   ~/.dotfiles/scripts/herdr-keyprobe.sh
#
#   Run it in a PLAIN Alacritty window on the `us` layout. Not inside herdr and
#   not inside tmux: both are terminal emulators in their own right, they hold
#   their own kitty-protocol state, and either would answer for itself instead
#   of for Alacritty. The script refuses to start in one rather than lie to you.
#
#   Press the chords in the order the table lists, then Ctrl+C (or just wait out
#   the 90s timeout). Ctrl+G is NOT an exit here — the whole point of the probe
#   is that kitty mode turns Ctrl+G into `ESC[103;5u`, so the dumper's own exit
#   byte can never arrive.
#
# Requirements:
#   - python3, timeout (coreutils), stty
#
# Security:
#   - No secrets. Reads keystrokes from this terminal only, prints them, exits.
#

set -euo pipefail

readonly PROBE_TIMEOUT_S=90

if [[ -n "${HERDR_ENV:-}" || -n "${TMUX:-}" ]]; then
    cat >&2 <<'MSG'
herdr-keyprobe: refusing to run inside a multiplexer.

  HERDR_ENV / TMUX is set, so this pane is hosted by herdr or tmux. Both parse
  keys themselves and keep their own kitty-protocol state, so the hex you would
  see here is the multiplexer's re-encoding, not what Alacritty produces — the
  exact thing this probe exists to measure.

  Open a plain Alacritty window (us layout, no herdr, no tmux) and run it there.
MSG
    exit 1
fi

#######################################
# Restore the terminal no matter how we leave: pop the kitty-protocol flags we
# pushed, and undo raw mode. The dumper restores termios itself on a clean exit,
# but `timeout -s INT` and an operator Ctrl+C both land here too.
#######################################
cleanup() {
    printf '\e[<u'
    [[ -t 0 ]] && stty sane 2>/dev/null
    return 0
}

#######################################
# EXIT trap: restore the terminal, drop the scratch dir, preserve the status we
# were already leaving with.
#######################################
on_exit() {
    local rc=$?
    cleanup
    rm -rf "$workdir"
    exit "$rc"
}

workdir="$(mktemp -d)"
readonly workdir
trap on_exit EXIT
trap 'exit 130' INT TERM

#######################################
# The dumper. This is herdr's own scripts/capture_keys.py
# (https://github.com/herdrdev/herdr), vendored inline so the probe stays a
# single file that works without a herdr source checkout.
#
# Two deliberate changes from upstream:
#   - raw mode is applied only when stdin is a tty, so the script stays testable
#     by piping a synthetic escape sequence into it;
#   - SIGINT exits quietly instead of printing a KeyboardInterrupt traceback,
#     because SIGINT is how this probe is meant to end.
#######################################
cat > "$workdir/capture_keys.py" <<'PYEOF'
#!/usr/bin/env python3
"""Capture terminal key sequences in raw mode and print them as hex.

Vendored from herdr's scripts/capture_keys.py — https://github.com/herdrdev/herdr

Behavior:
- Switches stdin to raw mode (when stdin is a tty)
- Coalesces bytes until input goes idle for 20ms
- Prints each coalesced sequence as hex + escaped text
- Exits on EOF or SIGINT
"""

from __future__ import annotations

import select
import sys
import termios
import tty

IDLE_TIMEOUT_S = 0.020

# Ways out. Under kitty flags 7 the terminal no longer sends the legacy control
# bytes, so Ctrl+C arrives as `ESC[99;5u` (press) rather than 0x03 and never
# raises SIGINT in raw mode; recognise both encodings, plus Ctrl+G and a bare q.
# Note: on a non-Latin layout (il) Ctrl+C is reported with the layout's own
# codepoint (`ESC[1489;5u`) and is NOT recognised — switch to us, press q, or
# wait for the timeout.
EXIT_PREFIXES = (b"\x03", b"\x07", b"q", b"\x1b[99;5", b"\x1b[103;5", b"\x1b[113;1u", b"\x1b[113u")


def is_exit(data: bytes) -> bool:
    return any(data.startswith(p) for p in EXIT_PREFIXES)


def to_hex(data: bytes) -> str:
    return data.hex()


def escaped(data: bytes) -> str:
    parts: list[str] = []
    for byte in data:
        if byte == 0x1B:
            parts.append("\\x1b")
        elif byte == 0x7F:
            parts.append("\\x7f")
        elif byte == 0x0D:
            parts.append("\\r")
        elif byte == 0x0A:
            parts.append("\\n")
        elif byte == 0x09:
            parts.append("\\t")
        elif 0x20 <= byte <= 0x7E:
            parts.append(chr(byte))
        else:
            parts.append(f"\\x{byte:02x}")
    return "".join(parts)


def read_sequence() -> bytes:
    first = sys.stdin.buffer.read1(1)
    if not first:
        return b""

    chunks = [first]
    while True:
        ready, _, _ = select.select([sys.stdin], [], [], IDLE_TIMEOUT_S)
        if not ready:
            break
        chunk = sys.stdin.buffer.read1(1024)
        if not chunk:
            break
        chunks.append(chunk)
    return b"".join(chunks)


def main() -> int:
    fd = sys.stdin.fileno()
    interactive = sys.stdin.isatty()
    old = termios.tcgetattr(fd) if interactive else None

    # Raw mode also disables output post-processing (OPOST), so a bare "\n"
    # no longer implies a carriage return and lines would stair-step across the
    # screen. Emit explicit CRLF while interactive.
    eol = "\r\n" if interactive else "\n"

    if interactive:
        print("capture-keys: raw mode enabled", end=eol, file=sys.stderr)
        print("capture-keys: press Ctrl+C or q to quit", end=eol, file=sys.stderr)
    print("family\thex\tescaped", end=eol, file=sys.stdout)
    sys.stdout.flush()

    try:
        if interactive:
            tty.setraw(fd)
        while True:
            data = read_sequence()
            if not data:
                return 0
            print(f"captured\t{to_hex(data)}\t{escaped(data)}", end=eol, file=sys.stdout)
            sys.stdout.flush()
            if is_exit(data):
                return 0
    except KeyboardInterrupt:
        return 0
    finally:
        if old is not None:
            termios.tcsetattr(fd, termios.TCSADRAIN, old)


if __name__ == "__main__":
    raise SystemExit(main())
PYEOF

cat <<'TABLE'
herdr keyboard-protocol probe — Alacritty, kitty flags 7
========================================================

Press these in order. Each line shows what a terminal that honours the protocol
must produce. Anything else: match it against the two negative tables below.

  chord              expected          expected hex
  -----------------  ----------------  ------------------------
  ctrl+shift+e       ESC[101:69;6u     1b5b3130313a36393b3675
  ctrl+shift+w       ESC[119:87;6u     1b5b3131393a38373b3675
  ctrl+tab           ESC[9;5u          1b5b393b3575
  ctrl+shift+tab     ESC[9;6u          1b5b393b3675
  ctrl+1             ESC[49;5u         1b5b34393b3575
  ctrl+9             ESC[57;5u         1b5b35373b3575
  alt+j              ESC[106;3u        1b5b3130363b3375
  alt+1              ESC[49;3u         1b5b34393b3375
  ctrl+shift+left    ESC[1;6D          1b5b313b3644
  ctrl+alt+left      ESC[1;7D          1b5b313b3744
  f12                ESC[24~           1b5b32347e

  All eleven match -> Tier 1 confirmed; write the chords into config.toml.

Negative A — kitty mode not honoured (a protocol problem)
---------------------------------------------------------
The chord collapses to its legacy control byte: one byte, no CSI.

  ctrl+shift+e     -> 05          (bare ctrl+e)
  ctrl+shift+w     -> 17          (bare ctrl+w)
  ctrl+tab         -> 09          (bare tab)
  ctrl+1 / ctrl+9  -> 31 / 39     (the digits themselves)
  alt+j            -> 1b6a        (ESC-prefixed j)

  Any of these -> use the Alacritty `[keyboard.bindings]` `chars` fallback
  instead of relying on the terminal's own encoder.

Negative B — xkb layout-group toggle (NOT a protocol problem)
-------------------------------------------------------------
Now press:  alt+shift+right   then   ctrl+alt+shift+w

  alt+shift+right   -> ESC[1;2C (1b5b313b3243) or ESC[1;3C (1b5b313b3343),
                       i.e. shift-only or alt-only — one modifier short
  ctrl+alt+shift+w  -> a ...;6u / ...;7u form rather than the full ...;8u
  ...and the top-bar layout indicator flips us <-> il as you press.

  That signature is `xkb-options = ['grp:alt_shift_toggle']` making Alt+Shift
  the layout switch: whichever of Alt/Shift is pressed second emits
  ISO_Next_Group instead of its own modifier. Clear it with
  `gsettings set org.gnome.desktop.input-sources xkb-options "[]"`
  (persisted in apply-gnome-settings.sh); Super+Space keeps switching layouts.

Layout check — press these two once more with `il` active
---------------------------------------------------------
  ctrl+shift+e  must be UNCHANGED (il level 2 is Latin uppercase)
  alt+j         will show a Hebrew codepoint — unshifted letter chords are
                layout-dependent, which is why Tier 1 is the more robust family.

TABLE

printf 'Starting capture (%ss). Press q or Ctrl+C when done (on the us layout — under il the\nchord carries a Hebrew codepoint and is not recognised).\n\n' "$PROBE_TIMEOUT_S"

# Push kitty progressive enhancement, flags 7 (disambiguate escape codes, report
# event types, report alternate keys) — the same set herdr itself requests.
printf '\e[>7u'

# `--foreground` so the timeout applies to a process sharing this terminal, and
# `-s INT` so python leaves through its own KeyboardInterrupt path with termios
# restored. Timing out is a normal end to the run, not a failure.
timeout --foreground -s INT "$PROBE_TIMEOUT_S" python3 "$workdir/capture_keys.py" || true

printf '\nProbe finished. Compare the hex above against the table.\n'
