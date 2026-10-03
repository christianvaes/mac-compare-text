#!/bin/zsh
# Compiles the diff engine with the unit tests and runs them, including the
# real-world fixture comparison.
set -euo pipefail
cd "$(dirname "$0")/.."
TMP=$(mktemp -d)
swiftc -O Sources/DiffEngine.swift tests/main.swift -o "$TMP/difftests"
"$TMP/difftests" tests/fixtures/ha-v1.yaml tests/fixtures/ha-v2.yaml
