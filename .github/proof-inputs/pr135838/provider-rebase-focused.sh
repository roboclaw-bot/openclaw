#!/usr/bin/env bash
# Hosted continuation of public six-commit fd0; never replay or reproduce it.
set -euo pipefail
old=d247932b3075cf3a3975f64275e3eab9cd1d37d0
base=0edae198d278686e16426f7ad254d0341bd6e3d3
replayed_head=fd0b54a58f93b68a49eb07695705cd770ebb91b1
replayed_tree=ab1b49cd3e7f05a5253f5b12828c236384b9a671
tree='b1c1331382cae5f993b46cc0e1495e9ba60d690d'
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
test "$BASE_SHA" = "$replayed_head"
test "$EXPECTED_TREE" = "$tree"
test "$PATCH_ID" = provider-rebase-current
test "$PATCH_SHA256" = '22498b31782f4ef7155f3804bc931b6e68a0ae7801fe15552e5931a993d46fa9'
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
test -z "${GIT_INDEX_FILE:-}${GIT_OBJECT_DIRECTORY:-}${GIT_ALTERNATE_OBJECT_DIRECTORIES:-}${GIT_CONFIG_COUNT:-}${GIT_CONFIG_PARAMETERS:-}${GIT_DIR:-}${GIT_WORK_TREE:-}${GIT_AUTHOR_NAME:-}${GIT_AUTHOR_EMAIL:-}${GIT_AUTHOR_DATE:-}${GIT_COMMITTER_NAME:-}${GIT_COMMITTER_EMAIL:-}${GIT_COMMITTER_DATE:-}${GIT_ATTR_SOURCE:-}${GIT_ATTR_NOSYSTEM:-}"

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
  snapshot "$label-after"
  if [[ -f "$evidence/source-admitted.txt" ]]; then
    if ! assert_candidate; then
      printf 'Source changed at command boundary: %s\n' "$label" >&2
      exit 1
    fi
  fi
  if [[ -f "$evidence/committed-head.txt" ]]; then
    assert_commit || exit $?
  fi
  if (( last_tee != 0 )); then exit "$last_tee"; fi
  return "$last_native"
}
assert_no_operation() {
  local state
  # Git ort retains AUTO_MERGE as a result tree even after a successful pick.
  # Preserve that provenance in snapshots; it is not an active operation marker.
  for state in MERGE_HEAD MERGE_MODE MERGE_MSG MERGE_AUTOSTASH CHERRY_PICK_HEAD REVERT_HEAD REBASE_HEAD sequencer rebase-merge rebase-apply BISECT_START; do
    if [[ -e "$(git rev-parse --git-path "$state")" ]]; then
      printf 'Unexpected Git operation state: %s\n' "$state" >&2
      return 1
    fi
  done
}
assert_candidate() {
  assert_no_operation || return $?
  test "$(git write-tree)" = "$tree" || return $?
  git diff --quiet || return $?
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
# Each public commit must be one parent in the exact six-commit tree chain.
assert_public_history() {
  python3 - "$payload" "$1" <<'PY'
from pathlib import Path
import json,subprocess,base64,sys
m=json.loads(Path(sys.argv[1]).read_text()); head=sys.argv[2]
assert head==m['replayedHead']
def git(*a):return subprocess.check_output(['git',*a])
actual=git('rev-list','--reverse',m['newMain']+'..'+head).decode().splitlines()
assert len(actual)==len(m['steps'])==6, actual
parent=m['newMain']; result=[]
for sha,s in zip(actual,m['steps'],strict=True):
    raw=git('cat-file','commit',sha); assert raw==base64.b64decode(s['rawBase64'],validate=True)
    headers,msg=raw.split(bytes([10,10]),1)
    lines=headers.splitlines()
    parents=[x[7:].decode() for x in lines if x.startswith(b'parent ')]
    actual_tree=next(x[5:].decode() for x in lines if x.startswith(b'tree '))
    assert parents==[parent], (sha,parents,parent)
    assert sha==s['expectedActual'], (sha,s['expectedActual'])
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
  test "$(git rev-parse HEAD)" = "$(cat "$evidence/committed-head.txt")"
  test "$(git rev-parse HEAD^{tree})" = "$tree"
  test "$(git show -s --format=%P HEAD)" = "$(cat "$evidence/rebased-head.txt")"
  test "$(git show -s --format='%an <%ae>|%cn <%ce>' HEAD)" = 'roboclaw-bot <309084314+roboclaw-bot@users.noreply.github.com>|roboclaw-bot <309084314+roboclaw-bot@users.noreply.github.com>'
  git diff --quiet HEAD
  assert_public_history "$(cat "$evidence/rebased-head.txt")" > "$evidence/actual-replay-chain.json"
  test "$(git rev-list --count "$base..HEAD")" = 7
  test -z "$(git rev-list --merges "$base..HEAD")"
  git cat-file commit HEAD | python3 -c 'import sys; sys.stdout.buffer.write(sys.stdin.buffer.read().split(bytes([10,10]),1)[1])' > "$evidence/final-message.txt"
  cmp "$RUNNER_TEMP/commit-message.txt" "$evidence/final-message.txt"
}

case "$phase" in
  materialize)
    test "$(pwd -P)" = "$(realpath "$GITHUB_WORKSPACE")"
    test -d .git
    test "$(git rev-parse HEAD)" = "$replayed_head"
    test -z "$(git status --porcelain --untracked-files=all)"
    assert_no_operation
    # Reject custom semantics, do not disable them to force a desired outcome.
    status=0
    git config --name-only --get-regexp '^(attr\.tree$|merge\.|rebase\.|rerere\.|submodule\.|include|url\.|credential\.|http\..*extraheader|branch\..*\.mergeoptions$|pull\.(twohead|octopus)$|core\.(hookspath|attributesfile|fsmonitor|sparsecheckout|autocrlf|eol)$|commit\.|hook\.|hooks\.|i18n\.)' > "$evidence/custom-git-config.txt" || status=$?
    test "$status" -eq 1
    # Configured drivers are inert until an attribute selects one. Record only
    # names/origins/scopes; effective filter and merge admission belongs below.
    status=0
    git config --null --show-origin --show-scope --name-only --get-regexp '^filter\.' > "$evidence/configured-filter-metadata.nul" || status=$?
    test "$status" -eq 0 || test "$status" -eq 1
    printf '%s\n' "$status" > "$evidence/configured-filter-query.exit.txt"
    if (( status == 0 )); then
      test -s "$evidence/configured-filter-metadata.nul"
    else
      test ! -s "$evidence/configured-filter-metadata.nul"
    fi
    test ! -s "$(git rev-parse --git-path info/attributes)"
    test ! -L .git/hooks
    find .git/hooks -mindepth 1 -maxdepth 1 ! -name '*.sample' -print > "$evidence/active-hooks.txt"
    test ! -s "$evidence/active-hooks.txt"
    git --version > "$evidence/git-version.txt"
    test "$(cat "$evidence/git-version.txt")" = 'git version 2.55.0'
    python3 - "$payload" "$RUNNER_TEMP/post-rebase-repair.patch" <<'PY'
from pathlib import Path
import base64,hashlib,json,sys
r=json.loads(Path(sys.argv[1]).read_text())['repair']
assert set(r)=={'path','mode','sha256','bytes','base64'} and r['path']=='post-rebase-repair.patch' and r['mode']=='100644'
data=base64.b64decode(r['base64'],validate=True)
assert len(data)==r['bytes'] and hashlib.sha256(data).hexdigest()==r['sha256']=='ab6489032d4c91fa7a897ba4a159779b39bb9cf1b4170b7976ab19265ea07dab'
Path(sys.argv[2]).write_bytes(data)
PY
    # Exact public checkout already has all six objects and B prerequisites.
    git merge-base --is-ancestor "$base" "$replayed_head"
    python3 - "$payload" <<'PY'
from pathlib import Path
import json,sys
m=json.loads(Path(sys.argv[1]).read_text())
assert m['schema']==2 and m['mode']=='public-six-history-lint-continuation'
assert m['status']=='PARENT_REVIEWED_FORMAT_ADOPTED'
assert m['finalTree']=='b1c1331382cae5f993b46cc0e1495e9ba60d690d'
assert m['formatAdoption']['parentReviewedAndAdopted'] is True
assert m['replayedHead']=='fd0b54a58f93b68a49eb07695705cd770ebb91b1'
assert len(m['steps'])==6
PY
    assert_public_history "$replayed_head" > "$evidence/actual-replay-chain.json"
    # One union covers the base, all six public states, and future repair paths.
    # Every public state must retain the audited base attribute inventory;
    # the repair cannot change attributes.
    python3 - "$payload" "$evidence" "$RUNNER_TEMP/post-rebase-repair.patch" <<'PY'
from pathlib import Path
import json,subprocess,base64,sys
m=json.loads(Path(sys.argv[1]).read_text()); evidence=Path(sys.argv[2])
def git(*a):return subprocess.check_output(['git',*a])
def fields(data):
    assert not data or data.endswith(bytes([0])), 'unterminated NUL output'
    return data[:-1].split(bytes([0])) if data else []
def save(name,data):
    (evidence/name).write_bytes(data)
    return data
metadata=fields((evidence/'configured-filter-metadata.nul').read_bytes())
assert len(metadata)%3==0
for scope,origin,name in zip(metadata[::3],metadata[1::3],metadata[2::3],strict=True):
    assert scope and origin and name.startswith(b'filter.'), 'invalid filter metadata'
# This continuation never checks out or replays original pre-rebase commits.
# Their native custody is retained by the prior producer; verify every public
# source commit byte here and audit only states this operation can materialize.
refs=[m['newMain'],*[s['expectedActual'] for s in m['steps']]]
paths=set(); inventories={}
for ref in refs:
    entries=fields(save(ref+'.entries.nul',git('ls-tree','-r','-z',ref)))
    assert entries, ref
    inventory=[]
    for entry in entries:
        header,path=entry.split(bytes([9]),1)
        mode,kind,oid=header.split(b' ')
        assert mode!=b'160000', (ref,path,'submodule')
        assert path, ref
        paths.add(path)
        if path.rsplit(b'/',1)[-1]==b'.gitattributes':
            assert mode in (b'100644',b'100755') and kind==b'blob', (ref,path)
            inventory.append(entry)
    inventories[ref]=inventory
    save(ref+'.attribute-files.nul',b''.join(x+bytes([0]) for x in inventory))
    hooks=save(ref+'.hooks.txt',git('ls-tree','-r',ref,'git-hooks'))
    assert hooks==b'100755 blob 00d02f1353abd2745357b955c9c222977c833c24'+bytes([9])+b'git-hooks/pre-commit'+bytes([10]), ref
for s in m['steps']:
    assert inventories[s['expectedActual']]==inventories[m['newMain']], 'replayed attribute change'
# --numstat alone is inert. Git emits the new name (old for deletions);
# reverse also covers rename/copy source names, without parsing diff headers.
repair_paths=set()
for label,args in [('forward',[]),('reverse',['--reverse'])]:
    records=fields(save('repair-'+label+'.numstat.nul',git('apply','--numstat','-z',*args,sys.argv[3])))
    assert records, 'empty repair inventory'
    for record in records:
        added,deleted,path=record.split(bytes([9]),2)
        assert (added.isdigit() and deleted.isdigit()) or (added==deleted==b'-')
        assert path and path.rsplit(b'/',1)[-1]!=b'.gitattributes', 'repair changes attributes'
        repair_paths.add(path)
paths.update(repair_paths)
ordered=sorted(paths); assert ordered, 'empty attribute proof'
union=save('attribute-audit-paths.nul',b''.join(p+bytes([0]) for p in ordered))
expected={(p,a) for p in ordered for a in (b'filter',b'merge')}
for ref in refs:
    raw=subprocess.check_output(['git','check-attr','--source='+ref,'--stdin','-z','filter','merge'],input=union)
    triples=fields(save(ref+'.attributes.nul',raw))
    assert len(triples)==3*len(expected), (ref,'attribute cardinality')
    seen=set()
    for path,attr,value in zip(triples[::3],triples[1::3],triples[2::3],strict=True):
        pair=(path,attr)
        assert pair in expected and pair not in seen and value==b'unspecified', (ref,path,attr,value)
        seen.add(pair)
    assert seen==expected, (ref,'attribute pair coverage')
    # Named output renders the literal string "unspecified" like the sentinel.
    # --all omits only the real unspecified sentinel, so reject either attribute
    # here even if its configured string value happens to spell "unspecified".
    raw=subprocess.check_output(['git','check-attr','--source='+ref,'--stdin','-z','--all'],input=union)
    triples=fields(save(ref+'.all-attributes.nul',raw))
    assert len(triples)%3==0, (ref,'all-attribute cardinality')
    seen=set()
    for path,attr,value in zip(triples[::3],triples[1::3],triples[2::3],strict=True):
        assert path in paths and attr and (path,attr) not in seen
        assert attr not in (b'filter',b'merge'), (ref,path,attr,value)
        seen.add((path,attr))
(evidence/'attribute-admission.json').write_text(json.dumps({
    'refs':refs,'unionPaths':len(paths),'repairPaths':len(repair_paths),
    'pairsPerRef':len(expected),'configuredFilterEntries':len(metadata)//3,
    'historicalAttributeInventoriesUnchanged':True,'repairChangesAttributes':False,
    'filterAndMergeUnspecified':True,'literalUnspecifiedExcluded':True,
    'filterValuesRecorded':False,
},indent=2)+chr(10))
PY
    test -z "$(git for-each-ref refs/replace --format="%(refname)")"
    test ! -s .git/info/grafts
    test "$(git rev-parse --is-shallow-repository)" = false
    git ls-files --others --directory -z > "$evidence/untracked-before-rebase.nul"
    test ! -s "$evidence/untracked-before-rebase.nul"
    # Public six-commit source is already checked out; do not reconstruct it.
    assert_no_operation
    test "$(git rev-parse HEAD)" = "$replayed_head"
    test "$(git rev-parse HEAD^{tree})" = "$replayed_tree"
    git diff --quiet HEAD
    assert_public_history "$replayed_head" > "$evidence/actual-replay-chain.json"
    printf '%s\n' "$replayed_head" > "$evidence/rebased-head.txt"
    run_logged repair-check git apply --index --check "$RUNNER_TEMP/post-rebase-repair.patch"
    run_logged repair-apply git apply --index "$RUNNER_TEMP/post-rebase-repair.patch"
    assert_candidate
    git diff --cached --check
    printf '%s\n' "$tree" > "$evidence/source-admitted.txt"
    ;;
  before-setup|after-setup)
    assert_candidate
    test "$(git rev-parse HEAD)" = "$replayed_head"
    if [[ "$phase" == after-setup ]]; then
      test "$(node --version)" = v24.19.0
      test "$(pnpm --version)" = 12.5.0
    fi
    ;;
  format)
    assert_candidate
    test "$(git rev-parse HEAD)" = "$(cat "$evidence/rebased-head.txt")"
    git diff --cached --name-only --diff-filter=ACMR -z "$base" > "$evidence/format-paths.nul"
    mapfile -d '' -t files < "$evidence/format-paths.nul"
    test "${#files[@]}" -eq 53
    python3 - "$payload" "$evidence/format-paths.nul" <<'PY'
from pathlib import Path
import json,sys
m=json.loads(Path(sys.argv[1]).read_text())
actual=Path(sys.argv[2]).read_bytes().split(bytes([0]))
assert actual[-1]==b'' and [x.decode() for x in actual[:-1]]==m['changedPaths']
PY
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
fix(workers): repair warm-image lint and private test boundaries

Preserve native worker admission coverage through the existing private SQLite test facade; make capture skip returns explicit without changing behavior.

Co-authored-by: sallyom <11166065+sallyom@users.noreply.github.com>
Co-authored-by: vincentkoc <25068+vincentkoc@users.noreply.github.com>
MESSAGE
    run_logged normal-hook-commit env GIT_TRACE2_EVENT="$evidence/final-commit.trace2.jsonl" git -c core.hooksPath=git-hooks -c user.name=roboclaw-bot -c user.email=309084314+roboclaw-bot@users.noreply.github.com commit --file "$RUNNER_TEMP/commit-message.txt"
    git rev-parse HEAD > "$evidence/committed-head.txt"
    assert_commit
    # Trace records real pre-commit invocation; canonical source calls the formatter.
    python3 - "$evidence/final-commit.trace2.jsonl" <<'PY'
from pathlib import Path
import json,sys
trace=[json.loads(x) for x in Path(sys.argv[1]).read_text().splitlines() if x]
starts=[x for x in trace if x.get('event')=='child_start' and x.get('hook_name')=='pre-commit']
assert len(starts)==1
s=starts[0]
assert any(x.get('event')=='child_exit' and x.get('sid')==s['sid'] and x.get('child_id')==s['child_id'] and x.get('code')==0 for x in trace)
PY
    git show -s --format='%H%n%P%n%T%n%B' HEAD > "$evidence/final-commit.txt"
    # Capture C at its producer before any tests/types can fail. It is retained
    # history, not a passing candidate; later lanes must consume this exact C.
    run_logged committed-history-bundle git bundle create "$evidence/committed-candidate.bundle" "$base..HEAD"
    run_logged committed-history-verify git bundle verify "$evidence/committed-candidate.bundle"
    jq -n --arg commit "$(git rev-parse HEAD)" --arg parent "$replayed_head" --arg base "$base" --arg tree "$tree" \
      --arg bundle "$(sha256sum "$evidence/committed-candidate.bundle" | cut -d ' ' -f1)" \
      --arg controller "$GITHUB_SHA" --arg run "$GITHUB_RUN_ID" --arg attempt "$GITHUB_RUN_ATTEMPT" \
      '{commit:$commit,parent:$parent,base:$base,tree:$tree,bundleSha256:$bundle,controller:$controller,runId:$run,attempt:$attempt,normalHookCommit:true,runtimeValidation:"NOT YET ESTABLISHED",scope:"Exact seventh commit retained at producer; not verified-candidate proof"}' \
      > "$evidence/committed-candidate.json"
    ;;
  tests)
    assert_commit
    run_logged focused pnpm test extensions/crabbox/src/crabbox-worker-warm-image-authority.test.ts --maxWorkers=1 --reporter=verbose --reporter=./scripts/lib/vitest-resource-reporter.mts --logHeapUsage -t 'record allocation honors invocation closure at commit with a live physical signal'
    assert_commit
    run_logged retirement-custody pnpm test extensions/crabbox/src/crabbox-worker-warm-image-sibling-admission.test.ts --maxWorkers=1 --reporter=verbose --reporter=./scripts/lib/vitest-resource-reporter.mts --logHeapUsage -t 'settles confirmed single-catalog deletion'
    assert_commit
    run_logged capture-custody pnpm test extensions/crabbox/src/crabbox-worker-warm-image-sibling-admission.test.ts --maxWorkers=1 --reporter=verbose --reporter=./scripts/lib/vitest-resource-reporter.mts --logHeapUsage -t 'capture (recovery precedence|(dispatch|claim delivery) custody)'
    assert_commit
    run_logged post-publication-control pnpm test extensions/crabbox/src/crabbox-worker-warm-image-sibling-admission.test.ts --maxWorkers=1 --reporter=verbose --reporter=./scripts/lib/vitest-resource-reporter.mts --logHeapUsage -t 'keeps a live project capture successful when post-publication retirement settlement is refused'
    assert_commit
    run_logged authority52 pnpm test \
      extensions/crabbox/src/crabbox-worker-warm-image-authority.test.ts \
      extensions/crabbox/src/crabbox-worker-warm-image-sibling-admission.test.ts \
      extensions/crabbox/src/crabbox-worker-warm-image-store.test.ts --maxWorkers=1 --reporter=verbose --reporter=./scripts/lib/vitest-resource-reporter.mts --logHeapUsage
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
      extensions/crabbox/src/crabbox-worker-warm-image.test.ts --maxWorkers=1 --reporter=verbose --reporter=./scripts/lib/vitest-resource-reporter.mts --logHeapUsage
    assert_commit
    run_logged core-custody-siblings pnpm test \
      src/gateway/worker-environments/provider-invocation.test.ts \
      src/gateway/worker-environments/provider-allocation-cleanup.test.ts --maxWorkers=1 --reporter=verbose --reporter=./scripts/lib/vitest-resource-reporter.mts --logHeapUsage
    assert_commit
    run_logged extensions-types pnpm tsgo:extensions
    assert_commit
    # Native proof plus production types stays within this existing job budget.
    run_logged core-types pnpm tsgo:core
    assert_commit
    run_logged test-core-imports pnpm run lint:plugins:no-extension-test-core-imports
    assert_commit
    run_logged sdk-subpaths pnpm run lint:plugins:plugin-sdk-subpaths-exported
    assert_commit
    # No test-types ownership transfer: run the complete canonical boundary set.
    run_logged additional-boundaries node --import tsx scripts/run-additional-boundary-checks.mts
    assert_commit
    ;;
  export)
    assert_commit
    cp "$evidence/committed-candidate.bundle" "$RUNNER_TEMP/candidate.bundle"
    cmp "$evidence/committed-candidate.bundle" "$RUNNER_TEMP/candidate.bundle"
    test "$(sha256sum "$RUNNER_TEMP/candidate.bundle" | cut -d ' ' -f1)" = "$(jq -r .bundleSha256 "$evidence/committed-candidate.json")"
    run_logged bundle-verify git bundle verify "$RUNNER_TEMP/candidate.bundle"
    jq -n --arg commit "$(git rev-parse HEAD)" --arg parent "$(cat "$evidence/rebased-head.txt")"       --arg base "$base" --arg old "$old" --arg tree "$tree" --arg payload "$PATCH_SHA256"       --arg suite "$SUITE" --arg controller "$GITHUB_SHA" --arg run "$GITHUB_RUN_ID" --arg attempt "$GITHUB_RUN_ATTEMPT"       --arg bundle "$(sha256sum "$RUNNER_TEMP/candidate.bundle" | cut -d ' ' -f1)"       --slurpfile replay "$evidence/actual-replay-chain.json"       '{commit:$commit,parent:$parent,base:$base,oldHead:$old,tree:$tree,payloadSha256:$payload,suite:$suite,
        controller:$controller,runId:$run,attempt:$attempt,bundleSha256:$bundle,replay:$replay[0],
        scope:"public six-commit history plus ordinary seventh lint repair and native provider/production-type/boundary proof; full lint and plugin/root test types remain a separate same-commit gate; not build/SDK/updater/native PR CI",
        declaredValidationScope:{focusedAllocationCases:1,pairedRetirementCases:2,pairedCaptureCases:11,postPublicationControlCases:1,groupedAuthorityCases:52,pluginSiblingFiles:13,coreSiblingFiles:2},
        observedCounts:"Read native logs; declared counts are not observations",
        hookProof:"Normal seventh repair commit with canonical pre-commit; public six raw commits are unchanged"}' > "$RUNNER_TEMP/candidate.json"
    cp "$RUNNER_TEMP/candidate.json" "$evidence/candidate.json"
    ;;
  *) exit 2 ;;
esac
