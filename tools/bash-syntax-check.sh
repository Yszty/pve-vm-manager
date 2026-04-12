#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash -n "$ROOT/deploy-vm.sh"
for f in "$ROOT"/lib/*.sh; do
  bash -n "$f"
done
echo "bash -n: OK"
