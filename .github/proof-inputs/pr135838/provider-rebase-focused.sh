#!/usr/bin/env bash
# Hosted continuation of the actual retained eight commits; never replay them.
set -euo pipefail
public_head=fd0b54a58f93b68a49eb07695705cd770ebb91b1
base=0edae198d278686e16426f7ad254d0341bd6e3d3
replayed_head=b99494f43807dccc858baef1fc169d2f2c2d33e5
replayed_tree=4e02b1417735ecfa62c645c427d44108cdf98d62
tree='dcf5d717b4a29b6b82d67d3acb57bf3f55ab300a'
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
test "$BASE_SHA" = "$public_head"
test "$EXPECTED_TREE" = "$tree"
test "$PATCH_ID" = provider-rebase-current
test "$PATCH_SHA256" = '4bb4a47f60de15bde0794c25eaa2a5bc8310861f26c6b082920b966a0623a746'
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
# Each retained commit must be one parent in the exact eight-commit tree chain.
assert_retained_history() {
  python3 - "$payload" "$1" <<'PY'
from pathlib import Path
import json,subprocess,base64,sys
m=json.loads(Path(sys.argv[1]).read_text()); head=sys.argv[2]
assert head==m['replayedHead']
def git(*a):return subprocess.check_output(['git',*a])
actual=git('rev-list','--reverse',m['newMain']+'..'+head).decode().splitlines()
assert len(actual)==len(m['steps'])==8, actual
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
    result.append({'actual':sha,'parent':parent,'tree':actual_tree,'emptyOriginal':s['emptyOriginal'],'authorAndMessagePreserved':True})
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
  assert_retained_history "$(cat "$evidence/rebased-head.txt")" > "$evidence/actual-replay-chain.json"
  test "$(git rev-list --count "$base..HEAD")" = 9
  test -z "$(git rev-list --merges "$base..HEAD")"
  git cat-file commit HEAD | python3 -c 'import sys; sys.stdout.buffer.write(sys.stdin.buffer.read().split(bytes([10,10]),1)[1])' > "$evidence/final-message.txt"
  cmp "$RUNNER_TEMP/commit-message.txt" "$evidence/final-message.txt"
}

case "$phase" in
  materialize)
    test "$(pwd -P)" = "$(realpath "$GITHUB_WORKSPACE")"
    test -d .git
    test "$(git rev-parse HEAD)" = "$public_head"
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
assert len(data)==r['bytes'] and hashlib.sha256(data).hexdigest()==r['sha256']=='d387bcdea1b40efcfacc735ae8ae016e1da51a2595d63df025635844def631c9'
Path(sys.argv[2]).write_bytes(data)
PY
    # Public fd0 carries authoritative B prerequisites, but not private b994.
    # Reject graft/replace/shallow semantics before bundle admission or import.
    test -z "$(git for-each-ref refs/replace --format='%(refname)')"
    test ! -s .git/info/grafts
    test "$(git rev-parse --is-shallow-repository)" = false
    git merge-base --is-ancestor "$base" "$public_head"
    python3 - "$payload" "$evidence" <<'PY'
from pathlib import Path
import base64,hashlib,json,sys
outer=json.loads(Path(sys.argv[1]).read_text());e=Path(sys.argv[2]);r=e/'retained';r.mkdir(exist_ok=False)
assert outer['schema']==3 and outer['mode']=='retained-eight-history-owner-repair'
assert outer['status']=='PARENT_REVIEWED_OWNER_REPAIR_FORMAT_ADOPTED'
assert outer['finalTree']=='dcf5d717b4a29b6b82d67d3acb57bf3f55ab300a'
assert outer['formatAdoption']['parentReviewedAndAdopted'] is True
assert outer['replayedHead']=='b99494f43807dccc858baef1fc169d2f2c2d33e5'
assert len(outer['steps'])==8
assert outer['repairPaths']==['extensions/crabbox/src/crabbox-worker-prepared-image.test.ts', 'extensions/crabbox/src/crabbox-worker-warm-image-allocation.test.ts', 'extensions/crabbox/src/crabbox-worker-warm-image-capture.ts']
assert outer['ownerRepairAdjudication']['greenPassed'] is True
assert outer['ownerRepairAdjudication']['canonicalFormatPassed'] is True
assert outer['formatAdoption']['formattedTree']==outer['finalTree']
m=outer['parentNative']
assert m['steps']==outer['steps']
for x in m['retained']:
    assert set(x)=={'path','mode','bytes','sha256','base64'} and x['mode']=='100644'
    assert Path(x['path']).name==x['path'] and x['path'] not in ('','.','..')
    data=base64.b64decode(x['base64'],validate=True)
    assert len(data)==x['bytes'] and hashlib.sha256(data).hexdigest()==x['sha256']
    target=r/x['path'];assert not target.exists();target.write_bytes(data)
"""Pure artifact/data validation. No Git, source modules, hooks, or subprocesses."""
import base64,hashlib,json,re

REQUIRED=[
 'committed-candidate.bundle','committed-candidate.json','committed-head.txt','rebased-head.txt',
 'final-message.txt','final-commit.txt','final-commit.trace2.jsonl','commit.phase.json',
 'normal-hook-commit.command.txt','normal-hook-commit.result.json','normal-hook-commit.log','normal-hook-commit.time.txt',
 'committed-history-bundle.command.txt','committed-history-bundle.result.json','committed-history-bundle.log',
 'committed-history-verify.command.txt','committed-history-verify.result.json','committed-history-verify.log',
 'format.command.txt','format.result.json','format.log','format.phase.json',
 'controller-workflow.yml','controller-recipe.sh','rebase-payload.json','controller-identity.txt',
 'run.json','step-outcomes.json','actual-replay-chain.json',
 'eight-commit-raw-receipt.json','tests.phase.json','warm-provider-siblings.result.json','warm-provider-siblings.log',
 'focused.result.json','retirement-custody.result.json','capture-custody.result.json','post-publication-control.result.json','authority-full.result.json',
 'focused.log','retirement-custody.log','capture-custody.log','post-publication-control.log','authority-full.log',
]
MESSAGE=b'fix(workers): fence reusable image publication with live authority\n\nKeep returned checkpoint custody independent while requiring live source authority at reusable publication admission.\n\nCo-authored-by: sallyom <11166065+sallyom@users.noreply.github.com>\nCo-authored-by: vincentkoc <25068+vincentkoc@users.noreply.github.com>\n'
def verify_retained(m,files):
    assert set(files)==set(REQUIRED)
    def j(p):return json.loads(files[p])
    def digest(p):return hashlib.sha256(files[p]).hexdigest()
    p=m['producer'];receipt=j('committed-candidate.json');expected=m['expectedProducer']
    assert p['repository']=='roboclaw-bot/openclaw'
    assert p['workflow']=='.github/workflows/pr135838-patch-validation.yml'
    assert p['artifactName']=='pr159178-rebase-evidence'
    assert p['runStatus']=='completed' and p['jobStatus']=='completed'
    # Failure after retention is valid custody, never a claim of passing tests.
    assert p['runConclusion']=='failure'
    assert p['jobConclusion']=='failure'
    for key in ('runId','attempt','jobId','artifactId'):
        assert isinstance(p[key],int) and not isinstance(p[key],bool) and p[key]>0
    assert re.fullmatch('[0-9a-f]{40}',p['controller'])
    assert re.fullmatch('sha256:[0-9a-f]{64}',p['artifactDigest'])
    assert receipt['commit']==m['commit'] and re.fullmatch('[0-9a-f]{40}',m['commit'])
    assert receipt['parent']==m['parent'] and receipt['base']==m['base'] and receipt['tree']==m['tree']
    assert receipt['controller']==p['controller'] and receipt['runId']==str(p['runId']) and receipt['attempt']==str(p['attempt'])
    assert receipt['normalHookCommit'] is True and receipt['runtimeValidation']=='NOT YET ESTABLISHED'
    assert receipt['bundleSha256']==m['bundleSha256']==digest('committed-candidate.bundle')
    header=files['committed-candidate.bundle'].split(bytes([10,10]),1)[0].splitlines()
    assert len(header)==3 and header[0]==b'# v2 git bundle'
    assert header[1].split(b' ',1)[0]==('-'+m['base']).encode()
    assert header[2]==(m['commit']+' HEAD').encode()
    assert files['committed-head.txt']==(m['commit']+chr(10)).encode()
    assert files['rebased-head.txt']==(m['parent']+chr(10)).encode()
    assert files['final-message.txt']==MESSAGE
    assert files['final-commit.txt'].splitlines()[:3]==[m[x].encode() for x in ('commit','parent','tree')]
    assert files['controller-identity.txt'].decode().splitlines()==[p['controller'],expected['parent'],expected['tree']]
    for path,key in [('controller-workflow.yml','workflowSha256'),('controller-recipe.sh','recipeSha256'),('rebase-payload.json','payloadSha256')]:
        assert digest(path)==expected[key]
    native=j('rebase-payload.json')
    assert native['finalTree']==m['tree'] and native['replayedHead']==m['parent'] and native['newMain']==m['base']
    assert native['schema']==3 and native['mode']=='retained-seven-history-publication-fence'
    assert native['status']=='PARENT_REVIEWED_FORMAT_ADOPTED'
    assert native['steps']==m['history'] and len(native['steps'])==7
    # Prior seven-parent custody remains exact opaque data: never execute it.
    assert len(files['rebase-payload.json'])==1457718
    assert digest('rebase-payload.json')=='eedd56d1f82ce5620e3703ee28e8a875607e64fe31d9100a48bd66e3c800e549'
    run=j('run.json')
    assert run['runId']==str(p['runId']) and run['attempt']==str(p['attempt']) and run['controller']==p['controller']
    outcomes=j('step-outcomes.json')
    for step in ('input_guard','preserve_inputs','base_checkout','materialize','dependencies','format','commit'):
        assert outcomes[step]['outcome']=='success' and outcomes[step]['conclusion']=='success',step
    for phase in ('format','commit'):
        assert j(phase+'.phase.json')['phase']==phase and j(phase+'.phase.json')['exitStatus']==0
    for label in ('normal-hook-commit','committed-history-bundle','committed-history-verify','format'):
        result=j(label+'.result.json')
        assert result['command']==label and result['nativeExitStatus']==0 and result['teeExitStatus']==0
    command=files['normal-hook-commit.command.txt']
    assert b'core.hooksPath=git-hooks' in command and b' commit --file ' in command
    assert b'--no-verify' not in command and b'commit-tree' not in command
    trace=[json.loads(x) for x in files['final-commit.trace2.jsonl'].splitlines() if x]
    starts=[x for x in trace if x.get('event')=='child_start' and x.get('hook_name')=='pre-commit']
    assert len(starts)==1
    start=starts[0]
    assert any(x.get('event')=='child_exit' and x.get('sid')==start['sid'] and x.get('child_id')==start['child_id'] and x.get('code')==0 for x in trace)
    replay=j('actual-replay-chain.json');assert len(replay)==7
    for actual,s in zip(replay,m['history'],strict=True):
        assert actual['actual']==s['expectedActual'] and actual['tree']==s['expectedRebasedTree']
        assert actual['emptyOriginal']==s['emptyOriginal']
        assert actual['authorAndMessagePreserved'] is True
    assert j('format.result.json')['endedAt']<=j('normal-hook-commit.result.json')['startedAt']
    assert j('normal-hook-commit.result.json')['endedAt']<=j('committed-history-bundle.result.json')['startedAt']
    assert j('committed-history-bundle.result.json')['endedAt']<=j('committed-history-verify.result.json')['startedAt']

    assert m['history']==m['steps'][:7]
    rows=j('eight-commit-raw-receipt.json');assert len(rows)==8
    parent=m['base'];trees=[]
    for row,s in zip(rows,m['steps'],strict=True):
        raw=base64.b64decode(row['rawBase64'],validate=True)
        assert raw==base64.b64decode(s['rawBase64'],validate=True)
        assert hashlib.sha1(b'commit '+str(len(raw)).encode()+bytes([0])+raw).hexdigest()==row['commit']==s['expectedActual']
        assert hashlib.sha256(raw).hexdigest()==row['rawSha256']
        h,msg=raw.split(bytes([10,10]),1);lines=h.splitlines()
        assert [x[7:].decode() for x in lines if x.startswith(b'parent ')]==[parent]
        tree=next(x[5:].decode() for x in lines if x.startswith(b'tree '));trees.append(tree)
        assert tree==s['expectedRebasedTree']
        assert next(x for x in lines if x.startswith(b'author '))==base64.b64decode(s['authorBase64'],validate=True)
        assert msg==base64.b64decode(s['messageBase64'],validate=True)
        parent=row['commit']
    assert parent==m['commit'] and trees[-1]==m['tree'] and trees[1]==trees[2]
    assert outcomes['tests']['outcome']==outcomes['tests']['conclusion']=='failure'
    assert outcomes['export']['outcome']==outcomes['export']['conclusion']=='skipped'
    assert m['verifiedCandidateExportExpected'] is False
    assert j('tests.phase.json')['exitStatus']==1
    failed=j('warm-provider-siblings.result.json')
    assert failed['nativeExitStatus']==1 and failed['teeExitStatus']==0
    for label in ('focused','retirement-custody','capture-custody','post-publication-control','authority-full'):
        result=j(label+'.result.json')
        assert result['nativeExitStatus']==0 and result['teeExitStatus']==0
    assert j('committed-history-verify.result.json')['endedAt']<=j('tests.phase.json')['startedAt']<=failed['startedAt']


verify_retained(m,{x:(r/x).read_bytes() for x in REQUIRED})
assert m['commit']==outer['replayedHead'] and m['tree']==outer['rebasedTree'] and m['base']==outer['newMain']
assert len((r/'committed-candidate.bundle').read_bytes())==64619
assert m['bundleSha256']=='f9fa60fdbc8180abeb3f2f43f18072e5fccb4617cc8077faff150ef2693f38bc'
assert m['producer']['controller']=='79564b780aaf7d8de89e10897840125be868d40e'
assert m['producer']['runId']==36359654197 and m['producer']['attempt']==1
assert m['producer']['artifactId']==10945078487
assert m['producer']['artifactDigest']=='sha256:ebc5aabd2312f4319c9f8b39b8d133c5d48ce5267a2aa84e52853176faec55fc'
(e/'parent-producer-custody.json').write_text(json.dumps(m['producer'],indent=2)+chr(10))
PY
    run_logged retained-bundle-verify git bundle verify "$evidence/retained/committed-candidate.bundle"
    run_logged retained-bundle-import git bundle unbundle "$evidence/retained/committed-candidate.bundle"
    assert_retained_history "$replayed_head" > "$evidence/actual-replay-chain.json"
    # One union covers B, all eight retained states, and future repair paths.
    # Every retained state must retain the audited base attribute inventory;
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
# retained commit byte here and audit only states this operation can materialize.
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
assert sorted(p.decode() for p in repair_paths)==m['repairPaths'], 'owner repair scope mismatch'
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
    # Attributes and raw history admitted before checking out the retained parent.
    run_logged checkout-retained-parent git checkout --detach "$replayed_head"
    assert_no_operation
    test "$(git rev-parse HEAD)" = "$replayed_head"
    test "$(git rev-parse HEAD^{tree})" = "$replayed_tree"
    git diff --quiet HEAD
    assert_retained_history "$replayed_head" > "$evidence/actual-replay-chain.json"
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
    test "${#files[@]}" -eq 56
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
fix(workers): keep project teardown within cleanup custody

Require captured logical source authority for project capture admission after cleanup collection; preserve late-image and ambiguous capture custody.

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
    python3 - "$base" "$evidence" <<'PY'
from pathlib import Path
import base64,hashlib,json,subprocess,sys
e=Path(sys.argv[2]);rows=[]
for commit in subprocess.check_output(['git','rev-list','--reverse',sys.argv[1]+'..HEAD']).decode().splitlines():
    raw=subprocess.check_output(['git','cat-file','commit',commit])
    assert hashlib.sha1(b'commit '+str(len(raw)).encode()+bytes([0])+raw).hexdigest()==commit
    (e/('raw-'+commit+'.commit')).write_bytes(raw)
    rows.append({'commit':commit,'rawSha256':hashlib.sha256(raw).hexdigest(),'rawBase64':base64.b64encode(raw).decode()})
assert len(rows)==9
(e/'nine-commit-raw-receipt.json').write_text(json.dumps(rows,indent=2)+chr(10))
PY
    # Capture C at its producer before any tests/types can fail. It is retained
    # history, not a passing candidate; later lanes must consume this exact C.
    run_logged committed-history-bundle git bundle create "$evidence/committed-candidate.bundle" "$base..HEAD"
    run_logged committed-history-verify git bundle verify "$evidence/committed-candidate.bundle"
    jq -n --arg commit "$(git rev-parse HEAD)" --arg parent "$replayed_head" --arg base "$base" --arg tree "$tree" \
      --arg bundle "$(sha256sum "$evidence/committed-candidate.bundle" | cut -d ' ' -f1)" \
      --arg controller "$GITHUB_SHA" --arg run "$GITHUB_RUN_ID" --arg attempt "$GITHUB_RUN_ATTEMPT" \
      '{commit:$commit,parent:$parent,base:$base,tree:$tree,bundleSha256:$bundle,controller:$controller,runId:$run,attempt:$attempt,normalHookCommit:true,runtimeValidation:"NOT YET ESTABLISHED",scope:"Exact ninth commit retained at producer; not verified-candidate proof"}' \
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
    run_logged authority-full pnpm test \
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
    jq -n --arg commit "$(git rev-parse HEAD)" --arg parent "$(cat "$evidence/rebased-head.txt")"       --arg base "$base" --arg publicHead "$public_head" --arg tree "$tree" --arg payload "$PATCH_SHA256"       --arg suite "$SUITE" --arg controller "$GITHUB_SHA" --arg run "$GITHUB_RUN_ID" --arg attempt "$GITHUB_RUN_ATTEMPT"       --arg bundle "$(sha256sum "$RUNNER_TEMP/candidate.bundle" | cut -d ' ' -f1)"       --slurpfile replay "$evidence/actual-replay-chain.json"       '{commit:$commit,parent:$parent,base:$base,publicHead:$publicHead,tree:$tree,payloadSha256:$payload,suite:$suite,
        controller:$controller,runId:$run,attempt:$attempt,bundleSha256:$bundle,replay:$replay[0],
        scope:"retained eight-commit history plus ordinary ninth owner repair and native provider/production-type/boundary proof; full lint and plugin/root test types remain a separate same-commit gate; not build/SDK/updater/native PR CI",
        declaredValidationScope:{focusedAllocationCases:1,pairedRetirementCases:2,pairedCaptureCases:11,postPublicationControlCases:1,groupedAuthorityFiles:3,pluginSiblingFiles:13,coreSiblingFiles:2},
        observedCounts:"Read native logs; selectors and file counts are not observed passes",
        hookProof:"Normal ninth repair commit with canonical pre-commit; all eight raw parent commits are unchanged"}' > "$RUNNER_TEMP/candidate.json"
    cp "$RUNNER_TEMP/candidate.json" "$evidence/candidate.json"
    ;;
  *) exit 2 ;;
esac
