#!/usr/bin/env bash
# Writes ~/.config/rabota/env from the CURRENT shell's LINEAR_API_KEY without printing it.
# Run this yourself in a shell where the key is exported. Agents must not run it.
set -euo pipefail
name="LINEAR_API_KEY"
if [ -z "${!name:-}" ]; then echo "rabota-env-write: $name is not set in this shell" >&2; exit 3; fi
dir="$HOME/.config/rabota"; mkdir -p "$dir"; umask 077
printf '%s=%s\n' "$name" "${!name}" > "$dir/env.tmp" && mv "$dir/env.tmp" "$dir/env"
chmod 600 "$dir/env"
echo "rabota-env-write: wrote $dir/env ($name, ${#LINEAR_API_KEY} chars)"
