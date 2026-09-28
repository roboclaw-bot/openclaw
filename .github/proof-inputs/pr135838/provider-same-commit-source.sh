#!/usr/bin/env bash
# Controller-owned source admission shared by the five existing pre-push suites.
# C is imported once per isolated job from the producer's identical bundle bytes.
set -euo pipefail
base=0edae198d278686e16426f7ad254d0341bd6e3d3
replayed_head=e0a53eaa04e450cf9c287e2f8ae1f687f3afdf23
tree='e84e634a10fa84314b04119bd44d3a4a233a2999'
candidate='c9921022529005400c41de6580dfabc99b7948dc'
payload="$RUNNER_TEMP/same-commit-payload.json"
evidence="$RUNNER_TEMP/pr159178-same-commit"
phase="${1:-source}"
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

case "$SUITE" in provider-resume-build|provider-resume-api|provider-resume-test-types-a|provider-resume-test-types-b|provider-resume-plugin-test-types) ;; *) exit 2 ;; esac
test "$BASE_SHA" = "$base"
test "$EXPECTED_TREE" = "$tree"
test "$PATCH_ID" = provider-same-commit
test "$PATCH_SHA256" = '7c8a09a759f3719fe60d4cb2f09ca8b859161219e93ee99060d6d5255ec4b08b'
test "$(sha256sum "$payload" | cut -d ' ' -f1)" = "$PATCH_SHA256"
test "$(sha256sum "$RUNNER_TEMP/same-commit-source.sh" | cut -d ' ' -f1)" = "$SAME_COMMIT_SOURCE_SHA256"
test "$GITHUB_REPOSITORY" = roboclaw-bot/openclaw
test "$GITHUB_REF" = refs/heads/main
test "$GITHUB_EVENT_NAME" = workflow_dispatch
test "$GITHUB_SHA" = "$REBASE_WORKFLOW_SHA"
test "$SAME_COMMIT_HOSTED" = github-hosted
test "$RUNNER_OS" = Linux
[[ "$GITHUB_RUN_ID" =~ ^[0-9]+$ && "$GITHUB_RUN_ATTEMPT" =~ ^[0-9]+$ ]]
test -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}${NODE_AUTH_TOKEN:-}${NPM_TOKEN:-}${NODE_OPTIONS:-}"
test -z "${GIT_INDEX_FILE:-}${GIT_OBJECT_DIRECTORY:-}${GIT_ALTERNATE_OBJECT_DIRECTORIES:-}${GIT_CONFIG_COUNT:-}${GIT_CONFIG_PARAMETERS:-}${GIT_DIR:-}${GIT_WORK_TREE:-}${GIT_ATTR_SOURCE:-}${GIT_ATTR_NOSYSTEM:-}"
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
  test "$(git rev-parse HEAD)" = "$candidate" || return $?
  test "$(git show -s --format=%P HEAD)" = "$replayed_head" || return $?
  test "$(git rev-parse HEAD^{tree})" = "$tree" || return $?
  test "$(git write-tree)" = "$tree" || return $?
  git diff --quiet HEAD || return $?
  python3 - "$payload" <<'PY'
from pathlib import Path
import json,hashlib,sys
for item in json.loads(Path(sys.argv[1]).read_text())['sourceChecks']:
    p=Path(item['path'])
    assert p.is_file() and not p.is_symlink(), item['path']
    assert hashlib.sha256(p.read_bytes()).hexdigest()==item['sha256'], item['path']
PY
}

case "$phase" in
  materialize)
    test "$(pwd -P)" = "$(realpath "$GITHUB_WORKSPACE")"
    test -d .git
    test "$(git rev-parse HEAD)" = "$base"
    test -z "$(git status --porcelain --untracked-files=all)"
    assert_no_operation
    test -z "$(git for-each-ref refs/replace --format='%(refname)')"
    test ! -s .git/info/grafts
    test "$(git rev-parse --is-shallow-repository)" = false
    status=0
    git config --name-only --get-regexp '^(attr\.tree$|merge\.|rebase\.|rerere\.|submodule\.|include|url\.|credential\.|http\..*extraheader|branch\..*\.mergeoptions$|pull\.(twohead|octopus)$|core\.(hookspath|attributesfile|fsmonitor|sparsecheckout|autocrlf|eol)$|commit\.|hook\.|hooks\.|i18n\.)' > "$evidence/custom-git-config.txt" || status=$?
    test "$status" -eq 1
    status=0
    git config --null --show-origin --show-scope --name-only --get-regexp '^filter\.' > "$evidence/configured-filter-metadata.nul" || status=$?
    test "$status" -eq 0 || test "$status" -eq 1
    test ! -s "$(git rev-parse --git-path info/attributes)"
    test ! -L .git/hooks
    find .git/hooks -mindepth 1 -maxdepth 1 ! -name '*.sample' -print > "$evidence/active-hooks.txt"
    test ! -s "$evidence/active-hooks.txt"
    git --version > "$evidence/git-version.txt"
    test "$(cat "$evidence/git-version.txt")" = 'git version 2.55.0'
    python3 - "$payload" "$evidence" <<'PY'
from pathlib import Path
import base64,hashlib,json,sys
m=json.loads(Path(sys.argv[1]).read_text());e=Path(sys.argv[2]);r=e/'retained';r.mkdir(exist_ok=False)
assert m['schema']==1 and m['status']=='PARENT_REVIEWED_SAME_COMMIT'
assert m['commit']=='c9921022529005400c41de6580dfabc99b7948dc' and m['tree']=='e84e634a10fa84314b04119bd44d3a4a233a2999'
for x in m['retained']:
    assert set(x)=={'path','mode','bytes','sha256','base64'} and x['mode']=='100644'
    assert Path(x['path']).name==x['path'] and x['path'] not in ('','.','..')
    b=base64.b64decode(x['base64'],validate=True)
    assert len(b)==x['bytes'] and hashlib.sha256(b).hexdigest()==x['sha256']
    target=r/x['path'];assert not target.exists();target.write_bytes(b)
# Every accepted byte was copied from the immutable producer archive, not rebuilt.
"""Pure inert receipt verification for the actual ordinary lint-repair producer.
No old receipt translation, source imports, subprocesses, network or writes.
"""
import base64, hashlib, json, re
B = '0edae198d278686e16426f7ad254d0341bd6e3d3'
A = 'e0a53eaa04e450cf9c287e2f8ae1f687f3afdf23'
T = 'e84e634a10fa84314b04119bd44d3a4a233a2999'
PATCH = '298c200e081b400b07197fa4dd061ea40aa43cf44dd69b2b19a596251f58a0c1'
CONTROLLER = 'c0aeafdd22fa4928456b23317cff1cea01dc0fc9'
IDENTITY = b'roboclaw-bot <309084314+roboclaw-bot@users.noreply.github.com>'
MESSAGE = b'''test(workers): avoid shadowing the capture profile key

Rename only the local capture profile key and its references; preserve all production code and assertions.

Co-authored-by: sallyom <11166065+sallyom@users.noreply.github.com>
Co-authored-by: vincentkoc <25068+vincentkoc@users.noreply.github.com>
'''
REQUIRED = ['committed-candidate.bundle','committed-candidate.json','committed-head.txt',
 'history.json','final-commit.trace2.jsonl','bundle-verify.txt',
 'public-head-before-commit.txt','expected-public-head.txt',
 'format-before-commit.command.txt','format-before-commit.result.json',
 'format-before-commit.log','format-before-commit.time.txt',
 'controller-workflow.yml','controller-recipe.sh','controller-identity.txt',
 'materialization.patch','run.json','step-outcomes.json']

def sha(b): return hashlib.sha256(b).hexdigest()

def verify_retained(m, files):
    assert m['schema'] == 1 and m['status'] == 'PARENT_REVIEWED_SAME_COMMIT'
    assert (m['base'],m['parent'],m['tree']) == (B,A,T)
    candidate = m['commit']; assert isinstance(candidate,str) and re.fullmatch('[a-f0-9]{40}',candidate)
    assert len(m['history']) == 9 and m['history'][-1]['commit'] == A
    raw_paths = ['raw-'+h['commit']+'.commit' for h in m['history']]+['raw-'+candidate+'.commit']
    assert set(REQUIRED+raw_paths) <= set(files)
    p = m['producer']; expected = m['expectedProducer']
    assert p['repository'] == 'roboclaw-bot/openclaw'
    assert p['workflow'] == '.github/workflows/pr135838-patch-validation.yml'
    assert p['artifactName'] == 'pr159178-same-commit-evidence' and p['controller'] == CONTROLLER
    assert p['runStatus'] == p['jobStatus'] == 'completed'
    for key in ('runId','attempt','jobId','artifactId'):
        assert type(p[key]) is int and p[key] > 0
    assert p['attempt'] == 1
    assert p['runConclusion'] in ('success','failure','cancelled','timed_out')
    assert p['jobConclusion'] in ('success','failure','cancelled','timed_out')
    assert re.fullmatch('sha256:[a-f0-9]{64}',p['artifactDigest'])
    receipt = json.loads(files['committed-candidate.json'])
    # This producer does NOT emit attempt/normalHookCommit/runtimeValidation here.
    assert set(receipt) == {'commit','parent','base','tree','patchSha256','controller','runId','bundleSha256','validation','scope'}
    for key in ('commit','parent','base','tree','bundleSha256'): assert receipt[key] == m[key]
    assert receipt['patchSha256'] == PATCH and receipt['controller'] == CONTROLLER
    assert receipt['runId'] == str(p['runId']) and receipt['validation'] == 'NOT YET ESTABLISHED'
    assert receipt['scope'] == 'Retained actual normal-hook commit; not passing proof'
    assert sha(files['committed-candidate.bundle']) == m['bundleSha256']
    header = files['committed-candidate.bundle'].split(b'\n\n',1)[0].splitlines()
    assert len(header) == 3 and header[0] == b'# v2 git bundle'
    assert header[1].split(b' ',1)[0] == ('-'+B).encode() and header[2] == (candidate+' HEAD').encode()
    assert files['committed-head.txt'] == (candidate+'\n').encode()
    assert files['expected-public-head.txt'] == files['public-head-before-commit.txt'] == (A+'	refs/pull/159178/head\n').encode()
    assert sha(files['materialization.patch']) == PATCH == expected['patchSha256']
    assert files['controller-identity.txt'].decode().splitlines() == [CONTROLLER,expected['parent'],expected['tree']]
    for name,key in [('controller-workflow.yml','workflowSha256'),('controller-recipe.sh','recipeSha256')]:
        assert sha(files[name]) == expected[key]
    result = json.loads(files['format-before-commit.result.json'])
    assert set(result) == {'name','commit','nativeExit','captureExit'}
    assert result == {'name':'format-before-commit','commit':A,'nativeExit':0,'captureExit':0}
    assert files['format-before-commit.command.txt'] == b'pnpm format:check extensions/crabbox/src/crabbox-worker-warm-image-authority.test.ts \n'
    run = json.loads(files['run.json'])
    assert (run['runId'],run['attempt'],run['controller'],run['suite']) == (str(p['runId']),'1',CONTROLLER,'provider-routing-repair')
    outcomes = json.loads(files['step-outcomes.json'])
    for step in ('input_guard','preserve_inputs','base_checkout','materialize','dependencies','ordinary_commit'):
        assert outcomes[step]['outcome'] == outcomes[step]['conclusion'] == 'success', step
    # These existing sibling producer steps are skipped, not invented passes.
    for step in ('format','commit','export','same_commit_export'):
        assert outcomes[step]['outcome'] == outcomes[step]['conclusion'] == 'skipped', step
    trace = [json.loads(line) for line in files['final-commit.trace2.jsonl'].splitlines() if line]
    starts = [x for x in trace if x.get('event') == 'child_start' and x.get('hook_name') == 'pre-commit']
    assert len(starts) == 1
    start = starts[0]
    exits = [x for x in trace if x.get('event') == 'child_exit' and x.get('sid') == start['sid'] and x.get('child_id') == start['child_id']]
    assert len(exits) == 1 and exits[0]['code'] == 0 and start['time'] <= exits[0]['time']
    rows = json.loads(files['history.json'])
    assert len(rows) == len({x['commit'] for x in rows}) == 10
    assert [x['commit'] for x in rows] == [h['commit'] for h in m['history']]+[candidate]
    previous = B; trees = []
    for i,row in enumerate(rows):
        assert set(row) == {'commit','rawSha256'}, 'No fabricated rawBase64 native receipt'
        raw = files['raw-'+row['commit']+'.commit']
        assert sha(raw) == row['rawSha256']
        assert hashlib.sha1(b'commit '+str(len(raw)).encode()+b'\0'+raw).hexdigest() == row['commit']
        headers,message = raw.split(b'\n\n',1); lines = headers.splitlines()
        assert [x[7:].decode() for x in lines if x.startswith(b'parent ')] == [previous]
        tree_rows = [x[5:].decode() for x in lines if x.startswith(b'tree ')]; assert len(tree_rows) == 1
        tree = tree_rows[0]; trees.append(tree)
        if i < 9:
            h = m['history'][i]
            assert raw == base64.b64decode(h['rawBase64'],validate=True)
            assert sha(raw) == h['rawSha256'] and tree == h['expectedRebasedTree']
        else:
            assert previous == A and tree == T and message == MESSAGE
            for role in (b'author ',b'committer '):
                identities = [x[len(role):] for x in lines if x.startswith(role)]
                assert len(identities) == 1 and identities[0].rsplit(b' ',2)[0] == IDENTITY
        previous = row['commit']
    assert trees[1] == trees[2]
    return receipt

verify_retained(m,{x:(r/x).read_bytes() for x in REQUIRED+['raw-'+h['commit']+'.commit' for h in m['history']]+['raw-'+m['commit']+'.commit']})

(e/'producer-custody.json').write_text(json.dumps(m['producer'],indent=2)+chr(10))
PY
    # The only prerequisite is B, already checked out with complete history.
    # verify/unbundle transport real objects; neither constructs a new commit.
    run_logged committed-bundle-verify git bundle verify "$evidence/retained/committed-candidate.bundle"
    run_logged committed-bundle-import git bundle unbundle "$evidence/retained/committed-candidate.bundle"
    python3 - "$payload" "$evidence" <<'PY'
from pathlib import Path
import base64,hashlib,json,subprocess,sys
m=json.loads(Path(sys.argv[1]).read_text());e=Path(sys.argv[2])
def git(*a):return subprocess.check_output(['git',*a])
actual=git('rev-list','--reverse',m['base']+'..'+m['commit']).decode().splitlines()
assert actual==[s['commit'] for s in m['history']]+[m['commit']] and len(actual)==10
assert not git('rev-list','--merges',m['base']+'..'+m['commit'])
parent=m['base'];rows=[]
for i,sha in enumerate(actual):
    raw=git('cat-file','commit',sha);(e/('raw-'+sha+'.commit')).write_bytes(raw)
    assert hashlib.sha1(b'commit '+str(len(raw)).encode()+bytes([0])+raw).hexdigest()==sha
    headers,msg=raw.split(bytes([10,10]),1);lines=headers.splitlines()
    assert [x[7:].decode() for x in lines if x.startswith(b'parent ')]==[parent]
    tree=next(x[5:].decode() for x in lines if x.startswith(b'tree '))
    if i<9:
        s=m['history'][i]
        assert raw==base64.b64decode(s['rawBase64'],validate=True)
        assert tree==s['expectedRebasedTree']
        assert hashlib.sha256(raw).hexdigest()==s['rawSha256']
    else:
        assert parent==m['parent'] and tree==m['tree']
        assert raw==(e/('retained/raw-'+sha+'.commit')).read_bytes()
        for role in (b'author ',b'committer '):
            identity=next(x[len(role):] for x in lines if x.startswith(role)).rsplit(b' ',2)
            assert identity[0]==b'roboclaw-bot <309084314+roboclaw-bot@users.noreply.github.com>'
    rows.append(dict(commit=sha,parent=parent,tree=tree));parent=sha
assert rows[1]['tree']==rows[2]['tree']
(e/'ten-commit-chain.json').write_text(json.dumps(rows,indent=2)+chr(10))
# Attribute activation is checked at B and every admitted actual object before
# checkout. Configured filter names alone are not activation or an LFS ban.
def fields(data):
    assert not data or data.endswith(bytes([0]))
    return data[:-1].split(bytes([0])) if data else []
metadata=fields((e/'configured-filter-metadata.nul').read_bytes());assert len(metadata)%3==0
for scope,origin,name in zip(metadata[::3],metadata[1::3],metadata[2::3],strict=True):
    assert scope and origin and name.startswith(b'filter.')
refs=[m['base'],*actual];paths=set();inventories={}
for ref in refs:
    entries=fields(git('ls-tree','-r','-z',ref));assert entries
    (e/(ref+'.entries.nul')).write_bytes(bytes([0]).join(entries)+bytes([0]))
    attrs=[]
    for entry in entries:
        header,path=entry.split(bytes([9]),1);mode,kind,oid=header.split(b' ')
        assert mode!=b'160000' and path
        paths.add(path)
        if path.rsplit(b'/',1)[-1]==b'.gitattributes':
            assert kind==b'blob' and mode in (b'100644',b'100755');attrs.append(entry)
    inventories[ref]=attrs
assert all(v==inventories[m['base']] for v in inventories.values())
union=b''.join(p+bytes([0]) for p in sorted(paths));(e/'attribute-audit-paths.nul').write_bytes(union)
expected={(p,a) for p in paths for a in (b'filter',b'merge')}
for ref in refs:
    data=subprocess.check_output(['git','check-attr','--source='+ref,'--stdin','-z','filter','merge'],input=union)
    (e/(ref+'.attributes.nul')).write_bytes(data);triples=fields(data)
    assert len(triples)==3*len(expected);seen=set()
    for p,a,v in zip(triples[::3],triples[1::3],triples[2::3],strict=True):
        assert (p,a) in expected and (p,a) not in seen and v==b'unspecified';seen.add((p,a))
    assert seen==expected
    data=subprocess.check_output(['git','check-attr','--source='+ref,'--stdin','-z','--all'],input=union)
    (e/(ref+'.all-attributes.nul')).write_bytes(data);triples=fields(data);assert len(triples)%3==0;seen=set()
    for p,a,v in zip(triples[::3],triples[1::3],triples[2::3],strict=True):
        assert p in paths and a and (p,a) not in seen and a not in (b'filter',b'merge');seen.add((p,a))
paths=git('diff','--name-only','-z',m['base'],m['commit']).split(bytes([0]))
assert paths[-1]==b'' and [p.decode() for p in paths[:-1]]==m['changedPaths'] and len(paths)==len(m['changedPaths'])+1
(e/'full-pr-changed-paths.nul').write_bytes(bytes([0]).join(paths))
PY
    run_logged checkout-committed-candidate git checkout --detach "$candidate"
    assert_candidate
    printf '%s\n' "$candidate" > "$evidence/source-admitted.txt"
    ;;
  source|before-setup|after-setup)
    assert_candidate
    if [[ "$phase" == after-setup ]]; then
      test "$(node --version)" = v24.19.0
      test "$(pnpm --version)" = 12.5.0
    fi
    ;;
  export)
    assert_candidate
    # Retain exact producer bytes. No bundle create/repack or commit in a gate.
    cp "$evidence/retained/committed-candidate.bundle" "$RUNNER_TEMP/candidate.bundle"
    cmp "$evidence/retained/committed-candidate.bundle" "$RUNNER_TEMP/candidate.bundle"
    sdk_report_sha=""
    if [[ "$SUITE" == provider-resume-api ]]; then
      test -s "$RUNNER_TEMP/candidate-sdk-api.txt"
      jq -e . "$RUNNER_TEMP/candidate-sdk-api.json" >/dev/null
      sdk_report_sha="$(sha256sum "$RUNNER_TEMP/candidate-sdk-api.json" | cut -d ' ' -f1)"
    fi
    jq -n --arg commit "$candidate" --arg parent "$replayed_head" --arg base "$base" --arg tree "$tree" --arg payload "$PATCH_SHA256" --arg suite "$SUITE" --arg report "$sdk_report_sha" --arg bundle "$(sha256sum "$RUNNER_TEMP/candidate.bundle" | cut -d ' ' -f1)" --arg controller "$GITHUB_SHA" --arg run "$GITHUB_RUN_ID" --arg attempt "$GITHUB_RUN_ATTEMPT" --slurpfile admitted "$payload" '{commit:$commit,parent:$parent,base:$base,tree:$tree,payloadSha256:$payload,suite:$suite,bundleSha256:$bundle,producer:$admitted[0].producer,controller:$controller,runId:$run,attempt:$attempt,gateStatus:"passed",compatibilityReview:(if $suite=="provider-resume-api" then {status:"required",base:$base,head:$commit,reportSha256:$report} else null end),scope:"This selected pre-push gate only; not focused runtime, other gates, updater, PR CI, or merge approval"}' > "$RUNNER_TEMP/candidate.json"
    ;;
  *) exit 2 ;;
esac
