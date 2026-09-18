set -euo pipefail
test "$BASE_SHA" = 1e254336b194c48f97342d8dd9024b8e59c14be2
base=3e8b396a7dc833185c0fdba33efadef6826eeda7
pnpm test src/gateway/worker-environments/desktop-ssh-identity.test.ts src/gateway/worker-environments/bootstrap.test.ts src/gateway/worker-environments/identity.test.ts src/gateway/worker-environments/provider-ssh-identity.test.ts src/gateway/worker-environments/ssh.test.ts src/gateway/worker-environments/tunnel.test.ts src/gateway/worker-environments/provider-bootstrap.test.ts src/gateway/worker-environments/desktop-tunnel.test.ts
pnpm check:line-cap-ratchet --base "$base"
pnpm check:max-lines-ratchet --base "$base"
pnpm tsgo:core
changed=$(git diff --name-only "$base" HEAD | jq -Rsc 'split("\n")|map(select(length>0))')
node scripts/run-tsgo-core-test-shards.mjs --changed-paths-json "$changed"
mapfile -t typescript < <(git diff --name-only "$base" HEAD -- '*.ts')
node scripts/run-oxlint.mjs --tsconfig config/tsconfig/oxlint.core.json "${typescript[@]}"
pnpm build
mapfile -t changed_files < <(git diff --name-only "$base" HEAD)
./node_modules/.bin/oxfmt --check "${changed_files[@]}"
git diff --check "$base" HEAD
