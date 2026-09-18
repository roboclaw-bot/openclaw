set -euo pipefail
test "$SUITE" = provider-full
test "$BASE_SHA" = 1e254336b194c48f97342d8dd9024b8e59c14be2
test "$(git rev-parse HEAD^{tree})" = "$EXPECTED_TREE"
test ! -e extensions/crabbox/src/crabbox-worker-invocation-baseline.test.ts
pnpm test src/plugins/worker-provider-registry.test.ts src/plugin-sdk/worker-provider.contract.test.ts src/gateway/worker-environments/provider-provisioning.test.ts src/gateway/worker-environments/provider-provisioning-node.test.ts src/gateway/worker-environments/provider-provisioning.replay.test.ts src/gateway/worker-environments/provider-provisioning.shutdown-replay.test.ts src/gateway/worker-environments/provider-provisioning.cancellation.test.ts src/gateway/worker-environments/provider-project-preparation.test.ts src/gateway/worker-environments/provider-crabbox-runtime-preflight.test.ts src/gateway/worker-environments/service-prepare.test.ts src/gateway/worker-environments/device-provider.test.ts extensions/qa-lab/src/static-ssh-worker-provider.test.ts extensions/crabbox/src/crabbox-worker-provider.test.ts extensions/crabbox/src/crabbox-worker-project.test.ts extensions/crabbox/src/crabbox-worker-provision-cancellation.test.ts extensions/crabbox/src/crabbox-worker-provision-commands.test.ts extensions/crabbox/src/crabbox-worker-allocation-authority.test.ts extensions/crabbox/src/crabbox-worker-warm-image-allocation.test.ts extensions/crabbox/src/crabbox-worker-prepared-image.test.ts extensions/crabbox/index.test.ts test/plugins/crabbox-service-replacement.test.ts test/helpers/desktop-resize-real-fixture.test.ts
pnpm check:line-cap-ratchet --base 1e254336b194c48f97342d8dd9024b8e59c14be2
pnpm check:max-lines-ratchet --base 1e254336b194c48f97342d8dd9024b8e59c14be2
pnpm tsgo:core
pnpm tsgo:extensions
pnpm tsgo:core:test
pnpm tsgo:extensions:test
pnpm tsgo:test:root
pnpm plugin-sdk:check-exports
pnpm plugin-sdk:surface:check
pnpm plugin-sdk:api:diff --base 1e254336b194c48f97342d8dd9024b8e59c14be2 --head HEAD --summary .artifacts/provider-sdk-api.txt --json .artifacts/provider-sdk-api.json
pnpm build:plugin-sdk:strict-smoke
git diff --check 1e254336b194c48f97342d8dd9024b8e59c14be2 HEAD
git diff --name-only --diff-filter=ACMR -z "$BASE_SHA" HEAD -- '*.ts' '*.mts' '*.js' '*.mjs' > "$RUNNER_TEMP/lint-files"
mapfile -d '' -t lint < "$RUNNER_TEMP/lint-files"
test "${#lint[@]}" -gt 0
node scripts/run-oxlint.mjs --tsconfig config/tsconfig/oxlint.json "${lint[@]}"
git diff --name-only --diff-filter=ACMR -z "$BASE_SHA" HEAD > "$RUNNER_TEMP/changed-files"
mapfile -d '' -t changed < "$RUNNER_TEMP/changed-files"
test "${#changed[@]}" -gt 0
./node_modules/.bin/oxfmt --check "${changed[@]}"
test -s .artifacts/provider-sdk-api.json
test -s .artifacts/provider-sdk-api.txt
cp .artifacts/provider-sdk-api.json "$RUNNER_TEMP/candidate-sdk-api.json"
cp .artifacts/provider-sdk-api.txt "$RUNNER_TEMP/candidate-sdk-api.txt"
