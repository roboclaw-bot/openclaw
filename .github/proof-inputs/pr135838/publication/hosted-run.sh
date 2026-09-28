#!/usr/bin/env bash
set -euo pipefail
: "${PUBLICATION_BINDING:?}" "${PUBLICATION_BUILD_RECEIPT:?}" "${PUBLICATION_CONTROLLER_ROOT:?}" "${CRABBOX_PROOF_BINARY:?}"
test -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}${NODE_AUTH_TOKEN:-}${NPM_TOKEN:-}"
exec python3 "$(dirname "$0")/controller.py" run
