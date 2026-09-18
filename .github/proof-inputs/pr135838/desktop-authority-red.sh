set -euo pipefail
test "$BASE_SHA" = 1e254336b194c48f97342d8dd9024b8e59c14be2
pnpm test src/gateway/worker-environments/desktop-ssh-identity.test.ts
