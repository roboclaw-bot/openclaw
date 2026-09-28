#!/usr/bin/env bash
set -euo pipefail
# Existing controller always() step; same VM and RUNNER_TEMP. Missing receipt is failure.
exec python3 "$(dirname "$0")/controller.py" always
