#!/usr/bin/env bash
# Existing same-commit admission, bound here only for the reviewed canonical build.
# C is imported once per isolated job from the producer's identical bundle bytes.
set -euo pipefail
base=aa298d3a515ca85dc0970aacda0403d67ec2a097
replayed_head=19d331d185ac1337204a9a80aff913ee1a358572
tree='5cd77ceafea320d20b9f43cdd62b0ab712b74115'
candidate='57cd0bcdb90a9a2eea6396cad3f3e2e3bfb2225c'
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

test "$SUITE" = provider-resume-build
test "$BASE_SHA" = "$base"
test "$EXPECTED_TREE" = "$tree"
test "$PATCH_ID" = provider-same-commit
test "$PATCH_SHA256" = 'd6c07ebbcba2cabc3c0a847c07de1c088eca6da667dcf393935a07ac0bd652d1'
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
assert m['commit']=='57cd0bcdb90a9a2eea6396cad3f3e2e3bfb2225c' and m['tree']=='5cd77ceafea320d20b9f43cdd62b0ab712b74115'
for x in m['retained']:
    assert set(x)=={'path','mode','bytes','sha256','base64'} and x['mode']=='100644'
    assert Path(x['path']).name==x['path'] and x['path'] not in ('','.','..')
    b=base64.b64decode(x['base64'],validate=True)
    assert len(b)==x['bytes'] and hashlib.sha256(b).hexdigest()==x['sha256']
    target=r/x['path'];assert not target.exists();target.write_bytes(b)
# Exact successful producer custody. Consume original receipts; never normalize exit1 to0.
def kept(name):
    return r/name.replace('/', '__')
def read_json(name):
    return json.loads(kept(name).read_bytes())
def hash_bytes(data):
    return hashlib.sha256(data).hexdigest()
producer=m['producer']; receipt=read_json('candidate.json'); native=read_json('history.json')
assert producer['repository']=='roboclaw-bot/openclaw' and producer['workflow']=='.github/workflows/pr135838-patch-validation.yml'
assert producer['runId']==37139953970 and producer['attempt']==1 and producer['jobId']==111252133152
assert producer['controller']=='20735bd9cfdf530abe0c1d65947fa8cb702b029a'
assert producer['runConclusion']==producer['jobConclusion']=='success'
assert receipt['commit']==m['commit'] and receipt['tree']==m['tree'] and receipt['base']==m['base']
assert receipt['parent']==m['parent'] and receipt['oldHead']=='5d116aa3f1e0d85f9408d95cce0640926a8d8c60'
assert receipt['bundleSha256']==m['bundleSha256'] and receipt['payloadSha256']=='b85061574031cfe7acdc241a61708b30f76a1abeba5b1f4d7a2013d2fe5c1104'
assert receipt['controller']==producer['controller'] and receipt['runId']==str(producer['runId']) and receipt['attempt']=='1' and receipt['suite']=='provider-rebase-focused'
assert hash_bytes(kept('candidate.bundle').read_bytes())==m['bundleSha256']
assert kept('candidate.bundle').stat().st_size==65551
header=kept('candidate.bundle').read_bytes().split(bytes([10,10]),1)[0].decode().splitlines()
assert len(header)==3 and header[0]=='# v2 git bundle' and header[1].split(' ',1)[0]=='-'+m['base'] and header[2]==m['commit']+' HEAD'
# Exact reviewed API receipts are included, not a lone successful artifact name.
run_api=read_json('producer-attempt.json');jobs_api=read_json('producer-jobs.json')
assert run_api['id']==producer['runId'] and run_api['run_attempt']==1 and run_api['head_sha']==producer['controller'] and run_api['status']=='completed' and run_api['conclusion']=='success'
assert run_api['event']=='workflow_dispatch' and run_api['head_branch']=='main' and run_api['path']==producer['workflow']
assert run_api['actor']['login']=='roboclaw-bot' and run_api['actor']['id']==309084314
job=next(j for j in jobs_api['jobs'] if j['id']==producer['jobId'])
assert job['run_id']==producer['runId'] and job['head_sha']==producer['controller'] and job['run_attempt']==1 and job['conclusion']=='success' and job['status']=='completed'
for slot,name,artifact_id,digest in [
    ('artifact','producer-evidence-metadata.json',11280347436,'sha256:e09b50c4a3c925ceaf7558acc1a5fa427eea86f3c8bfa701b8996bbc01cdf08d'),
    ('verifiedArtifact','producer-verified-metadata.json',11280497334,'sha256:0ef73eea8a95229df11377295214961975170aa71ed67a4012561be4ad20daba'),
]:
    artifact=read_json(name);assert artifact==producer[slot] and artifact['id']==artifact_id and artifact['digest']==digest
    assert artifact['workflow_run']['id']==producer['runId'] and artifact['workflow_run']['head_sha']==producer['controller'] and not artifact['expired']
member_manifest={x['path']:x for x in read_json('producer-evidence-members.json')}
verified_manifest={x['path']:x for x in read_json('producer-verified-members.json')}
assert len(member_manifest)==429 and len(verified_manifest)==2
for original in m['evidencePaths']:
    source=member_manifest[original];data=kept(original).read_bytes()
    assert len(data)==source['bytes'] and hash_bytes(data)==source['sha256'],original
for original in ('candidate.bundle','candidate.json'):
    source=verified_manifest[original];data=kept(original).read_bytes()
    assert len(data)==source['bytes'] and hash_bytes(data)==source['sha256'],original
replay=read_json('rebase-payload.json');assert hash_bytes(kept('rebase-payload.json').read_bytes())==receipt['payloadSha256']
assert replay['newMain']==m['base'] and replay['finalTree']==m['tree'] and replay['oldHead']==receipt['oldHead']
assert replay['sourceChecks']==m['sourceChecks'] and replay['changedPaths']==m['changedPaths']
assert len(native)==len(m['history'])==len(replay['steps'])==10 and native==receipt['replay']
previous=m['base']; trees=[]
for h,row,original in zip(m['history'],native,replay['steps'],strict=True):
    assert row['actual']==h['commit'] and row['parent']==previous and row['tree']==h['expectedRebasedTree']==original['expectedRebasedTree']
    raw=kept('raw-'+h['commit']+'.commit').read_bytes()
    assert raw==base64.b64decode(h['rawBase64'],validate=True) and hash_bytes(raw)==h['rawSha256']
    assert hashlib.sha1(b'commit '+str(len(raw)).encode()+bytes([0])+raw).hexdigest()==h['commit']
    headers,message=raw.split(bytes([10,10]),1);lines=headers.splitlines()
    assert [x[7:].decode() for x in lines if x.startswith(b'parent ')]==[previous]
    tree=next(x[5:].decode() for x in lines if x.startswith(b'tree '));assert tree==row['tree'];trees.append(tree)
    assert next(x for x in lines if x.startswith(b'author '))==base64.b64decode(original['authorBase64'],validate=True)
    assert message==base64.b64decode(original['messageBase64'],validate=True) and row['original']==original['original'] and row['authorAndMessagePreserved'] is True
    for trailer in (b'Co-authored-by: sallyom <11166065+sallyom@users.noreply.github.com>',b'Co-authored-by: vincentkoc <25068+vincentkoc@users.noreply.github.com>'):
        assert message.count(trailer)==1
    previous=h['commit']
assert previous==m['commit'] and trees[-1]==m['tree'] and trees[1]==trees[2] and replay['steps'][2]['emptyOriginal'] is True
run=read_json('run.json');assert run=={'runId':str(producer['runId']),'attempt':'1','controller':producer['controller'],'status':'success'}
steps=read_json('step-outcomes.json')
for phase in ('materialize','dependencies','format','commit','tests','export'):assert steps[phase]['outcome']==steps[phase]['conclusion']=='success'
for phase in ('materialize','before-setup','after-setup','format','commit','tests','export'):assert read_json(phase+'.phase.json')['exitStatus']==0

def result(label,code):
    value=read_json(label+'.result.json')
    assert set(value)=={'command','startedAt','endedAt','nativeExitStatus','teeExitStatus'} and value['command']==label
    assert type(value['nativeExitStatus']) is int and value['nativeExitStatus']==code and value['teeExitStatus']==0
    return value

import shlex
prefix=['git','-c','core.hooksPath=git-hooks','-c','user.name=roboclaw-bot','-c','user.email=309084314+roboclaw-bot@users.noreply.github.com']
stops=[s['number'] for s in replay['steps'] if s['conflicts']];assert stops==[1,4,6,7,8]
sequence=[('native-rebase',1,1)]+[('native-continue-'+str(n),1,stops[i+1]) for i,n in enumerate(stops[:-1])]+[('native-continue-8',0,None)]
for label,code,next_step in sequence:
    result(label,code)
    command=shlex.split(kept(label+'.command.txt').read_text())
    expected=prefix+(['rebase','--merge','--reapply-cherry-picks','--empty=keep','--onto',m['base'],replay['oldBase'],replay['oldHead']] if label=='native-rebase' else ['rebase','--continue'])
    assert command==['env',*(['GIT_EDITOR=:'] if label!='native-rebase' else []),'GIT_TRACE2_EVENT='+producer['evidenceRoot']+'/'+label+'.trace2.jsonl',*expected]
    trace=[json.loads(line) for line in kept(label+'.trace2.jsonl').read_text().splitlines()]
    roots=[x for x in trace if x.get('event')=='start' and '/' not in x['sid']];assert len(roots)==1 and roots[0]['argv']==expected
    exits=[x for x in trace if x.get('event')=='exit' and x['sid']==roots[0]['sid']];assert len(exits)==1 and exits[0]['code']==code
    if next_step is None:continue
    step=replay['steps'][next_step-1];directory='conflict-'+str(next_step)+'/'
    assert kept(directory+'HEAD.txt').read_text().strip()==(m['base'] if next_step==1 else native[next_step-2]['actual'])
    assert kept(directory+'REBASE_HEAD').read_text().strip()==step['original']
    assert kept(directory+'rebase-merge/stopped-sha').read_text().strip()==step['original']
    assert kept(directory+'rebase-merge/onto').read_text().strip()==m['base']
    assert kept(directory+'rebase-merge/orig-head').read_text().strip()==replay['oldHead']
    rows=[x for x in replay['resolutions'] if x['step']==next_step]
    assert sorted(x['path'] for x in rows if 'stages' in x)==step['conflicts']
    wanted=''.join('100644 '+oid+' '+str(stage)+chr(9)+row['path']+chr(10) for row in rows if 'stages' in row for stage,oid in enumerate(row['stages'],1))
    assert kept(directory+'unmerged-stages.txt').read_text()==wanted
    resolution=read_json('resolution-'+str(next_step)+'.json')
    assert resolution=={'step':next_step,'original':step['original'],'tree':step['expectedRebasedTree'],'paths':[x['path'] for x in rows]}
for label in ('normal-hooks','format','provider-authority','extensions-types','core-types','plugin-test-types','bundle-create','bundle-verify'):result(label,0)
result('coordinator-red',1)
assert kept('normal-hooks.command.txt').read_text().strip()=='git -c core.hooksPath=git-hooks hook run pre-commit'
assert len(m['changedPaths'])==58 and shlex.split(kept('format.command.txt').read_text())==['pnpm','format:check',*m['changedPaths']]
assert shlex.split(kept('provider-authority.command.txt').read_text())==['pnpm','test',*m['positiveTargets'],'--maxWorkers=1','--reporter=verbose','--reporter=json','--outputFile='+producer['evidenceRoot']+'/provider-tests.json']
for label,command in [('extensions-types','pnpm tsgo:extensions'),('core-types','pnpm tsgo:core'),('plugin-test-types','pnpm tsgo:extensions:test')]:assert kept(label+'.command.txt').read_text().strip()==command
# The reviewed producer program owns restoration and its assert_commit before GREEN.
assert hash_bytes(kept('controller-recipe.sh').read_bytes())=='0e0337057eaa6ff2891bd3b39cbb283b15df15dbf92446cfc6f861cd75642269'
assert hash_bytes(kept('controller-workflow.yml').read_bytes())=='6b321d87917993878b88acd0da7a9c26982585648021a1a41c2a59d4e2493a7f'
assert kept('controller-identity.txt').read_text().splitlines()==[producer['controller'],'aab0af6c37202eee2d015f4c021d0660ed5821de','00b9ca4426edcc8112046487873244c59f7408cf']
checks=''.join(x['sha256']+'  '+x['path']+chr(10) for x in m['sourceChecks'])
for phase in ('materialize-exit','before-setup-exit','after-setup-exit','format-exit','commit-exit','tests-exit','export-exit','always'):
    assert kept(phase+'/HEAD.txt').read_text().strip()==m['commit']
    for name in ('tracked-status.txt','tracked-diff.patch','expected-tree-diff.patch','unmerged-stages.txt'):assert kept(phase+'/'+name).read_bytes()==b''
    assert kept(phase+'/source-checks.exit.txt').read_bytes()==b'0'+bytes([10])
    assert kept(phase+'/source-checks.sha256').read_text()==checks
# These exact reviewed RED/outer validators are copied below without behavioral edits.

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


capture=read_json('coordinator-red.json.capture.json')
validate_red(read_json('coordinator-red.json'),capture,producer['workspace'])
outer_paths=[p for p in member_manifest if p.startswith('outer-invocation/')]
assert outer_paths==[m['outerRecord']] and kept(m['outerRecord']).stat().st_size<=16*1024
outer=read_json(m['outerRecord']);validated=validate_outer(outer,producer['workspace']);validate_native_close(capture)
assert m['outerRecord']=='outer-invocation/'+validated['invocation']+'.json'
assert hash_bytes(kept('outer-observation.json').read_bytes())=='2534b94134b44f4063aa9d11490abd7f406325c9e42197d05fe73596bd6f8931'
assert [line.split(' b/',1)[1] for line in kept('retry-red.patch').read_text().splitlines() if line.startswith('diff --git ')]==sorted([replay['retryRegression']['path'],*[x['path'] for x in read_json('outer-observation.json')['files']]])
report=read_json('provider-tests.json');index=read_json(m['positiveReports']+'/index.json')
assert report['success'] is True and report['numPassedTests']==report['numTotalTests']==265
assert report['numFailedTests']==report['numPendingTests']==report['numTodoTests']==0
assert index['complete'] is True and index['error']=='' and len(index['entries'])==3
normal={'code':0,'exitedNormally':True,'noOutputTimedOut':False,'signal':None,'groupJoined':True}
assert index['merge']==normal and index['requested']==index['aggregate']==producer['evidenceRoot']+'/provider-tests.json'
expected_configs=['test/vitest/vitest.gateway-database-workers.config.ts','test/vitest/vitest.extension-database-workers.config.ts','test/vitest/vitest.extensions.config.ts']
all_cases=[];all_files=[]
for number,entry in enumerate(index['entries'],1):
    assert entry['invocation']==number and entry['config']==expected_configs[number-1]
    assert entry['state']=='finished' and entry['acceptedAttempt']==1 and len(entry['attempts'])==1 and entry['attempts'][0]['outcome']==normal
    rel=m['positiveReports']+'/'+str(number)+'/1/report.json'
    assert entry['attempts'][0]['json']==producer['evidenceRoot']+'/'+rel
    part=read_json(rel);facts=read_json(rel+'.capture.json')
    assert part['success'] is True and part['numFailedTests']==part['numPendingTests']==part['numTodoTests']==0
    assert part['numPassedTests']==part['numTotalTests']==[24,239,2][number-1]
    assert facts['ended']=={'reason':'passed','unhandledErrors':0,'failedModules':0,'suiteErrors':0}
    assert facts['root']==producer['workspace'] and facts['projects']==m['positiveProjects'][number-1]
    assert facts['processTimedOut'] is False and facts['ignoreUnhandledErrors'] is False and facts['passWithNoTests'] is False
    assert 'nativeInvocation' not in facts
    names=[f['name'].removeprefix(producer['workspace']+'/') for f in part['testResults']]
    assert sorted(names)==sorted(entry['includePatterns']) and len(facts['modules'])==len(names)
    assert sorted(x['file'] for x in facts['modules'])==sorted(f['name'] for f in part['testResults'])
    all_files+=names
    for file in part['testResults']:
        assert file['status']=='passed' and file['message']==''
        for case in file['assertionResults']:
            assert case['status']=='passed' and case['failureMessages']==[]
            all_cases.append((file['name'],case['fullName'],case['status']))
assert len(all_files)==len(set(all_files))==12 and sorted(all_files)==sorted(m['positiveTargets'])
aggregate_cases=[(file['name'],case['fullName'],case['status']) for file in report['testResults'] for case in file['assertionResults']]
assert len(report['testResults'])==12 and len(aggregate_cases)==265 and sorted(aggregate_cases)==sorted(all_cases)
recovery=[name for _,name,_ in all_cases if 'capture recovery precedence preserves the original ' in name]
assert sorted(recovery)==sorted(m['recoveryCases']) and len(recovery)==4
(e/'producer-custody.json').write_text(json.dumps({'producer':producer,'nativeStops':stops,'historyCount':10,'fullGreenFiles':12,'fullGreenPassed':265,'lateRecoveryCases':recovery,'controlledRed':True,'outerCompletion':True,'restoration':True,'allTypesPassed':True},indent=2)+chr(10))

PY
    # The only prerequisite is B, already checked out with complete history.
    # verify/unbundle transport real objects; neither constructs a new commit.
    run_logged committed-bundle-verify git bundle verify "$evidence/retained/candidate.bundle"
    run_logged committed-bundle-import git bundle unbundle "$evidence/retained/candidate.bundle"
    python3 - "$payload" "$evidence" <<'PY'
from pathlib import Path
import base64,hashlib,json,subprocess,sys
m=json.loads(Path(sys.argv[1]).read_text());e=Path(sys.argv[2])
def git(*a):return subprocess.check_output(['git',*a])
actual=git('rev-list','--reverse',m['base']+'..'+m['commit']).decode().splitlines()
assert actual==[s['commit'] for s in m['history']] and len(actual)==10
assert not git('rev-list','--merges',m['base']+'..'+m['commit'])
parent=m['base'];rows=[]
for i,sha in enumerate(actual):
    raw=git('cat-file','commit',sha);(e/('raw-'+sha+'.commit')).write_bytes(raw)
    assert hashlib.sha1(b'commit '+str(len(raw)).encode()+bytes([0])+raw).hexdigest()==sha
    headers,msg=raw.split(bytes([10,10]),1);lines=headers.splitlines()
    assert [x[7:].decode() for x in lines if x.startswith(b'parent ')]==[parent]
    tree=next(x[5:].decode() for x in lines if x.startswith(b'tree '))
    s=m['history'][i]
    assert raw==base64.b64decode(s['rawBase64'],validate=True)
    assert tree==s['expectedRebasedTree']
    assert hashlib.sha256(raw).hexdigest()==s['rawSha256']
    assert raw==(e/('retained/raw-'+sha+'.commit')).read_bytes()
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
      node --version > "$evidence/node-version.txt"
      pnpm --version > "$evidence/pnpm-version.txt"
      expected_pnpm="$(node -p 'JSON.parse(require("fs").readFileSync("package.json", "utf8")).packageManager.split("@")[1].split("+")[0]')"
      test "$(pnpm --version)" = "$expected_pnpm"
    fi
    ;;
  export)
    assert_candidate
    # Retain exact producer bytes. No bundle create/repack or commit in a gate.
    cp "$evidence/retained/candidate.bundle" "$RUNNER_TEMP/candidate.bundle"
    cmp "$evidence/retained/candidate.bundle" "$RUNNER_TEMP/candidate.bundle"
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
