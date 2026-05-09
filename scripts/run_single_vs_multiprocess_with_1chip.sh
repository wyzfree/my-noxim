#!/bin/bash
# Wrapper: fair single-process vs multi-process benchmark
# with single-chip baseline included by default.
#
# Default chip configs keep total PE fixed at 1024:
#   1 chip : 32x32
#   4 chips: 16x16
#   16 chips: 8x8
#
# Usage:
#   bash scripts/run_single_vs_multiprocess_with_1chip.sh
#   bash scripts/run_single_vs_multiprocess_with_1chip.sh --repeats 2 --sim 8000
#
# Notes:
#   - You can override defaults by passing the same option again, e.g.:
#     --chip-configs "1:256:256,4:128:128,16:64:64"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

exec bash "$ROOT_DIR/scripts/run_single_vs_multiprocess_fair.sh" \
  --chip-configs "1:32:32,4:16:16,16:8:8" \
  --skip-multi-when-1chip \
  "$@"
