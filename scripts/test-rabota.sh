#!/usr/bin/env bash
# Runs the rabota unit tests. Mirrors the other scripts/test-*.sh in this repo.
set -euo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
cd "$here/rabota"
python3 -m unittest discover -s tests -t . -v "$@"
