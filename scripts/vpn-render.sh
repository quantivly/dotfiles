#!/usr/bin/env bash
#
# scripts/vpn-render.sh
# =====================
#
# Render a VPN template to stdout — the SINGLE source of truth for __VPN_*__
# placeholder substitution (DO-692). Used by:
#   - vpn-setup    when installing systemd/vpn-failfast.service into /etc
#   - vpn-doctor   when comparing the live /etc copy against this checkout
#                  (drift check) — it must render EXACTLY like the install did,
#                  or the drift check reports a difference it created itself
#
# Why placeholders at all: a SYSTEM unit has no %h. `%h` is a USER-manager
# specifier, and in a system unit it does not expand to the invoking user's home
# — so an ExecStart written with it silently becomes a path that cannot exist.
# That failure has already been paid for once in this repo, in a different guise:
# scripts/herdr-unit-dropin.sh exists because an unresolved placeholder produced
# `ExecStart=/scripts/herdr-server-launch.sh`. Same rule applies here, and it is
# the reason for the leftover check below.
#
# Placeholder:
#   __VPN_DOTFILES__  → absolute path of the checkout installing the file
#
# Usage: vpn-render.sh <template-file>
# Test override: VPN_RENDER_DOTFILES

set -euo pipefail

tpl="${1:?usage: vpn-render.sh <template-file>}"
[[ -r "$tpl" ]] || { printf '%s: not readable\n' "$tpl" >&2; exit 1; }

# Resolved from THIS script's location, not from $PWD and not from a symlink:
# the answer must be the checkout that owns the template, whichever directory
# the operator happened to be standing in.
root="${VPN_RENDER_DOTFILES:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"

# A path with a space would be split by systemd on an unquoted value; the
# templates quote every use, and this refuses the one thing quoting cannot save
# — a path containing a double quote, which would terminate the quoted value and
# turn the rest of the line into arguments.
case "$root" in
  *'"'*) printf 'vpn-render: checkout path contains a double quote: %s\n' "$root" >&2; exit 1 ;;
esac

# Parameter expansion, not sed, so a replacement containing |, & or a backslash
# can never corrupt the output.
content="$(cat "$tpl")"
content="${content//__VPN_DOTFILES__/$root}"

# Refuse to emit a half-rendered file. A blanked placeholder is not a degraded
# result, it is a different one: `ExecStart=/scripts/vpn-failfast.sh` is a
# perfectly well-formed unit that can never start, and it would install silently
# and read as correct forever.
leftover="$(printf '%s\n' "$content" | grep -o '__VPN_[A-Z_]*__' | sort -u | tr '\n' ' ' || true)"
if [[ -n "${leftover// /}" ]]; then
  printf '%s: unresolved placeholder(s): %s\n' "$tpl" "${leftover% }" >&2
  exit 1
fi

printf '%s\n' "$content"
