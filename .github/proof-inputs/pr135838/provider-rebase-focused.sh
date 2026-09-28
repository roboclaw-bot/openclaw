#!/usr/bin/env bash
# Fixed hosted proof only. Never substitute tree composition for native history.
set -euo pipefail
old=c9921022529005400c41de6580dfabc99b7948dc
common=0edae198d278686e16426f7ad254d0341bd6e3d3
base=e433bfda89c486f98dfb03586dacd1e23b6f820b
replayed_tree=6e181a3dd95b720f9bfbac1b7804c6ce23df431b
tree=6e181a3dd95b720f9bfbac1b7804c6ce23df431b
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
test "$PATCH_SHA256" = 95cdf836dba0443825c54c568fc93ee8b1f197fcf825bc3bfdb98c8f3733df6e
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
    # Any native conflict not found by the inert preview fails closed.
    run_logged native-rebase env GIT_TRACE2_EVENT="$evidence/native-rebase.trace2.jsonl" git -c core.hooksPath=git-hooks -c user.name=roboclaw-bot -c user.email=309084314+roboclaw-bot@users.noreply.github.com rebase --merge --reapply-cherry-picks --empty=keep --onto "$base" "$common" "$old"
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
    run_logged provider-authority pnpm test \
      extensions/crabbox/src/crabbox-worker-allocation-authority.test.ts \
      extensions/crabbox/src/crabbox-worker-warm-image-authority.test.ts \
      extensions/crabbox/src/crabbox-worker-warm-image-sibling-admission.test.ts \
      extensions/crabbox/src/crabbox-worker-warm-image-store.test.ts \
      extensions/crabbox/src/crabbox-worker-project.test.ts \
      extensions/crabbox/src/crabbox-worker-node-enrollment.test.ts \
      src/gateway/worker-environments/provider-invocation.test.ts \
      src/gateway/worker-environments/provider-owner-revocation.test.ts \
      src/gateway/worker-environments/provider-allocation-cleanup.test.ts \
      --maxWorkers=1 --reporter=verbose
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
