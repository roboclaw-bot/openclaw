#!/usr/bin/env bash
# Fixed hosted proof only. Never substitute tree composition for native history.
set -euo pipefail
old=d247932b3075cf3a3975f64275e3eab9cd1d37d0
common=c0e6951d6f02d3eabd4bc13cf8e9fa9e77d290ac
base=0edae198d278686e16426f7ad254d0341bd6e3d3
replayed_tree=ebce62a4c472c28acc06d629403d6570eb9bbb61
tree=cdbaa9538bb44c651813b6bf777aec07883176d3
payload="$RUNNER_TEMP/rebase-payload.json"
evidence="$RUNNER_TEMP/pr159178-rebase"
phase="${1:-tests}"
mkdir -p "$evidence"
phase_started="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"

snapshot() {
  local state target="$evidence/$1"
  mkdir -p "$target"
  git rev-parse HEAD > "$target/HEAD.txt" 2>&1
  git status --porcelain=v1 --untracked-files=no > "$target/tracked-status.txt" 2>&1
  git diff --binary HEAD > "$target/tracked-diff.patch" 2>&1
  git ls-files --stage > "$target/index-entries.txt" 2>&1
  if git cat-file -e "$tree^{tree}" 2>/dev/null; then
    git diff --binary "$tree" > "$target/expected-tree-diff.patch" 2>&1
  fi
  jq -r '.sourceChecks[] | "\(.sha256)  \(.path)"' "$payload" > "$target/source-checks.sha256"
  check_status=0
  sha256sum --check "$target/source-checks.sha256" > "$target/source-checks.result.txt" 2>&1 || check_status=$?
  printf '%s\n' "$check_status" > "$target/source-checks.exit.txt"
  git ls-files --unmerged > "$target/unmerged-stages.txt" 2>&1
  for state in REBASE_HEAD ORIG_HEAD MERGE_HEAD CHERRY_PICK_HEAD AUTO_MERGE rebase-merge rebase-apply sequencer; do
    source="$(git rev-parse --git-path "$state")"
    if [[ -e "$source" ]]; then cp -R -- "$source" "$target/$state"; fi
  done
}
finish() {
  local status=$?
  trap - EXIT
  set +e
  snapshot "$phase-exit"
  jq -n --arg phase "$phase" --arg start "$phase_started" --arg end "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"     --argjson status "$status" '{phase:$phase,startedAt:$start,endedAt:$end,exitStatus:$status}' > "$evidence/$phase.phase.json"
  exit "$status"
}
trap finish EXIT

test "$SUITE" = provider-rebase-focused
test "$BASE_SHA" = "$old"
test "$EXPECTED_TREE" = "$tree"
test "$PATCH_ID" = provider-rebase-current
test "$PATCH_SHA256" = 4a2b158131f49538744f4e1398be0b9ce66a773a31f75b7bbe40b97cfc77702a
test "$(sha256sum "$payload" | cut -d ' ' -f1)" = "$PATCH_SHA256"
test "$(sha256sum "$0" | cut -d ' ' -f1)" = "$REBASE_RECIPE_SHA256"
test "$GITHUB_REPOSITORY" = roboclaw-bot/openclaw
test "$GITHUB_REF" = refs/heads/main
test "$GITHUB_EVENT_NAME" = workflow_dispatch
test "$GITHUB_SHA" = "$REBASE_WORKFLOW_SHA"
test "$REBASE_HOSTED" = github-hosted
test "$RUNNER_OS" = Linux
[[ "$GITHUB_RUN_ID" =~ ^[0-9]+$ && "$GITHUB_RUN_ATTEMPT" =~ ^[0-9]+$ ]]
test -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}${NODE_AUTH_TOKEN:-}${NPM_TOKEN:-}${NODE_OPTIONS:-}"
test -z "${GIT_INDEX_FILE:-}${GIT_OBJECT_DIRECTORY:-}${GIT_ALTERNATE_OBJECT_DIRECTORIES:-}${GIT_CONFIG_COUNT:-}${GIT_CONFIG_PARAMETERS:-}${GIT_DIR:-}${GIT_WORK_TREE:-}${GIT_AUTHOR_NAME:-}${GIT_AUTHOR_EMAIL:-}${GIT_AUTHOR_DATE:-}${GIT_COMMITTER_NAME:-}${GIT_COMMITTER_EMAIL:-}${GIT_COMMITTER_DATE:-}"

run_logged() {
  local label="$1" started ended
  shift
  printf '%q ' "$@" > "$evidence/$label.command.txt" || exit $?
  printf '\n' >> "$evidence/$label.command.txt" || exit $?
  started="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
  set +e
  /usr/bin/time -f 'wall_seconds=%e user_seconds=%U system_seconds=%S native_exit=%x'     -o "$evidence/$label.time.txt" "$@" 2>&1 | tee "$evidence/$label.log"
  codes=("${PIPESTATUS[@]}")
  set -e
  last_native="${codes[0]}"
  last_tee="${codes[1]}"
  ended="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
  jq -n --arg command "$label" --arg start "$started" --arg end "$ended"     --argjson native "$last_native" --argjson tee "$last_tee"     '{command:$command,startedAt:$start,endedAt:$end,nativeExitStatus:$native,teeExitStatus:$tee}'     > "$evidence/$label.result.json" || exit $?
  if (( last_tee != 0 )); then exit "$last_tee"; fi
  return "$last_native"
}
assert_no_operation() {
  local state
  for state in MERGE_HEAD MERGE_MODE MERGE_MSG MERGE_AUTOSTASH CHERRY_PICK_HEAD REVERT_HEAD REBASE_HEAD sequencer rebase-merge rebase-apply BISECT_START AUTO_MERGE; do
    test ! -e "$(git rev-parse --git-path "$state")"
  done
}
assert_candidate() {
  assert_no_operation
  test "$(git write-tree)" = "$tree"
  git diff --quiet
  python3 - "$payload" <<'PY'
from pathlib import Path
import json,hashlib,sys
for item in json.loads(Path(sys.argv[1]).read_text())['sourceChecks']:
    p=Path(item['path'])
    assert p.is_file() and not p.is_symlink(), item['path']
    assert hashlib.sha256(p.read_bytes()).hexdigest()==item['sha256'], item['path']
PY
}
# Compare raw original author (including date/timezone) and message bytes.
# Each actual commit must be one parent in the exact five-commit tree chain.
assert_replay() {
  python3 - "$payload" "$1" <<'PY'
from pathlib import Path
import json,subprocess,base64,sys
m=json.loads(Path(sys.argv[1]).read_text()); head=sys.argv[2]
def git(*a):return subprocess.check_output(['git',*a])
actual=git('rev-list','--reverse',m['newMain']+'..'+head).decode().splitlines()
assert len(actual)==len(m['steps'])==5, actual
parent=m['newMain']; result=[]
for sha,s in zip(actual,m['steps'],strict=True):
    raw=git('cat-file','commit',sha); headers,msg=raw.split(bytes([10,10]),1)
    lines=headers.splitlines()
    parents=[x[7:].decode() for x in lines if x.startswith(b'parent ')]
    actual_tree=next(x[5:].decode() for x in lines if x.startswith(b'tree '))
    assert parents==[parent], (sha,parents,parent)
    assert actual_tree==s['expectedRebasedTree'], (sha,actual_tree)
    assert next(x for x in lines if x.startswith(b'author '))==base64.b64decode(s['authorBase64'])
    assert msg==base64.b64decode(s['messageBase64']), sha
    result.append({'original':s['original'],'actual':sha,'parent':parent,'tree':actual_tree,'emptyOriginal':s['emptyOriginal'],'authorAndMessagePreserved':True})
    parent=sha
assert result[1]['tree']==result[2]['tree']
print(json.dumps(result,indent=2))
PY
}
assert_commit() {
  assert_candidate
  test "$(git rev-parse HEAD^{tree})" = "$tree"
  test "$(git show -s --format=%P HEAD)" = "$(cat "$evidence/rebased-head.txt")"
  test "$(git show -s --format='%an <%ae>|%cn <%ce>' HEAD)" = 'roboclaw-bot <309084314+roboclaw-bot@users.noreply.github.com>|roboclaw-bot <309084314+roboclaw-bot@users.noreply.github.com>'
  git diff --quiet HEAD
  assert_replay "$(cat "$evidence/rebased-head.txt")" > "$evidence/actual-replay-chain.json"
  test "$(git rev-list --count "$base..HEAD")" = 6
  test -z "$(git rev-list --merges "$base..HEAD")"
  git cat-file commit HEAD | python3 -c 'import sys; sys.stdout.buffer.write(sys.stdin.buffer.read().split(bytes([10,10]),1)[1])' > "$evidence/final-message.txt"
  cmp "$RUNNER_TEMP/commit-message.txt" "$evidence/final-message.txt"
}

case "$phase" in
  materialize)
    test "$(pwd -P)" = "$(realpath "$GITHUB_WORKSPACE")"
    test -d .git
    test "$(git rev-parse HEAD)" = "$old"
    test -z "$(git status --porcelain --untracked-files=all)"
    assert_no_operation
    # Reject custom semantics, do not disable them to force a desired outcome.
    status=0
    git config --name-only --get-regexp '^(filter\.|merge\.|rebase\.|rerere\.|submodule\.|include|url\.|credential\.|http\..*extraheader|branch\..*\.mergeoptions$|pull\.(twohead|octopus)$|core\.(hookspath|attributesfile|fsmonitor|sparsecheckout|autocrlf|eol)$|commit\.|hook\.|hooks\.|i18n\.)' > "$evidence/custom-git-config.txt" || status=$?
    test "$status" -eq 1
    test ! -s "$(git rev-parse --git-path info/attributes)"
    test ! -L .git/hooks
    find .git/hooks -mindepth 1 -maxdepth 1 ! -name '*.sample' -print > "$evidence/active-hooks.txt"
    test ! -s "$evidence/active-hooks.txt"
    git --version > "$evidence/git-version.txt"
    test "$(cat "$evidence/git-version.txt")" = 'git version 2.55.0'
    run_logged fetch-main git fetch --no-tags https://github.com/openclaw/openclaw.git "$base"
    test "$(git rev-parse FETCH_HEAD)" = "$base"
    test "$(git cat-file -t "$base")" = commit
    test "$(git merge-base --all "$base" "$old")" = "$common"
    python3 - "$payload" <<'PY'
from pathlib import Path
import json,subprocess,base64,sys
m=json.loads(Path(sys.argv[1]).read_text())
def git(*a):return subprocess.check_output(['git',*a])
assert git('rev-list','--reverse',m['oldBase']+'..'+m['oldHead']).decode().splitlines()==[s['original'] for s in m['steps']]
parent=m['oldBase']
for s in m['steps']:
    h,msg=git('cat-file','commit',s['original']).split(bytes([10,10]),1)
    assert [x[7:].decode() for x in h.splitlines() if x.startswith(b'parent ')]==[parent]
    assert next(x for x in h.splitlines() if x.startswith(b'author '))==base64.b64decode(s['authorBase64'])
    assert msg==base64.b64decode(s['messageBase64'])
    parent=s['original']
PY
    # Every historical replay tree is inspected, not just the endpoints.
    refs=("$base" "$common")
    mapfile -t originals < <(jq -r '.steps[].original' "$payload")
    refs+=("${originals[@]}")
    for ref in "${refs[@]}"; do
      git ls-tree -r "$ref" > "$evidence/$ref.entries.txt"
      if grep -q '^160000 ' "$evidence/$ref.entries.txt"; then exit 2; fi
      git ls-tree -r "$ref" git-hooks > "$evidence/$ref.hooks.txt"
      printf '100755 blob 00d02f1353abd2745357b955c9c222977c833c24\tgit-hooks/pre-commit\n' > "$evidence/expected-hooks.txt"
      cmp "$evidence/expected-hooks.txt" "$evidence/$ref.hooks.txt"
      git ls-tree -r --name-only -z "$ref" > "$evidence/$ref.paths.nul"
      git check-attr --source="$ref" --stdin -z filter merge < "$evidence/$ref.paths.nul" > "$evidence/$ref.attributes.nul"
      while IFS= read -r -d '' path && IFS= read -r -d '' attr && IFS= read -r -d '' value; do
        test "$value" = unspecified
      done < "$evidence/$ref.attributes.nul"
    done
    test -z "$(git for-each-ref refs/replace --format="%(refname)")"
    test ! -s .git/info/grafts
    test "$(git rev-parse --is-shallow-repository)" = false
    git ls-files --others --directory -z > "$evidence/untracked-before-rebase.nul"
    test ! -s "$evidence/untracked-before-rebase.nul"
    if run_logged native-rebase git -c core.hooksPath=git-hooks -c user.name=roboclaw-bot -c user.email=309084314+roboclaw-bot@users.noreply.github.com rebase --merge --reapply-cherry-picks --empty=keep --onto "$base" "$common" "$old"; then
      status=0
    else
      status=$?
    fi
    test "$status" -eq 1
    test "$last_native" -eq 1
    test "$last_tee" -eq 0
    snapshot first-conflict
    test "$(git rev-parse REBASE_HEAD)" = 8469e0c1353886c4266a5986a1f2be628f870b83
    test "$(git rev-parse HEAD)" = "$base"
    test "$(cat .git/rebase-merge/orig-head)" = "$old"
    test "$(cat .git/rebase-merge/onto)" = "$base"
    test ! -e .git/MERGE_HEAD
    jq -r '.resolutions[].path' "$payload" > "$evidence/expected-unmerged-paths.txt"
    git diff --name-only --diff-filter=U > "$evidence/unmerged-paths.txt"
    cmp "$evidence/expected-unmerged-paths.txt" "$evidence/unmerged-paths.txt"
    sha256sum .git/rebase-merge/orig-head .git/rebase-merge/onto .git/REBASE_HEAD > "$evidence/native-intent.sha256"
    # Only these three reviewed regular files are replaced. No archive extraction.
    python3 - "$payload" "$RUNNER_TEMP" <<'PY'
from pathlib import Path
import base64,hashlib,json,os,sys
m=json.loads(Path(sys.argv[1]).read_text())
expected=['extensions/crabbox/src/crabbox-worker-preflight.ts','extensions/crabbox/src/crabbox-worker-provider.ts','extensions/crabbox/src/crabbox-worker-provision-commands.ts']
assert [r['path'] for r in m['resolutions']]==expected
for r in m['resolutions']:
    assert set(r)=={'path','mode','sha256','bytes','base64'} and r['mode']=='100644'
    data=base64.b64decode(r['base64'],validate=True)
    assert len(data)==r['bytes'] and hashlib.sha256(data).hexdigest()==r['sha256']
    p=Path(r['path']); assert p.is_file() and not p.is_symlink()
    assert all(not ancestor.is_symlink() for ancestor in p.parents)
    p.write_bytes(data); p.chmod(0o644)
PY
    mapfile -t conflicts < "$evidence/expected-unmerged-paths.txt"
    git add -- "${conflicts[@]}"
    test -z "$(git ls-files --unmerged)"
    test "$(git write-tree)" = 1bc83624e99ed5e81cce3a05175bf2804f3c8068
    git diff --quiet
    sha256sum --check "$evidence/native-intent.sha256"
    # Native sequencer owns all commits/state. GIT_EDITOR only prevents a prompt.
    run_logged native-continue env GIT_EDITOR=: git -c core.hooksPath=git-hooks -c user.name=roboclaw-bot -c user.email=309084314+roboclaw-bot@users.noreply.github.com rebase --continue
    assert_no_operation
    test "$(git rev-parse HEAD^{tree})" = "$replayed_tree"
    git diff --quiet HEAD
    assert_replay HEAD > "$evidence/actual-replay-chain.json"
    git rev-parse HEAD > "$evidence/rebased-head.txt"
    python3 - "$payload" "$RUNNER_TEMP/post-rebase-repair.patch" <<'PY'
from pathlib import Path
import base64,hashlib,json,sys
r=json.loads(Path(sys.argv[1]).read_text())['repair']
assert set(r)=={'path','mode','sha256','bytes','base64'} and r['path']=='post-rebase-repair.patch' and r['mode']=='100644'
data=base64.b64decode(r['base64'],validate=True)
assert len(data)==r['bytes'] and hashlib.sha256(data).hexdigest()==r['sha256']=='a1e9c9a5f78bcfa53e0bccf38172f97652832c60b4cf6b3c6acf16e14891eb90'
Path(sys.argv[2]).write_bytes(data)
PY
    run_logged repair-check git apply --index --check "$RUNNER_TEMP/post-rebase-repair.patch"
    run_logged repair-apply git apply --index "$RUNNER_TEMP/post-rebase-repair.patch"
    assert_candidate
    git diff --cached --check
    ;;
  format)
    assert_candidate
    test "$(git rev-parse HEAD)" = "$(cat "$evidence/rebased-head.txt")"
    git diff --cached --name-only --diff-filter=ACMR -z "$base" > "$evidence/format-paths.nul"
    mapfile -d '' -t files < "$evidence/format-paths.nul"
    test "${#files[@]}" -gt 0
    run_logged format pnpm format:check "${files[@]}"
    assert_candidate
    ;;
  commit)
    assert_candidate
    test "$(git rev-parse HEAD)" = "$(cat "$evidence/rebased-head.txt")"
    test -x git-hooks/pre-commit
    test -x scripts/pre-commit/format-staged.sh
    test -f scripts/pre-commit/guard-staged-content.mjs
    test -z "$(git config --get hooks.blockedLiteralsFile || true)"
    hook_path="$(git config --get core.hooksPath || true)"
    test -z "$hook_path" || test "$hook_path" = git-hooks
    cat > "$RUNNER_TEMP/commit-message.txt" <<'MESSAGE'
fix(workers): retain warm-image custody through caller closure

Preserve physical settlement and cleanup after invocation closure on the rebased provider series.

Co-authored-by: sallyom <11166065+sallyom@users.noreply.github.com>
Co-authored-by: vincentkoc <25068+vincentkoc@users.noreply.github.com>
MESSAGE
    run_logged normal-hook-commit env GIT_TRACE2_EVENT="$evidence/final-commit.trace2.jsonl" git -c core.hooksPath=git-hooks -c user.name=roboclaw-bot -c user.email=309084314+roboclaw-bot@users.noreply.github.com commit --file "$RUNNER_TEMP/commit-message.txt"
    assert_commit
    # Trace records real pre-commit invocation; canonical source calls the formatter.
    jq -s -e 'any(.[]; .event == "child_start" and .hook_name == "pre-commit")' "$evidence/final-commit.trace2.jsonl"
    git show -s --format='%H%n%P%n%T%n%B' HEAD > "$evidence/final-commit.txt"
    ;;
  tests)
    assert_commit
    run_logged focused pnpm test extensions/crabbox/src/crabbox-worker-warm-image-authority.test.ts --maxWorkers=1 --reporter=verbose -t 'record allocation honors invocation closure at commit with a live physical signal'
    assert_commit
    run_logged retirement-custody pnpm test extensions/crabbox/src/crabbox-worker-warm-image-sibling-admission.test.ts --maxWorkers=1 --reporter=verbose -t 'settles confirmed single-catalog deletion'
    assert_commit
    run_logged capture-custody pnpm test extensions/crabbox/src/crabbox-worker-warm-image-sibling-admission.test.ts --maxWorkers=1 --reporter=verbose -t 'capture (recovery precedence|(dispatch|claim delivery) custody)'
    assert_commit
    run_logged authority51 pnpm test \
      extensions/crabbox/src/crabbox-worker-warm-image-authority.test.ts \
      extensions/crabbox/src/crabbox-worker-warm-image-sibling-admission.test.ts \
      extensions/crabbox/src/crabbox-worker-warm-image-store.test.ts --maxWorkers=1 --reporter=verbose
    assert_commit
    run_logged warm-provider-siblings pnpm test \
      extensions/crabbox/src/crabbox-worker-warm-image-allocation.test.ts \
      extensions/crabbox/src/crabbox-worker-warm-image-lifecycle.test.ts \
      extensions/crabbox/src/crabbox-worker-warm-image-maintenance.test.ts \
      extensions/crabbox/src/crabbox-worker-warm-image-retirement.test.ts \
      extensions/crabbox/src/crabbox-worker-prepared-image.test.ts \
      extensions/crabbox/src/crabbox-worker-allocation-authority.test.ts \
      extensions/crabbox/src/crabbox-worker-provider.test.ts \
      extensions/crabbox/src/crabbox-worker-project.test.ts \
      extensions/crabbox/src/crabbox-worker-provision-cancellation.test.ts \
      extensions/crabbox/src/crabbox-worker-read-budget.test.ts \
      extensions/crabbox/src/crabbox-worker-provision-commands.test.ts \
      extensions/crabbox/src/crabbox-worker-stop-lifetime.test.ts \
      extensions/crabbox/src/crabbox-worker-warm-image.test.ts --maxWorkers=1 --reporter=verbose
    assert_commit
    run_logged core-custody-siblings pnpm test \
      src/gateway/worker-environments/provider-invocation.test.ts \
      src/gateway/worker-environments/provider-allocation-cleanup.test.ts --maxWorkers=1 --reporter=verbose
    assert_commit
    run_logged extensions-types pnpm tsgo:extensions
    assert_commit
    # Last lane uses only the existing job budget; timeout/failure is not proof.
    run_logged core-types pnpm tsgo:core
    assert_commit
    ;;
  export)
    assert_commit
    run_logged bundle-create git bundle create "$RUNNER_TEMP/candidate.bundle" "$base..HEAD"
    run_logged bundle-verify git bundle verify "$RUNNER_TEMP/candidate.bundle"
    jq -n --arg commit "$(git rev-parse HEAD)" --arg parent "$(cat "$evidence/rebased-head.txt")"       --arg base "$base" --arg old "$old" --arg tree "$tree" --arg payload "$PATCH_SHA256"       --arg suite "$SUITE" --arg controller "$GITHUB_SHA" --arg run "$GITHUB_RUN_ID" --arg attempt "$GITHUB_RUN_ATTEMPT"       --arg bundle "$(sha256sum "$RUNNER_TEMP/candidate.bundle" | cut -d ' ' -f1)"       --slurpfile replay "$evidence/actual-replay-chain.json"       '{commit:$commit,parent:$parent,base:$base,oldHead:$old,tree:$tree,payloadSha256:$payload,suite:$suite,
        controller:$controller,runId:$run,attempt:$attempt,bundleSha256:$bundle,replay:$replay[0],
        scope:"native rebase plus focused provider proof; includes canonical plugin/core production types; not build/SDK/new-updater/native PR CI",
        declaredValidationScope:{focusedAllocationCases:1,pairedRetirementCases:2,pairedCaptureCases:11,groupedAuthorityCases:51,pluginSiblingFiles:13,coreSiblingFiles:2},
        observedCounts:"Read native logs; declared counts are not observations",
        hookProof:"Normal final repair commit with canonical pre-commit; native rebase is not per-replay pre-commit proof"}' > "$RUNNER_TEMP/candidate.json"
    cp "$RUNNER_TEMP/candidate.json" "$evidence/candidate.json"
    ;;
  *) exit 2 ;;
esac
