#!/usr/bin/env bash
# Convenience wrapper around build.mjs.
# Usage:
#   ./build_poc.sh 2021-01-Sushi_Badger_Digg
#   ./build_poc.sh --jobs 4
#   HACKS_REGISTRY_DIR=/path/to/clone ./build_poc.sh <slug>
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export HACKS_REGISTRY_DIR="${HACKS_REGISTRY_DIR:-$(cd "$HERE/../.." && pwd)}"
cd "$HERE"
if [ ! -d node_modules ]; then
  echo "[build_poc.sh] npm install..."
  npm install
fi
exec node build.mjs "$@"
