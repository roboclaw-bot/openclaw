#!/usr/bin/env bash
# Fixed hosted proof only. Never substitute tree composition for native history.
set -euo pipefail
old=5d116aa3f1e0d85f9408d95cce0640926a8d8c60
common=e433bfda89c486f98dfb03586dacd1e23b6f820b
base=aa298d3a515ca85dc0970aacda0403d67ec2a097
replayed_tree=5cd77ceafea320d20b9f43cdd62b0ab712b74115
tree=5cd77ceafea320d20b9f43cdd62b0ab712b74115
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
test "$PATCH_SHA256" = b85061574031cfe7acdc241a61708b30f76a1abeba5b1f4d7a2013d2fe5c1104
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
# Each actual commit must be one parent in the exact ten-commit tree chain.
assert_replay() {
  python3 - "$payload" "$1" <<'PY'
from pathlib import Path
import json,subprocess,base64,sys,os
m=json.loads(Path(sys.argv[1]).read_text()); head=sys.argv[2]
def git(*a):return subprocess.check_output(['git',*a])
actual=git('rev-list','--reverse',m['newMain']+'..'+head).decode().splitlines()
assert len(actual)==len(m['steps'])==10, actual
parent=m['newMain']; result=[]
for sha,s in zip(actual,m['steps'],strict=True):
    raw=git('cat-file','commit',sha); Path(os.environ['RUNNER_TEMP'],'pr159178-rebase','raw-'+sha+'.commit').write_bytes(raw); headers,msg=raw.split(bytes([10,10]),1)
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
  test "$(git rev-parse HEAD)" = "$(cat "$evidence/rebased-head.txt")"
  test "$(git rev-parse HEAD^{tree})" = "$tree"
  git diff --quiet HEAD
  assert_replay HEAD > "$evidence/history.json"
  test "$(git rev-list --count "$base..HEAD")" = 10
  test -z "$(git rev-list --merges "$base..HEAD")"
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
    run_logged fetch-main git fetch --no-tags https://github.com/openclaw/openclaw.git "$base"
    test "$(git rev-parse FETCH_HEAD)" = "$base"
    test "$(git cat-file -t "$base")" = commit
    test "$(git merge-base --all "$base" "$old")" = "$common"
    # One union covers old history and target-base paths before native replay.
    # Original commits cannot change attributes; all merged states
    # therefore use the target base's audited attribute inventory.
    python3 - "$payload" "$evidence" <<'PY'
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
assert git('rev-list','--reverse',m['oldBase']+'..'+m['oldHead']).decode().splitlines()==[s['original'] for s in m['steps']]
parent=m['oldBase']
for s in m['steps']:
    h,msg=git('cat-file','commit',s['original']).split(bytes([10,10]),1)
    assert [x[7:].decode() for x in h.splitlines() if x.startswith(b'parent ')]==[parent]
    assert next(x for x in h.splitlines() if x.startswith(b'author '))==base64.b64decode(s['authorBase64'])
    assert msg==base64.b64decode(s['messageBase64'])
    parent=s['original']
metadata=fields((evidence/'configured-filter-metadata.nul').read_bytes())
assert len(metadata)%3==0
for scope,origin,name in zip(metadata[::3],metadata[1::3],metadata[2::3],strict=True):
    assert scope and origin and name.startswith(b'filter.'), 'invalid filter metadata'
refs=[m['newMain'],m['oldBase'],*[s['original'] for s in m['steps']]]
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
    assert inventories[s['original']]==inventories[m['oldBase']], 'historical attribute change'
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
    'refs':refs,'unionPaths':len(paths),'repairPaths':0,
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
    # Native Git alone owns commits, authors, messages, empty commits and sequencer state.
    status=0
    run_logged native-rebase env GIT_TRACE2_EVENT="$evidence/native-rebase.trace2.jsonl" git -c core.hooksPath=git-hooks -c user.name=roboclaw-bot -c user.email=309084314+roboclaw-bot@users.noreply.github.com rebase --merge --reapply-cherry-picks --empty=keep --onto "$base" "$common" "$old" || status=$?
    mapfile -t conflict_steps < <(jq -r '.steps[] | select(.conflicts | length > 0) | .number' "$payload")
    for step in "${conflict_steps[@]}"; do
      test "$status" -eq 1
      test "$last_native" -eq 1
      test "$last_tee" -eq 0
      snapshot "conflict-$step"
      test "$(cat .git/rebase-merge/orig-head)" = "$old"
      test "$(cat .git/rebase-merge/onto)" = "$base"
      test ! -e .git/MERGE_HEAD
      python3 - "$payload" "$step" "$evidence" <<'PY'
from pathlib import Path
import base64,hashlib,json,subprocess,sys
m=json.loads(Path(sys.argv[1]).read_text()); n=int(sys.argv[2]); e=Path(sys.argv[3]); s=m['steps'][n-1]
def git(*a):return subprocess.check_output(['git',*a]).decode().strip()
assert s['number']==n and git('rev-parse','REBASE_HEAD')==s['original']
assert git('rev-parse','HEAD^{tree}')==s['inputTree']
assert git('diff','--name-only','--diff-filter=U').splitlines()==s['conflicts']
rs=[r for r in m['resolutions'] if r['step']==n]
assert sorted(r['path'] for r in rs if 'stages' in r)==s['conflicts']
for r in rs:
    p=Path(r['path']); assert not p.is_absolute() and '..' not in p.parts
    assert p.is_file() and not p.is_symlink() and all(not a.is_symlink() for a in p.parents)
    assert r['original']==s['original'] and r['mode']=='100644'
    if 'stages' in r:
        assert [git('rev-parse',':'+str(i)+':'+r['path']) for i in [1,2,3]]==r['stages']
    else:
        assert git('rev-parse',':'+r['path'])==r['beforeOid']
    data=base64.b64decode(r['base64'],validate=True)
    assert len(data)==r['bytes'] and hashlib.sha256(data).hexdigest()==r['sha256']
    p.write_bytes(data);p.chmod(0o644)
subprocess.run(['git','add','--',*[r['path'] for r in rs]],check=True)
assert not git('ls-files','--unmerged')
assert git('write-tree')==s['expectedRebasedTree']
subprocess.run(['git','diff','--quiet'],check=True)
(e/('resolution-'+str(n)+'.json')).write_text(json.dumps({'step':n,'original':s['original'],'tree':s['expectedRebasedTree'],'paths':[r['path'] for r in rs]},indent=2)+chr(10))
PY
      status=0
      run_logged "native-continue-$step" env GIT_EDITOR=: GIT_TRACE2_EVENT="$evidence/native-continue-$step.trace2.jsonl" git -c core.hooksPath=git-hooks -c user.name=roboclaw-bot -c user.email=309084314+roboclaw-bot@users.noreply.github.com rebase --continue || status=$?
    done
    test "$status" -eq 0
    test "$last_native" -eq 0
    test "$last_tee" -eq 0
    assert_no_operation
    test "$(git rev-parse HEAD^{tree})" = "$replayed_tree"
    git diff --quiet HEAD
    assert_replay HEAD > "$evidence/actual-replay-chain.json"
    git rev-parse HEAD > "$evidence/rebased-head.txt"
    cp "$evidence/actual-replay-chain.json" "$evidence/history.json"
    run_logged replay-history-bundle git bundle create "$evidence/replayed-history.bundle" "$base..HEAD"
    run_logged replay-history-verify git bundle verify "$evidence/replayed-history.bundle"
    assert_commit
    git diff --check "$base" HEAD
    ;;
  before-setup|after-setup)
    assert_commit
    if [[ "$phase" == after-setup ]]; then
      node --version > "$evidence/node-version.txt"
      pnpm --version > "$evidence/pnpm-version.txt"
      expected_pnpm="$(node -p 'JSON.parse(require("fs").readFileSync("package.json", "utf8")).packageManager.split("@")[1].split("+")[0]')"
      test "$(pnpm --version)" = "$expected_pnpm"
    fi
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
    # Pure rebase: no repair commit. Preserve ten authors/messages and empty C3.
    assert_commit
    test -x git-hooks/pre-commit
    run_logged normal-hooks git -c core.hooksPath=git-hooks hook run pre-commit
    assert_commit
    ;;
  tests)
    assert_commit
    # Reproduce the new-main retry composition defect on this exact candidate with
    # Product RED removes only two dispatch assertions; the separately hashed owner diagnostic overlay is restored with them.
    retry_red() (
      restore_retry_source() {
        git restore --source=HEAD --worktree -- extensions/crabbox/src/crabbox-worker-provision-commands.ts scripts/lib/failed-trailer.mts scripts/lib/vitest-report-capture.mts scripts/lib/vitest-worker-run.mts scripts/test-projects-run.mts
      }
      trap restore_retry_source EXIT
      test "$(sha256sum "$RUNNER_TEMP/outer-observation.json" | cut -c 1-64)" = 2534b94134b44f4063aa9d11490abd7f406325c9e42197d05fe73596bd6f8931
      test "${OPENCLAW_VITEST_WORKER_CACHE:-}" != 1
      python3 - "$payload" "$evidence" "$RUNNER_TEMP/outer-observation.json" <<'PY'
from pathlib import Path
import json,hashlib,base64,sys,subprocess
m=json.loads(Path(sys.argv[1]).read_text());r=m['retryRegression'];p=Path(r['path']);e=Path(sys.argv[2])
assert hashlib.sha256(p.read_bytes()).hexdigest()==r['candidateSha256']
data=base64.b64decode(r['redBase64'],validate=True)
assert hashlib.sha256(data).hexdigest()==r['redSha256']
p.write_bytes(data)
overlay=json.loads(Path(sys.argv[3]).read_text())
assert overlay['candidateTree']==m['finalTree']
paths=['scripts/lib/failed-trailer.mts','scripts/lib/vitest-report-capture.mts','scripts/lib/vitest-worker-run.mts','scripts/test-projects-run.mts']
assert [entry['path'] for entry in overlay['files']]==paths
for entry in overlay['files']:
    target=Path(entry['path'])
    assert target.is_file() and not target.is_symlink() and all(not p.is_symlink() for p in target.parents)
    original=subprocess.check_output(['git','show','HEAD:'+entry['path']])
    assert target.read_bytes()==original and hashlib.sha256(original).hexdigest()==entry['beforeSha256']
    data=base64.b64decode(entry['base64'],validate=True)
    assert len(data)==entry['bytes'] and hashlib.sha256(data).hexdigest()==entry['afterSha256']
    target.write_bytes(data)
assert subprocess.check_output(['git','diff','--name-only']).decode().splitlines()==sorted([r['path'],*paths])
(e/'retry-red.patch').write_bytes(subprocess.check_output(['git','diff','--binary','--full-index']))
PY
      status=0
      test ! -e "$evidence/coordinator-red.json"
      test ! -e "$evidence/coordinator-red.json.capture.json"
      mkdir "$evidence/outer-invocation"
      run_logged coordinator-red env PR159178_RED_OUTCOME_DIRECTORY="$evidence/outer-invocation" pnpm test extensions/crabbox/src/crabbox-worker-coordinator-retry.test.ts --maxWorkers=1 --testNamePattern 'closes .* backoff without resubmission when invocation authority expires' --reporter=json --reporter="$GITHUB_WORKSPACE/scripts/lib/vitest-report-capture.mts" --outputFile.json="$evidence/coordinator-red.json" || status=$?
      test "$status" -eq 1
      test "$last_native" -eq 1
      test "$last_tee" -eq 0
      python3 - "$evidence/coordinator-red.json" "$evidence/coordinator-red.json.capture.json" "$GITHUB_WORKSPACE" <<'PY'
from pathlib import Path
import json
import re
import sys

FILE = 'extensions/crabbox/src/crabbox-worker-coordinator-retry.test.ts'
SUITE = 'Crabbox worker coordinator retries'
PROJECT = 'extension-database-workers'
CONFIG = 'test/vitest/vitest.extension-database-workers.config.ts'
# Vitest 5.0.1 generateFileHash(FILE, PROJECT, no typecheck/merge label).
TASK_ID = '1706718556'
SELECTED = [
    'closes inspect backoff without resubmission when invocation authority expires',
    'closes run backoff without resubmission when invocation authority expires',
]
SKIPPED = [
    "retries node enrollment setup only before script output ''",
    "retries node enrollment setup only before script output 'CRABBOX_PHASE:openclaw-bootstrap-start'",
    "retries node runtime preparation only before script output ''",
    'submits profile setup until recovers',
    'submits profile setup until exhausted',
    'submits profile setup until script error',
    'cancels backoff without resubmitting setup or stopping the lease',
    'recovers during initial inspection',
    'recovers during readiness inspection',
    'recovers during lifecycle inspection',
    'does not retry warmup coordinator timeouts',
    'recovers heartbeat before warning',
]

def require(condition, code):
    if not condition:
        raise ValueError(code)

def validate_red(report, capture, root):
    # This is an admission check of native owner facts, never reconstruction of
    # completion from exit 1 or another later GREEN run.
    require(type(report) is dict and type(capture) is dict, 'native-report-shape')
    require(capture.get('ended') == {
        'reason': 'failed', 'unhandledErrors': 0, 'failedModules': 1, 'suiteErrors': 0,
    }, 'native-completion')
    require(capture.get('processTimedOut') is False, 'native-timeout')
    require(capture.get('ignoreUnhandledErrors') is False, 'native-errors-ignored')
    require(capture.get('passWithNoTests') is False, 'native-empty-admission')
    require(type(capture.get('pid')) is int and capture['pid'] > 0, 'native-process-identity')
    require(capture.get('root') == root, 'native-root')
    project = {
        'name': PROJECT, 'namePrefix': '', 'root': root,
        'config': root + '/' + CONFIG, 'pool': 'openclaw-forks',
    }
    require(capture.get('projects') == [project], 'native-project')
    require(capture.get('modules') == [{
        **project, 'file': root + '/' + FILE, 'taskId': TASK_ID,
    }], 'native-module')
    expected_counts = {
        'numFailedTests': 2, 'numPassedTests': 0, 'numPendingTests': 12,
        'numTodoTests': 0, 'numTotalTests': 14,
        'numFailedTestSuites': 2, 'numPassedTestSuites': 0,
        'numPendingTestSuites': 0, 'numTotalTestSuites': 2,
    }
    require(all(type(report.get(k)) is int and report[k] == v
                for k, v in expected_counts.items()), 'native-counts')
    require(report.get('success') is False, 'native-unexpected-success')
    files = report.get('testResults')
    require(type(files) is list and len(files) == 1, 'native-file-count')
    file = files[0]
    require(type(file) is dict and file.get('name') == root + '/' + FILE,
            'native-file')
    require(file.get('status') == 'failed' and file.get('message') == '',
            'native-file-error')
    cases = file.get('assertionResults')
    require(type(cases) is list and len(cases) == 14 and
            all(type(case) is dict for case in cases), 'native-case-count')
    require(sorted(case.get('title', '') for case in cases) == sorted(SELECTED + SKIPPED),
            'native-case-inventory')
    for case in cases:
        title = case['title']
        require(case.get('ancestorTitles') == [SUITE] and
                case.get('fullName') == SUITE + ' ' + title, 'native-case-identity')
        if title in SKIPPED:
            require(case.get('status') == 'skipped' and case.get('failureMessages') == [],
                    'native-skipped-error')
            continue
        require(case.get('status') == 'failed', 'native-selected-status')
        errors = case.get('failureMessages')
        require(type(errors) is list and len(errors) == 1 and type(errors[0]) is str,
                'native-selected-error-count')
        lines = errors[0].splitlines()
        require(bool(lines) and re.fullmatch(
            r'AssertionError: expected .+ to have a length of 1 but got 3', lines[0]
        ) is not None, 'native-selected-assertion')
        # Native JSON carries Error.stack, not formatted diffs/log output. Reject
        # additional non-frame diagnostics smuggled into the one assertion entry.
        require(all(re.fullmatch(r'\s+at .+', line) is not None for line in lines[1:]),
                'native-selected-extra-error')
    return {'admitted': True, 'selectedFailures': 2, 'skipped': 12, 'total': 14,
            'file': FILE, 'project': PROJECT, 'taskId': TASK_ID}

if __name__ == '__main__':
    result = validate_red(json.loads(Path(sys.argv[1]).read_text()),
                          json.loads(Path(sys.argv[2]).read_text()), sys.argv[3])
    print(json.dumps(result, sort_keys=True))
PY
      python3 - "$evidence/outer-invocation" "$GITHUB_WORKSPACE" "$evidence/coordinator-red.json.capture.json" <<'PY'
from pathlib import Path
import json
import re
import sys

FILE = 'extensions/crabbox/src/crabbox-worker-coordinator-retry.test.ts'
CONFIG = 'test/vitest/vitest.extension-database-workers.config.ts'

def require(condition, code):
    if not condition:
        raise ValueError(code)

def validate_outer(outer, root):
    require(type(outer) is dict and outer.get('schema') == 'pr159178.outer-invocation.v1', 'outer-schema')
    require(outer.get('phase') == 'exited' and outer.get('initialized') is True, 'outer-terminal')
    require(outer.get('cwd') == root and outer.get('entry') == root + '/scripts/test-projects.mts', 'outer-identity')
    require(type(outer.get('pid')) is int and outer['pid'] > 0, 'outer-pid')
    require(type(outer.get('invocation')) is str and re.fullmatch(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}', outer['invocation']), 'outer-invocation')
    for key in ['observationFailed','overflow','errorHandlersSeen','unsafeUnhandledMode','lateExitListener']:
        require(outer.get(key) is False, 'outer-' + key)
    require(type(outer.get('drains')) is int and outer['drains'] > 0, 'outer-natural-drain')
    require(outer.get('terminal') == {'code':1,'captureCallback':False}, 'outer-exit')
    for key in ['wrapperEntered','wrapperReturned','runnerEntered','runnerReturned','disposalStarted','disposalSettled','summaryReturned','signalsDetached']:
        require(type(outer.get(key)) is int and outer[key] == 1, 'outer-' + key)
    for key in ['wrapperErrors','runnerErrors','disposalErrors','fatalEvents']:
        require(type(outer.get(key)) is int and outer[key] == 0, 'outer-' + key)
    require(outer.get('wrapperTool') == 'test' and outer.get('workersPresent') is True, 'outer-owner')
    require(outer.get('plan') == {'count':1,'configs':[CONFIG],'targets':[FILE],'targetCount':1,'reports':False}, 'outer-plan')
    require(outer.get('preparation') == {'code':0}, 'outer-preparation')
    require(outer.get('commands') == [{'code':1,'exitedNormally':True,'noOutputTimedOut':False,'signal':None,'groupJoined':True}], 'outer-command')
    require(outer.get('finalization') == {'reportFailure':False,'signal':None,'hadSummary':True,'hadReports':False}, 'outer-finalization')
    workers = outer.get('workers')
    require(type(workers) is list and len(workers) == 1 and type(workers[0]) is dict, 'outer-worker-count')
    worker = workers[0]
    require(worker.get('id') == 0 and worker.get('parent') is False, 'outer-worker-identity')
    require(worker.get('borrows') == 1 and worker.get('disposalCalls') == 1, 'outer-worker-lifetime')
    require(type(worker.get('requests')) is int and 0 <= worker['requests'] <= worker['borrows'], 'outer-worker-requests')
    require(worker.get('requests') == worker.get('sends') == worker.get('sendCallbacks'), 'outer-worker-ipc-pending')
    for key in ['admissionErrors','sendErrors','disposalErrors']:
        require(type(worker.get(key)) is int and worker[key] == 0, 'outer-worker-' + key)
    require(worker.get('disposed') == {'id':0,'borrowerCount':1,'settledCount':1,'rejected':0,'compilerJoined':True,'resourcesReleased':True,'channelError':False}, 'outer-worker-settlement')
    return {'outerCompletedTestFailure':True,'pid':outer['pid'],'invocation':outer['invocation']}

def validate_native_close(capture):
    facts = capture.get('nativeInvocation')
    require(type(facts) is dict and facts.get('phase') == 'exited', 'native-close-terminal')
    for key in ['observationFailed','forcedExit','lateExitListener','lateErrorHandler']:
        require(facts.get(key) is False, 'native-close-' + key)
    for key in ['closeRejected','exitRejected','checkedUnhandled','finalUnhandled','fatalEvents','errorHandlersAtExit']:
        require(type(facts.get(key)) is int and facts[key] == 0, 'native-close-' + key)
    for prefix in ['close','exit']:
        calls = facts.get(prefix + 'Calls')
        require(type(calls) is int and calls >= 1 and facts.get(prefix + 'Settled') == calls,
                'native-close-' + prefix + '-settlement')
    require(type(facts.get('drains')) is int and facts['drains'] > 0 and facts.get('exitCode') == 1,
            'native-close-natural-exit')
    return True

if __name__ == '__main__':
    directory = Path(sys.argv[1])
    entries = list(directory.iterdir())
    require(len(entries) == 1 and entries[0].is_file() and not entries[0].is_symlink(), 'outer-record-count')
    require(entries[0].stat().st_size <= 16 * 1024, 'outer-record-bound')
    outer = json.loads(entries[0].read_text())
    result = validate_outer(outer, sys.argv[2])
    validate_native_close(json.loads(Path(sys.argv[3]).read_text()))
    require(entries[0].name == result['invocation'] + '.json', 'outer-record-identity')
    print(json.dumps(result, sort_keys=True))
PY
    )
    retry_red
    assert_commit
    run_logged provider-authority pnpm test \
      extensions/crabbox/src/crabbox-worker-allocation-authority.test.ts \
      extensions/crabbox/src/crabbox-worker-coordinator-retry.test.ts \
      extensions/crabbox/src/crabbox-worker-node-enrollment-diagnostics.test.ts \
      extensions/crabbox/src/crabbox-worker-warm-image-authority.test.ts \
      extensions/crabbox/src/crabbox-worker-warm-image-sibling-admission.test.ts \
      extensions/crabbox/src/crabbox-worker-warm-image-store.test.ts \
      extensions/crabbox/src/crabbox-worker-project.test.ts \
      extensions/crabbox/src/crabbox-worker-warm-image.test.ts \
      extensions/crabbox/src/crabbox-worker-node-enrollment.test.ts \
      src/gateway/worker-environments/provider-invocation.test.ts \
      src/gateway/worker-environments/provider-owner-revocation.test.ts \
      src/gateway/worker-environments/provider-allocation-cleanup.test.ts \
      --maxWorkers=1 --reporter=verbose --reporter=json --outputFile="$evidence/provider-tests.json"
    assert_commit
    run_logged extensions-types pnpm tsgo:extensions
    assert_commit
    run_logged core-types pnpm tsgo:core
    assert_commit
    run_logged plugin-test-types pnpm tsgo:extensions:test
    assert_commit
    ;;
  export)
    assert_commit
    run_logged bundle-create git bundle create "$RUNNER_TEMP/candidate.bundle" "$base..HEAD"
    run_logged bundle-verify git bundle verify "$RUNNER_TEMP/candidate.bundle"
    jq -n --arg commit "$(git rev-parse HEAD)" --arg parent "$(git rev-parse HEAD^)" \
      --arg base "$base" --arg old "$old" --arg tree "$tree" --arg payload "$PATCH_SHA256" \
      --arg suite "$SUITE" --arg controller "$GITHUB_SHA" --arg run "$GITHUB_RUN_ID" --arg attempt "$GITHUB_RUN_ATTEMPT" \
      --arg bundle "$(sha256sum "$RUNNER_TEMP/candidate.bundle" | cut -d ' ' -f1)" \
      --slurpfile replay "$evidence/history.json" \
      '{commit:$commit,parent:$parent,base:$base,oldHead:$old,tree:$tree,payloadSha256:$payload,suite:$suite,controller:$controller,runId:$run,attempt:$attempt,bundleSha256:$bundle,replay:$replay[0],scope:"Native ten-commit rebase, canonical format/hook, selected provider and overlap regressions, core/plugin production types and plugin test types; native process/build and PR CI separate",hookProof:"Native rebase with canonical hooks configured; clean-result canonical pre-commit invoked separately; no per-replayed-commit pre-commit claim"}' > "$RUNNER_TEMP/candidate.json"
    cp "$RUNNER_TEMP/candidate.json" "$evidence/candidate.json"
    ;;
  *) exit 2 ;;
esac
