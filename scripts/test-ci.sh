#!/usr/bin/env bash
set -euo pipefail

echo "=== TOOLCHAIN ==="
forge --version
cast --version || true

echo "=== CONFIG ==="
echo "FOUNDRY_PROFILE=${FOUNDRY_PROFILE:-}"
cat foundry.toml

echo "=== CLEAN ==="
rm -rf out cache

echo "=== FORMAT (CI PARITY) ==="
FOUNDRY_PROFILE=ci forge fmt --check

echo "=== BUILD (CI PARITY) ==="
FOUNDRY_PROFILE=ci forge build --sizes

echo "=== TEST (CI PARITY) ==="
FOUNDRY_PROFILE=ci forge test -vvv
