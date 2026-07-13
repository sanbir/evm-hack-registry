#!/bin/bash
# Compatibility shim — harness lives in _shared/run-poc/
exec "$(cd "$(dirname "$0")" && pwd)/run-poc/run_poc.sh" "$@"
