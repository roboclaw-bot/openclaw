#!/usr/bin/env bash
# Controller-owned source admission shared by the five existing pre-push suites.
# C is imported once per isolated job from the producer's identical bundle bytes.
set -euo pipefail
base=0edae198d278686e16426f7ad254d0341bd6e3d3
replayed_head=7365e3003e1c6ab9e372fc5b1fe673f82c18389e
tree=ab1b49cd3e7f05a5253f5b12828c236384b9a671
candidate='fd0b54a58f93b68a49eb07695705cd770ebb91b1'
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
test "$PATCH_SHA256" = 'a27406ea27fa53d745f8c3782425ef6ffea839383f7a6b0372b2dd55f78f8491'
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
assert m['commit']=='fd0b54a58f93b68a49eb07695705cd770ebb91b1' and m['tree']=='ab1b49cd3e7f05a5253f5b12828c236384b9a671'
for x in m['retained']:
    assert set(x)=={'path','mode','bytes','sha256','base64'} and x['mode']=='100644'
    assert Path(x['path']).name==x['path'] and x['path'] not in ('','.','..')
    b=base64.b64decode(x['base64'],validate=True)
    assert len(b)==x['bytes'] and hashlib.sha256(b).hexdigest()==x['sha256']
    target=r/x['path'];assert not target.exists();target.write_bytes(b)
# Every accepted byte was copied from the immutable producer archive, not rebuilt.
"""Pure artifact/data validation. No Git, source modules, hooks, or subprocesses."""
import hashlib,json,re

REQUIRED=[
 'committed-candidate.bundle','committed-candidate.json','committed-head.txt','rebased-head.txt',
 'final-message.txt','final-commit.txt','final-commit.trace2.jsonl','commit.phase.json',
 'normal-hook-commit.command.txt','normal-hook-commit.result.json','normal-hook-commit.log','normal-hook-commit.time.txt',
 'committed-history-bundle.command.txt','committed-history-bundle.result.json','committed-history-bundle.log',
 'committed-history-verify.command.txt','committed-history-verify.result.json','committed-history-verify.log',
 'format.command.txt','format.result.json','format.log','format.phase.json',
 'controller-workflow.yml','controller-recipe.sh','rebase-payload.json','controller-identity.txt',
 'run.json','step-outcomes.json','actual-replay-chain.json',
]
MESSAGE=b'''fix(workers): retain warm-image custody through caller closure

Preserve physical settlement and cleanup after invocation closure on the rebased provider series.

Co-authored-by: sallyom <11166065+sallyom@users.noreply.github.com>
Co-authored-by: vincentkoc <25068+vincentkoc@users.noreply.github.com>
'''
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
    assert p['runConclusion'] in ('success','failure','cancelled','timed_out')
    assert p['jobConclusion'] in ('success','failure','cancelled','timed_out')
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
    assert native['sourceChecks']==m['sourceChecks'] and native['changedPaths']==m['changedPaths']
    assert native['nativeCustody']==m['settledNativeCustody'] and native['formatAdoption']==m['formatAdoption']
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
    replay=j('actual-replay-chain.json');assert len(replay)==5
    for actual,s in zip(replay,m['history'],strict=True):
        assert actual['actual']==s['commit'] and actual['original']==s['original'] and actual['tree']==s['expectedRebasedTree']
        assert actual['authorAndMessagePreserved'] is True
    assert j('format.result.json')['endedAt']<=j('normal-hook-commit.result.json')['startedAt']
    assert j('normal-hook-commit.result.json')['endedAt']<=j('committed-history-bundle.result.json')['startedAt']
    assert j('committed-history-bundle.result.json')['endedAt']<=j('committed-history-verify.result.json')['startedAt']

verify_retained(m,{x:(r/x).read_bytes() for x in REQUIRED})

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
assert actual==[s['commit'] for s in m['history']]+[m['commit']] and len(actual)==6
assert not git('rev-list','--merges',m['base']+'..'+m['commit'])
parent=m['base'];rows=[]
for i,sha in enumerate(actual):
    raw=git('cat-file','commit',sha);(e/('raw-'+sha+'.commit')).write_bytes(raw)
    assert hashlib.sha1(b'commit '+str(len(raw)).encode()+bytes([0])+raw).hexdigest()==sha
    headers,msg=raw.split(bytes([10,10]),1);lines=headers.splitlines()
    assert [x[7:].decode() for x in lines if x.startswith(b'parent ')]==[parent]
    tree=next(x[5:].decode() for x in lines if x.startswith(b'tree '))
    if i<5:
        s=m['history'][i]
        assert raw==base64.b64decode(s['rawBase64'],validate=True)
        assert tree==s['expectedRebasedTree']
        assert next(x for x in lines if x.startswith(b'author '))==base64.b64decode(s['authorBase64'])
        assert msg==base64.b64decode(s['messageBase64'])
    else:
        assert parent==m['parent'] and tree==m['tree']
        assert msg==(e/'retained/final-message.txt').read_bytes()
        for role in (b'author ',b'committer '):
            identity=next(x[len(role):] for x in lines if x.startswith(role)).rsplit(b' ',2)
            assert identity[0]==b'roboclaw-bot <309084314+roboclaw-bot@users.noreply.github.com>'
    rows.append(dict(commit=sha,parent=parent,tree=tree));parent=sha
assert rows[1]['tree']==rows[2]['tree']
(e/'six-commit-chain.json').write_text(json.dumps(rows,indent=2)+chr(10))
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
assert paths[-1]==b'' and [p.decode() for p in paths[:-1]]==m['changedPaths'] and len(paths)==51
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
