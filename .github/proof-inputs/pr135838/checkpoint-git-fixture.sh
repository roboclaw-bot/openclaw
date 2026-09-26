set -euo pipefail
test "$BASE_SHA" = 9e323ad891f776e1645ed494866aa8bdefe8362c
test "$(git rev-parse HEAD^)" = "$BASE_SHA"
test "$(git rev-parse HEAD^{tree})" = "$EXPECTED_TREE"
file=src/gateway/worker-environments/session-repository-checkpoints.test.ts
test "$(git diff --name-only "$BASE_SHA" HEAD)" = "$file"
git diff --check "$BASE_SHA" HEAD
./node_modules/.bin/oxfmt --check "$file"
node scripts/run-oxlint.mjs --tsconfig config/tsconfig/oxlint.core.json "$file"
pnpm check:line-cap-ratchet --base "$BASE_SHA"
pnpm check:max-lines-ratchet --base "$BASE_SHA"
pnpm check:assertion-safety --base "$BASE_SHA"
pnpm check:env-var-count --base "$BASE_SHA"
pnpm test "$file"
node scripts/run-tsgo-core-test-shards.mjs --ci-graphs-json '["core-test-gateway-other"]' --concurrency 1
binary=$(mktemp "$RUNNER_TEMP/opengrep.XXXXXX")
trap 'rm -f "$binary"' EXIT
curl -fsSL --retry 4 --retry-all-errors --retry-delay 2 --connect-timeout 10 --max-time 300 -o "$binary" https://github.com/opengrep/opengrep/releases/download/v1.30.0/opengrep_manylinux_x86
printf '%s  %s
' 35779bdd72e92129c8df2a77f0c55e8c08356801ea92591ef32108d6b28d564c "$binary" | sha256sum --check
install_dir="$RUNNER_TEMP/openclaw-opengrep"
mkdir -p "$install_dir"
install -m 0755 "$binary" "$install_dir/opengrep"
export PATH="$install_dir:$PATH"
opengrep --version
# Match the complete PR change surface, not only this fixture follow-up.
OPENCLAW_OPENGREP_BASE_REF=76e32e92441321b2e564263bc385cc7f4cc8ecd7...HEAD scripts/run-opengrep.sh --changed --sarif --error
git diff --quiet HEAD
