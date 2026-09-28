#!/usr/bin/env bash
# Existing bounded normal-commit route, rebound to the public nine-commit head.
set -euo pipefail
phase="${1:-tests}"
evidence="$RUNNER_TEMP/pr159178-same-commit"
lineage=0edae198d278686e16426f7ad254d0341bd6e3d3
file=extensions/crabbox/src/crabbox-worker-warm-image-authority.test.ts
mkdir -p "$evidence"
test "$SUITE" = provider-routing-repair
test "$BASE_SHA" = e0a53eaa04e450cf9c287e2f8ae1f687f3afdf23
test "$EXPECTED_TREE" = e84e634a10fa84314b04119bd44d3a4a233a2999
test "$PATCH_ID" = provider-routing-repair-20260927
test "$PATCH_SHA256" = 298c200e081b400b07197fa4dd061ea40aa43cf44dd69b2b19a596251f58a0c1
test "$GITHUB_REPOSITORY" = roboclaw-bot/openclaw
test "$GITHUB_EVENT_NAME" = workflow_dispatch
test "$GITHUB_REF" = refs/heads/main
test "$GITHUB_SHA" = "$REBASE_WORKFLOW_SHA"
test "$GITHUB_RUN_ATTEMPT" = 1
test "$SHADOW_HOSTED" = github-hosted
test "$RUNNER_OS" = Linux
test "$RUNNER_ARCH" = X64
# No alternate pools, timeouts, author dates, hooks, or toolchain injection.
test -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}${NODE_AUTH_TOKEN:-}${NPM_TOKEN:-}${NODE_OPTIONS:-}"
test -z "${GIT_AUTHOR_DATE:-}${GIT_COMMITTER_DATE:-}${GIT_INDEX_FILE:-}${GIT_OBJECT_DIRECTORY:-}${GIT_ALTERNATE_OBJECT_DIRECTORIES:-}"
test -z "${OPENCLAW_OXLINT_SHARDS_SERIAL:-}${OPENCLAW_OXLINT_SHARD_CONCURRENCY:-}${OPENCLAW_OXLINT_SHARD_TIMEOUT_MS:-}${OPENCLAW_LOCAL_CHECK_MODE:-}"
test "$(node --version)" = v24.19.0
test "$(pnpm --version)" = 12.5.0

assert_source() {
  test "$(git write-tree)" = "$EXPECTED_TREE"
  git diff --quiet
  git diff --cached --check
  test "$(sha256sum "$file" | cut -d ' ' -f1)" = 91ebf8214d0d00a3c85777a1be731a85afb5326541091b5b660043d26f8302b1
  test -z "$(git ls-files --unmerged)"
  test -z "$(git for-each-ref refs/replace --format='%(refname)')"
  test "$(git rev-parse --is-shallow-repository)" = false
  test ! -s "$(git rev-parse --git-path info/grafts)"
  for state in REBASE_HEAD MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply sequencer; do
    test ! -e "$(git rev-parse --git-path "$state")"
  done
}
assert_commit() {
  assert_source
  test "$(git show -s --format=%P HEAD)" = "$BASE_SHA"
  test "$(git rev-parse HEAD^{tree})" = "$EXPECTED_TREE"
  git diff --quiet HEAD
  test "$(git diff --name-only "$BASE_SHA" HEAD)" = "$file"
  test "$(git rev-list --count "$lineage..HEAD")" = 10
  test "$(git rev-parse HEAD)" = "$(cat "$evidence/committed-head.txt")"
}
run_logged() {
  local name="$1"; shift
  printf '%q ' "$@" > "$evidence/$name.command.txt"
  printf '\n' >> "$evidence/$name.command.txt"
  set +e
  /usr/bin/time -f 'wall_seconds=%e native_exit=%x' -o "$evidence/$name.time.txt" "$@" 2>&1 | tee "$evidence/$name.log"
  local result=("${PIPESTATUS[@]}")
  set -e
  jq -n --arg name "$name" --arg commit "$(git rev-parse HEAD)" --argjson code "${result[0]}" --argjson capture "${result[1]}" '{name:$name,commit:$commit,nativeExit:$code,captureExit:$capture}' > "$evidence/$name.result.json"
  test "${result[1]}" -eq 0
  return "${result[0]}"
}

case "$phase" in
  before-commit)
    assert_source
    test "$(git rev-parse HEAD)" = "$BASE_SHA"
    test "$(git diff --cached --name-only)" = "$file"
    test -x git-hooks/pre-commit
    test -x scripts/pre-commit/format-staged.sh
    test -f scripts/pre-commit/guard-staged-content.mjs
    test -z "$(git config --get hooks.blockedLiteralsFile || true)"
    hook_path="$(git config --get core.hooksPath || true)"
    test -z "$hook_path" || test "$hook_path" = git-hooks
    test "$GIT_AUTHOR_NAME" = roboclaw-bot
    test "$GIT_AUTHOR_EMAIL" = 309084314+roboclaw-bot@users.noreply.github.com
    test "$GIT_COMMITTER_NAME" = "$GIT_AUTHOR_NAME"
    test "$GIT_COMMITTER_EMAIL" = "$GIT_AUTHOR_EMAIL"
    git ls-remote https://github.com/openclaw/openclaw.git refs/pull/159178/head > "$evidence/public-head-before-commit.txt"
    printf '%s\trefs/pull/159178/head\n' "$BASE_SHA" > "$evidence/expected-public-head.txt"
    cmp "$evidence/expected-public-head.txt" "$evidence/public-head-before-commit.txt"
    # Check, never adopt formatter output: the normal hook must be a byte no-op.
    run_logged format-before-commit pnpm format:check "$file"
    assert_source
    ;;
  retain-commit)
    # Retain the actual new object and full genuine ancestry BEFORE any native tests.
    git rev-parse HEAD > "$evidence/committed-head.txt"
    git bundle create "$evidence/committed-candidate.bundle" "$lineage..HEAD"
    git bundle verify "$evidence/committed-candidate.bundle" > "$evidence/bundle-verify.txt" 2>&1
    jq -n --arg commit "$(git rev-parse HEAD)" --arg parent "$BASE_SHA" --arg base "$lineage" --arg tree "$(git rev-parse HEAD^{tree})" --arg patch "$PATCH_SHA256" --arg controller "$GITHUB_SHA" --arg run "$GITHUB_RUN_ID" --arg bundle "$(sha256sum "$evidence/committed-candidate.bundle" | cut -d ' ' -f1)" '{commit:$commit,parent:$parent,base:$base,tree:$tree,patchSha256:$patch,controller:$controller,runId:$run,bundleSha256:$bundle,validation:"NOT YET ESTABLISHED",scope:"Retained actual normal-hook commit; not passing proof"}' > "$evidence/committed-candidate.json"
    python3 - "$lineage" "$BASE_SHA" "$evidence" <<'PY'
from pathlib import Path
import hashlib,json,subprocess,sys
e=Path(sys.argv[3]);rows=[]
commits=subprocess.check_output(['git','rev-list','--reverse',sys.argv[1]+'..HEAD']).decode().splitlines()
for commit in commits:
    raw=subprocess.check_output(['git','cat-file','commit',commit])
    (e/('raw-'+commit+'.commit')).write_bytes(raw)
    assert hashlib.sha1(b'commit '+str(len(raw)).encode()+b'\0'+raw).hexdigest()==commit
    rows.append({'commit':commit,'rawSha256':hashlib.sha256(raw).hexdigest()})
(e/'history.json').write_text(json.dumps(rows,indent=2)+'\n')
assert len(commits)==10 and commits[-2]==sys.argv[2]
# The public head pins all original raw objects/messages, including empty third.
assert subprocess.check_output(['git','rev-parse',commits[2]+'^{tree}'])==subprocess.check_output(['git','rev-parse',commits[1]+'^{tree}'])
raw=(e/('raw-'+commits[-1]+'.commit')).read_bytes()
message=(Path(__import__('os').environ['RUNNER_TEMP'])/'commit-message.txt').read_bytes()
assert raw.split(b'\n\n',1)[1]==message
for role in (b'author',b'committer'):
    assert any(x.startswith(role+b' roboclaw-bot <309084314+roboclaw-bot@users.noreply.github.com> ') for x in raw.split(b'\n\n',1)[0].splitlines())
PY
    # Retention precedes admission: a changed hook tree stays a visible failure.
    assert_commit
    python3 - "$evidence/final-commit.trace2.jsonl" <<'PY'
from pathlib import Path
import json,sys
trace=[json.loads(x) for x in Path(sys.argv[1]).read_text().splitlines() if x]
starts=[x for x in trace if x.get('event')=='child_start' and x.get('hook_name')=='pre-commit']
assert len(starts)==1
s=starts[0]
assert any(x.get('event')=='child_exit' and x.get('sid')==s['sid'] and x.get('child_id')==s['child_id'] and x.get('code')==0 for x in trace)
PY
    ;;
  tests)
    assert_commit
    git diff --name-only --diff-filter=ACMR -z "$lineage" HEAD > "$evidence/format-paths.nul"
    mapfile -d '' -t files < "$evidence/format-paths.nul"
    test "${#files[@]}" -eq 56
    run_logged format pnpm format:check "${files[@]}"
    assert_commit
    run_logged full-lint pnpm lint
    assert_commit
    # Complete file, all 23 cases: no name filter, custom pool, retries or timeout.
    run_logged authority-full pnpm test "$file" --reporter=verbose
    assert_commit
    run_logged plugin-test-types pnpm tsgo:extensions:test
    assert_commit
    printf '%s\n' 'full format + pnpm lint + complete authority file + plugin test types passed' > "$evidence/native-proof-passed.txt"
    ;;
  export)
    assert_commit
    test -s "$evidence/native-proof-passed.txt"
    cp "$evidence/committed-candidate.bundle" "$RUNNER_TEMP/candidate.bundle"
    jq --arg suite "$SUITE" '. + {suite:$suite,validation:"PASSED SCOPED NATIVE PROOF",scope:"Formatting 56 paths, canonical full pnpm lint, entire authority test file, plugin test types; not P2/runtime/publish-ready or remaining public CI attribution"}' "$evidence/committed-candidate.json" > "$RUNNER_TEMP/candidate.json"
    ;;
  *) exit 2 ;;
esac
