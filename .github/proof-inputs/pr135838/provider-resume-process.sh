#!/usr/bin/env bash
set -euo pipefail
: "${RUNNER_TEMP:?}"
# EXIT records the outer status, including 124/137; never converts death to 0.
# 137 may mean watchdog KILL or another SIGKILL: do not invent a timedOut fact.
record_outer() {
  local status=$?
  trap - EXIT
  printf '{"exitStatus":%s,"proofMissing":%s}\n' "$status" "$([[ "$status" == 0 ]] && echo false || echo true)" > "$RUNNER_TEMP/publication-outer.json" || status=2
  exit "$status"
}
trap record_outer EXIT
test -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}${NODE_AUTH_TOKEN:-}${NPM_TOKEN:-}"
PUBLICATION_NATIVE_BUDGET=$(python3 "$RUNNER_TEMP/publication-inputs/host.py" budget)
[[ "$PUBLICATION_NATIVE_BUDGET" =~ ^[0-9]{4}$ ]]
(( PUBLICATION_NATIVE_BUDGET >= 1510 && PUBLICATION_NATIVE_BUDGET <= 1680 ))
export PUBLICATION_NATIVE_BUDGET
# Hard outer kill at budget+10, NOT TERM at budget+10 then ten MORE seconds.
# Exact descendants are joined by the unchanged same-VM always owner.
timeout --signal=KILL "$(( PUBLICATION_NATIVE_BUDGET + 10 ))s" bash "$RUNNER_TEMP/publication-inputs/hosted-run.sh"
