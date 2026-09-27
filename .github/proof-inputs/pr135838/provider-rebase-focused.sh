#!/usr/bin/env bash
# Hosted continuation of the settled native five-commit history; never replay it.
set -euo pipefail
old=d247932b3075cf3a3975f64275e3eab9cd1d37d0
common=c0e6951d6f02d3eabd4bc13cf8e9fa9e77d290ac
base=0edae198d278686e16426f7ad254d0341bd6e3d3
replayed_head=7365e3003e1c6ab9e372fc5b1fe673f82c18389e
replayed_tree=ebce62a4c472c28acc06d629403d6570eb9bbb61
tree='ab1b49cd3e7f05a5253f5b12828c236384b9a671'
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
test "$PATCH_SHA256" = '5b43132a7decae69a1a3983a4cfd56fe02f52dfa165de252261d3afd6a0c33a7'
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
# Each actual commit must be one parent in the exact five-commit tree chain.
assert_replay() {
  python3 - "$payload" "$1" <<'PY'
from pathlib import Path
import json,subprocess,base64,sys
m=json.loads(Path(sys.argv[1]).read_text()); head=sys.argv[2]
assert head==m['replayedHead']
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
assert len(data)==r['bytes'] and hashlib.sha256(data).hexdigest()==r['sha256']=='2c3e083b6e639b0c5632b2550f5d1b383ffe45e1130094a51e53cf9ced99dad8'
Path(sys.argv[2]).write_bytes(data)
PY
    run_logged fetch-main git fetch --no-tags https://github.com/openclaw/openclaw.git "$base"
    test "$(git rev-parse FETCH_HEAD)" = "$base"
    test "$(git cat-file -t "$base")" = commit
    test "$(git merge-base --all "$base" "$old")" = "$common"
    python3 - "$payload" "$evidence" <<'PY'
from pathlib import Path
import base64,hashlib,json,sys
m=json.loads(Path(sys.argv[1]).read_text()); e=Path(sys.argv[2])
assert m['schema']==2 and m['mode']=='retained-native-history-continuation'
assert m['status']=='PARENT_REVIEWED_FORMAT_ADOPTED'
assert m['finalTree']=='ab1b49cd3e7f05a5253f5b12828c236384b9a671'
assert m['formatAdoption']['parentReviewedAndAdopted'] is True
c=m['nativeCustody']
assert c['repository']=='roboclaw-bot/openclaw' and c['runId']==36329006184 and c['attempt']==1
assert c['artifactId']==10934549851 and c['artifactDigest']=='sha256:e20a1ed2fdd82486fa2e54806279c673cc45dc2d9be2cffbcdbc900d658759de'
assert c['controller']=='7abdc079306c4595170616f274c44c149982ce95'
expected=['replayed-history.bundle','replay-provenance.json','native-rebase.command.txt','native-rebase.result.json','native-rebase.log','native-continue.command.txt','native-continue.result.json','native-continue.log','replay-history-bundle.result.json','replay-history-verify.result.json','controller-identity.txt','run.json']
assert [x['path'] for x in m['retained']]==expected
r=e/'retained'; r.mkdir(exist_ok=False)
for x in m['retained']:
    assert set(x)=={'path','mode','sha256','bytes','base64'} and x['mode']=='100644'
    data=base64.b64decode(x['base64'],validate=True)
    assert len(data)==x['bytes'] and hashlib.sha256(data).hexdigest()==x['sha256']
    (r/x['path']).write_bytes(data)
bundle=(r/'replayed-history.bundle').read_bytes()
assert len(bundle)==27646 and hashlib.sha256(bundle).hexdigest()=='192ddc3033ade962b2d6084c65d41a2b01aa9c1789f2347d62fb6771e7859767'
header=bundle.split(bytes([10,10]),1)[0].splitlines()
assert len(header)==3 and header[0]==b'# v2 git bundle'
assert header[1].split(b' ',1)[0]==('-'+m['newMain']).encode()
assert header[2]==(m['replayedHead']+' HEAD').encode()
(e/'bundle-header.txt').write_bytes(bytes([10]).join(header)+bytes([10]))
p=json.loads((r/'replay-provenance.json').read_text())
assert (p['head'],p['tree'],p['base'],p['bundleSha256'])==(m['replayedHead'],m['rebasedTree'],m['newMain'],c['bundleSha256'])
for label,status in [('native-rebase',1),('native-continue',0),('replay-history-bundle',0),('replay-history-verify',0)]:
    result=json.loads((r/(label+'.result.json')).read_text())
    assert result['command']==label and result['nativeExitStatus']==status and result['teeExitStatus']==0
run=json.loads((r/'run.json').read_text())
assert run['runId']=='36329006184' and run['attempt']=='1' and run['controller']==c['controller']
(e/'retained-custody.json').write_text(json.dumps(c,indent=2)+chr(10))
PY
    # Native verify checks prerequisite connectivity; unbundle imports objects,
    # not newly created history. No reference/sequence state is manufactured.
    run_logged retained-bundle-verify git bundle verify "$evidence/retained/replayed-history.bundle"
    run_logged retained-bundle-import git bundle unbundle "$evidence/retained/replayed-history.bundle"
    assert_replay "$replayed_head" > "$evidence/actual-replay-chain.json"
    python3 - "$evidence" <<'PY'
from pathlib import Path
import json,sys
p=Path(sys.argv[1]); assert json.loads((p/'actual-replay-chain.json').read_text())==json.loads((p/'retained/replay-provenance.json').read_text())['replay']
PY
    # One union covers old, base, replay and future repair paths at every source.
    # Original commits and repair cannot change attributes; all merged states
    # therefore use the target base's audited attribute inventory.
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
refs=[m['newMain'],m['oldBase'],*[s['original'] for s in m['steps']],*[s['expectedActual'] for s in m['steps']]]
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
    # The native five-commit result is settled. Check out exactly that object.
    run_logged checkout-retained-history git checkout --detach "$replayed_head"
    assert_no_operation
    test "$(git rev-parse HEAD)" = "$replayed_head"
    test "$(git rev-parse HEAD^{tree})" = "$replayed_tree"
    git diff --quiet HEAD
    assert_replay "$replayed_head" > "$evidence/actual-replay-chain.json"
    printf '%s\n' "$replayed_head" > "$evidence/rebased-head.txt"
    run_logged repair-check git apply --index --check "$RUNNER_TEMP/post-rebase-repair.patch"
    run_logged repair-apply git apply --index "$RUNNER_TEMP/post-rebase-repair.patch"
    assert_candidate
    git diff --cached --check
    printf '%s\n' "$tree" > "$evidence/source-admitted.txt"
    ;;
  format)
    assert_candidate
    test "$(git rev-parse HEAD)" = "$(cat "$evidence/rebased-head.txt")"
    git diff --cached --name-only --diff-filter=ACMR -z "$base" > "$evidence/format-paths.nul"
    mapfile -d '' -t files < "$evidence/format-paths.nul"
    test "${#files[@]}" -eq 50
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
fix(workers): retain warm-image custody through caller closure

Preserve physical settlement and cleanup after invocation closure on the rebased provider series.

Co-authored-by: sallyom <11166065+sallyom@users.noreply.github.com>
Co-authored-by: vincentkoc <25068+vincentkoc@users.noreply.github.com>
MESSAGE
    run_logged normal-hook-commit env GIT_TRACE2_EVENT="$evidence/final-commit.trace2.jsonl" git -c core.hooksPath=git-hooks -c user.name=roboclaw-bot -c user.email=309084314+roboclaw-bot@users.noreply.github.com commit --file "$RUNNER_TEMP/commit-message.txt"
    git rev-parse HEAD > "$evidence/committed-head.txt"
    assert_commit
    # Trace records real pre-commit invocation; canonical source calls the formatter.
    jq -s -e 'any(.[]; .event == "child_start" and .hook_name == "pre-commit")' "$evidence/final-commit.trace2.jsonl"
    git show -s --format='%H%n%P%n%T%n%B' HEAD > "$evidence/final-commit.txt"
    # Capture C at its producer before any tests/types can fail. It is retained
    # history, not a passing candidate; later lanes must consume this exact C.
    run_logged committed-history-bundle git bundle create "$evidence/committed-candidate.bundle" "$base..HEAD"
    run_logged committed-history-verify git bundle verify "$evidence/committed-candidate.bundle"
    jq -n --arg commit "$(git rev-parse HEAD)" --arg parent "$replayed_head" --arg base "$base" --arg tree "$tree" \
      --arg bundle "$(sha256sum "$evidence/committed-candidate.bundle" | cut -d ' ' -f1)" \
      --arg controller "$GITHUB_SHA" --arg run "$GITHUB_RUN_ID" --arg attempt "$GITHUB_RUN_ATTEMPT" \
      '{commit:$commit,parent:$parent,base:$base,tree:$tree,bundleSha256:$bundle,controller:$controller,runId:$run,attempt:$attempt,normalHookCommit:true,runtimeValidation:"NOT YET ESTABLISHED",scope:"Exact sixth commit retained at producer; not verified-candidate proof"}' \
      > "$evidence/committed-candidate.json"
    ;;
  tests)
    assert_commit
    run_logged focused pnpm test extensions/crabbox/src/crabbox-worker-warm-image-authority.test.ts --maxWorkers=1 --reporter=verbose -t 'record allocation honors invocation closure at commit with a live physical signal'
    assert_commit
    run_logged retirement-custody pnpm test extensions/crabbox/src/crabbox-worker-warm-image-sibling-admission.test.ts --maxWorkers=1 --reporter=verbose -t 'settles confirmed single-catalog deletion'
    assert_commit
    run_logged capture-custody pnpm test extensions/crabbox/src/crabbox-worker-warm-image-sibling-admission.test.ts --maxWorkers=1 --reporter=verbose -t 'capture (recovery precedence|(dispatch|claim delivery) custody)'
    assert_commit
    run_logged post-publication-control pnpm test extensions/crabbox/src/crabbox-worker-warm-image-sibling-admission.test.ts --maxWorkers=1 --reporter=verbose -t 'keeps a live project capture successful when post-publication retirement settlement is refused'
    assert_commit
    run_logged authority52 pnpm test \
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
    cp "$evidence/committed-candidate.bundle" "$RUNNER_TEMP/candidate.bundle"
    cmp "$evidence/committed-candidate.bundle" "$RUNNER_TEMP/candidate.bundle"
    test "$(sha256sum "$RUNNER_TEMP/candidate.bundle" | cut -d ' ' -f1)" = "$(jq -r .bundleSha256 "$evidence/committed-candidate.json")"
    run_logged bundle-verify git bundle verify "$RUNNER_TEMP/candidate.bundle"
    jq -n --arg commit "$(git rev-parse HEAD)" --arg parent "$(cat "$evidence/rebased-head.txt")"       --arg base "$base" --arg old "$old" --arg tree "$tree" --arg payload "$PATCH_SHA256"       --arg suite "$SUITE" --arg controller "$GITHUB_SHA" --arg run "$GITHUB_RUN_ID" --arg attempt "$GITHUB_RUN_ATTEMPT"       --arg bundle "$(sha256sum "$RUNNER_TEMP/candidate.bundle" | cut -d ' ' -f1)"       --slurpfile replay "$evidence/actual-replay-chain.json"       '{commit:$commit,parent:$parent,base:$base,oldHead:$old,tree:$tree,payloadSha256:$payload,suite:$suite,
        controller:$controller,runId:$run,attempt:$attempt,bundleSha256:$bundle,replay:$replay[0],
        scope:"retained native five-commit history plus ordinary sixth repair commit and focused provider proof; includes canonical plugin/core production types; not build/SDK/new-updater/native PR CI",
        declaredValidationScope:{focusedAllocationCases:1,pairedRetirementCases:2,pairedCaptureCases:11,postPublicationControlCases:1,groupedAuthorityCases:52,pluginSiblingFiles:13,coreSiblingFiles:2},
        observedCounts:"Read native logs; declared counts are not observations",
        hookProof:"Normal sixth repair commit with canonical pre-commit; original five use retained native provenance, never repeated here"}' > "$RUNNER_TEMP/candidate.json"
    cp "$RUNNER_TEMP/candidate.json" "$evidence/candidate.json"
    ;;
  *) exit 2 ;;
esac
