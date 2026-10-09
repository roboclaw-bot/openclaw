#!/usr/bin/env bash
# Held P proof: one native attributed commit after canonical format/hook admission.
set -euo pipefail
old=3e90389813229bd33c169fb07b883b567847224e
common=3e90389813229bd33c169fb07b883b567847224e
base=3e90389813229bd33c169fb07b883b567847224e
replayed_tree=0626fcb2effa131169278b3c9be959baf407fded
tree=0626fcb2effa131169278b3c9be959baf407fded
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
test "$PATCH_SHA256" = 6cc4f8b755252fc55015bc459caef362a02047577bc3e08607733a7019d7badf
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
assert_commit() {
  assert_candidate
  test "$(git rev-parse HEAD)" = "$(cat "$evidence/rebased-head.txt")"
  test "$(git rev-parse HEAD^{tree})" = "$tree"
  test "$(git show -s --format=%P HEAD)" = "$base"
  git diff --quiet HEAD
  python3 - "$payload" "$evidence" <<'PY'
from pathlib import Path
import base64,json,subprocess,sys
m=json.loads(Path(sys.argv[1]).read_text());e=Path(sys.argv[2]);raw=subprocess.check_output(['git','cat-file','commit','HEAD']);h,msg=raw.split(b'\n\n',1)
assert msg==base64.b64decode(m['commitMessageBase64'])
a=next(x.decode() for x in h.splitlines() if x.startswith(b'author '));assert a.startswith('author '+m['commitAuthor']+' ')
assert subprocess.check_output(['git','rev-list','--count',m['base']+'..HEAD']).strip()==b'1'
(e/'P-native.commit').write_bytes(raw)
PY
}
validate_store_report() {
  python3 - "$1" "$2" "$GITHUB_WORKSPACE" <<'PY'
from pathlib import Path
import json
import re
import sys

FILE = 'extensions/crabbox/src/crabbox-worker-warm-image-store.test.ts'
PROJECT = 'extension-database-workers'
CONFIG = 'test/vitest/vitest.extension-database-workers.config.ts'
TASK_ID = '-1701623718'
STORE_SUITE = 'Crabbox asynchronous warm-image mutations'
LOGICAL_SUITE = 'Crabbox snapshot mutation final write authority'
SINGLES = [
    'preserves and projects a native-capture refusal through allocation updates',
    'rejects malformed native-capture refusal markers before reading or updating state',
    'rechecks retirement and preserves sibling allocations after a comparison conflict',
    'discards a capacity rejection when the compared row gained room',
    'does not replay a mutation whose completion is unavailable',
    'returns the committed checkpoint projection after its row is replaced',
]
EXISTING = [*SINGLES,
    *['rejects an accepted allocation whose owner is '+value+' before publication'
      for value in ['removed', 'replaced', 'conflicting']],
    *['refuses replay dispatch when its durable owner is '+value+' before comparison'
      for value in ['profile removed', 'allocation removed', 'allocation changed']],
]
MAIN = [*EXISTING,
    *['drains an admitted '+action+' write before provider disposal settles'
      for action in ['pin', 'rollback']],
]
BEFORE = ['refuses and drains a '+action+' held before comparison dispatch when disposed'
          for action in ['pin', 'rollback']]
AFTER = ['preserves and drains a '+action+' granted before provider disposal'
         for action in ['pin', 'rollback']]
SELECTED = {
    'refuses and drains a '+action+' disposed at native '+boundary+' admission': boundary
    for action in ['pin', 'rollback'] for boundary in ['transaction', 'commit']
}
LOGICAL = [action+' honors invocation closure at '+boundary+' with a live physical signal'
           for action in ['pin', 'rollback']
           for boundary in ['transaction', 'commit', 'after commit grant']]
P_STORE = [*EXISTING, *BEFORE, *AFTER, *SELECTED]


def require(condition, code):
    if not condition:
        raise ValueError(code)


def native_assertion(error, root, site, kind):
    # JSON reports native Error.stack || Error.message, not console diff output.
    require(type(error) is str and 0 < len(error) <= 32768, 'native-error-string')
    lines = error.splitlines()
    require(bool(lines), 'native-error-empty')
    header = lines[0]
    frames = lines[1:]
    if kind == 'fulfilled':
        # Chai may summarize the projection. The summary's status/value keys
        # distinguish the source's fulfilled alternative from status/error.
        actual = r"(?:\{ status: 'fulfilled', [^\r\n]+ \}|\{ Object \(status, value\) \})"
        expected = r"(?:\{ status: 'rejected', [^\r\n]+ \}|\{ Object \(status, error\) \})"
        require(re.fullmatch('AssertionError: expected '+actual+' to match object '+expected,
                             header) is not None, 'native-soft-outcome-shape')
        # toMatchObject drops the fulfilled value projection: one value key
        # plus the 23 own keys of the unchanged projectCrabboxWarmImage result.
        require(bool(frames) and frames[0] == '(24 matching properties omitted from actual)',
                'native-soft-subset-omission')
        frames = frames[1:]
    elif kind == 'stages':
        require(header == "AssertionError: expected [ 'transaction', 'commit' ] to deeply equal [ 'transaction' ]",
                'native-transaction-stage-shape')
    else:
        require(kind == 'decisions', 'native-error-kind')
        # Chai's array/object display can omit granted entirely. Its native
        # array-equality message plus the exact unchanged line530 callsite is
        # the contract; rendered expected/received console diffs are not read.
        require(re.fullmatch(r'AssertionError: expected \[ [^\r\n]+ \] to deeply equal \[ [^\r\n]+ \]',
                             header) is not None, 'native-commit-decision-shape')
    require(bool(frames) and all(re.fullmatch(r'\s+at .+', line) for line in frames),
            'native-extra-diagnostic-or-missing-stack')
    # Pin the original assertion identity, not an arbitrary AssertionError or
    # a matching token in a setup/cleanup error. Other stack frames may be
    # dependency internals; the sole frame in this exact test file must match.
    owner = re.compile(r'(?:file://)?'+re.escape(root+'/'+FILE)+r':([1-9][0-9]*):([1-9][0-9]*)(?:\)|$)')
    sites = [int(match[1]) for line in frames for match in owner.finditer(line)]
    require(sites == [site], 'native-assertion-source-site')


def validate_store_report(report, capture, kind, root):
    require(kind in ['main', 'green', 'red'], 'native-mode')
    require(type(report) is dict and type(capture) is dict, 'native-report-shape')
    red = kind == 'red'
    inventory = ([(STORE_SUITE, title) for title in MAIN] if kind == 'main' else
                 [(STORE_SUITE, title) for title in P_STORE]+
                 [(LOGICAL_SUITE, title) for title in LOGICAL])
    total = 14 if kind == 'main' else 26
    require(len(inventory) == len(set(inventory)) == total, 'controller-inventory')
    project = dict(name=PROJECT, namePrefix='', root=root, config=root+'/'+CONFIG, pool='openclaw-forks')
    require(type(capture.get('pid')) is int and capture['pid'] > 0, 'native-pid')
    require(capture.get('root') == root, 'native-root')
    require(capture.get('projects') == [project], 'native-project')
    require(capture.get('modules') == [{**project, 'file':root+'/'+FILE, 'taskId':TASK_ID}], 'native-module')
    for key in ['processTimedOut', 'ignoreUnhandledErrors', 'passWithNoTests']:
        require(capture.get(key) is False, 'native-'+key)
    require(capture.get('ended') == dict(reason='failed' if red else 'passed',
            unhandledErrors=0, failedModules=1 if red else 0, suiteErrors=0), 'native-completion')
    suites = 2 if kind == 'main' else 3
    counts = dict(numTotalTests=total, numTodoTests=0, numFailedTests=4 if red else 0,
                  numPendingTests=22 if red else 0, numPassedTests=0 if red else total,
                  numTotalTestSuites=suites, numFailedTestSuites=2 if red else 0,
                  numPassedTestSuites=1 if red else suites, numPendingTestSuites=0)
    require(all(type(report.get(k)) is int and report[k] == v for k,v in counts.items()), 'native-counts')
    require(report.get('success') is (not red), 'native-success')
    files = report.get('testResults')
    require(type(files) is list and len(files) == 1 and type(files[0]) is dict, 'native-file-count')
    file = files[0]
    require(file.get('name') == root+'/'+FILE and file.get('message') == '' and
            file.get('status') == ('failed' if red else 'passed'), 'native-file-identity-or-error')
    cases = file.get('assertionResults')
    require(type(cases) is list and len(cases) == total and all(type(c) is dict for c in cases), 'native-case-count')
    actual = []
    for case in cases:
        ancestors = case.get('ancestorTitles')
        title = case.get('title')
        require(type(ancestors) is list and len(ancestors) == 1 and type(ancestors[0]) is str and
                type(title) is str, 'native-case-identity-shape')
        require(case.get('fullName') == ancestors[0]+' '+title, 'native-case-full-name')
        actual.append((ancestors[0], title))
    require(sorted(actual) == sorted(inventory), 'native-complete-case-inventory')
    for case in cases:
        title = case['title']
        if red and title in SELECTED:
            require(case['ancestorTitles'] == [STORE_SUITE] and case.get('status') == 'failed', 'native-selected-status')
            errors = case.get('failureMessages')
            require(type(errors) is list and len(errors) == 2, 'native-selected-error-count')
            native_assertion(errors[0], root, 519, 'fulfilled')
            boundary = SELECTED[title]
            native_assertion(errors[1], root, 527 if boundary == 'transaction' else 530,
                             'stages' if boundary == 'transaction' else 'decisions')
        else:
            require(case.get('status') == ('skipped' if red else 'passed') and
                    case.get('failureMessages') == [], 'native-unselected-error-or-status')
    if not red:
        require('nativeInvocation' not in capture, 'native-green-overlay-not-restored')
    return {'kind':kind, 'tests':total, 'failed':counts['numFailedTests'],
            'taskId':TASK_ID, 'nativeOwnerCompletion':True}


if __name__ == '__main__':
    name,kind,root = sys.argv[1:]
    print(json.dumps(validate_store_report(json.loads(Path(name).read_text()),
                     json.loads(Path(name+'.capture.json').read_text()), kind, root)))
PY
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

    python3 - "$payload" "$evidence" <<'PY'
from pathlib import Path
import json,base64,hashlib,sys,subprocess
m=json.loads(Path(sys.argv[1]).read_text());e=Path(sys.argv[2]);data=base64.b64decode(m['patchBase64'],validate=True)
assert hashlib.sha256(data).hexdigest()==m['patchSha256'];(e/'P.patch').write_bytes(data)
subprocess.run(['git','apply','--index','--check',str(e/'P.patch')],check=True)
subprocess.run(['git','apply','--index',str(e/'P.patch')],check=True)
assert subprocess.check_output(['git','diff','--cached','--name-only']).decode().splitlines()==m['changedPaths']
PY
    assert_candidate
    git diff --cached --check
    ;;
  before-setup|after-setup)
    assert_candidate
    test "$(git rev-parse HEAD)" = "$base"
    if [[ "$phase" == after-setup ]]; then
      node --version > "$evidence/node-version.txt"
      pnpm --version > "$evidence/pnpm-version.txt"
      test "$(pnpm --version)" = 12.7.0
    fi
    ;;
  format)
    assert_candidate
    mapfile -t files < <(jq -r '.changedPaths[]' "$payload")
    run_logged format pnpm format:check "${files[@]}"
    assert_candidate
    ;;
  commit)
    assert_candidate
    python3 - "$payload" "$evidence/commit-message.txt" <<'PY'
from pathlib import Path
import base64,json,sys
Path(sys.argv[2]).write_bytes(base64.b64decode(json.loads(Path(sys.argv[1]).read_text())['commitMessageBase64']))
PY
    run_logged native-P-commit git -c core.hooksPath=git-hooks -c user.name=roboclaw-bot -c user.email=309084314+roboclaw-bot@users.noreply.github.com commit --file "$evidence/commit-message.txt"
    git rev-parse HEAD > "$evidence/rebased-head.txt"
    assert_commit
    run_logged normal-hooks git -c core.hooksPath=git-hooks hook run pre-commit
    assert_commit
    ;;
  tests)
    assert_commit
    store=extensions/crabbox/src/crabbox-worker-warm-image-store.test.ts
    (
      restore_P() { git checkout --detach "$(cat "$evidence/rebased-head.txt")"; }
      trap restore_P EXIT
      git checkout --detach "$base"
      test "$(git rev-parse HEAD)" = "$base"
      git diff --quiet HEAD
      run_logged main-store pnpm test "$store" --maxWorkers=1 --reporter=json --reporter="$GITHUB_WORKSPACE/scripts/lib/vitest-report-capture.mts" --outputFile.json="$evidence/main-store.json"
      validate_store_report "$evidence/main-store.json" main
      git diff --quiet HEAD
    )
    assert_commit
    (
      restore_RED() {
        git restore --source=HEAD --worktree -- extensions/crabbox/src/crabbox-worker-warm-image-store.ts extensions/crabbox/src/crabbox-worker-warm-image.ts scripts/lib/failed-trailer.mts scripts/lib/vitest-report-capture.mts scripts/lib/vitest-worker-run.mts scripts/test-projects-run.mts
      }
      trap restore_RED EXIT
      git restore --source="$base" --worktree -- extensions/crabbox/src/crabbox-worker-warm-image-store.ts extensions/crabbox/src/crabbox-worker-warm-image.ts
      test "$(sha256sum "$RUNNER_TEMP/outer-observation.json" | cut -c 1-64)" = b87d0575feb7212e0486b7a0e20a6c04c38e5a675b039eeede1293f4c07e3755
      test "${OPENCLAW_VITEST_WORKER_CACHE:-}" != 1
      python3 - "$RUNNER_TEMP/outer-observation.json" "$tree" "$evidence" <<'PY'
from pathlib import Path
import json,base64,hashlib,sys,subprocess
m=json.loads(Path(sys.argv[1]).read_text());assert m['candidateTree']==sys.argv[2]
for f in m['files']:
    p=Path(f['path']);assert p.is_file() and not p.is_symlink() and all(not a.is_symlink() for a in p.parents)
    assert hashlib.sha256(p.read_bytes()).hexdigest()==f['beforeSha256'];data=base64.b64decode(f['base64'],validate=True)
    assert len(data)==f['bytes'] and hashlib.sha256(data).hexdigest()==f['afterSha256'];p.write_bytes(data)
paths=['extensions/crabbox/src/crabbox-worker-warm-image-store.ts','extensions/crabbox/src/crabbox-worker-warm-image.ts',*[f['path'] for f in m['files']]]
assert subprocess.check_output(['git','diff','--name-only']).decode().splitlines()==sorted(paths)
(Path(sys.argv[3])/'P-red.patch').write_bytes(subprocess.check_output(['git','diff','--binary','--full-index']))
PY
      mkdir "$evidence/outer-invocation"
      status=0
      run_logged P-red env PR159178_RED_OUTCOME_DIRECTORY="$evidence/outer-invocation" pnpm test "$store" --maxWorkers=1 --testNamePattern 'disposed at native' --reporter=json --reporter="$GITHUB_WORKSPACE/scripts/lib/vitest-report-capture.mts" --outputFile.json="$evidence/P-red.json" || status=$?
      test "$status" -eq 1
      test "$last_native" -eq 1
      test "$last_tee" -eq 0
      validate_store_report "$evidence/P-red.json" red
      python3 - "$evidence/outer-invocation" "$GITHUB_WORKSPACE" "$evidence/P-red.json.capture.json" <<'PY'
from pathlib import Path
import json
import re
import sys

FILE = 'extensions/crabbox/src/crabbox-worker-warm-image-store.test.ts'
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
    assert_commit
    run_logged P-store pnpm test "$store" --maxWorkers=1 --reporter=json --reporter="$GITHUB_WORKSPACE/scripts/lib/vitest-report-capture.mts" --outputFile.json="$evidence/P-store.json"
    validate_store_report "$evidence/P-store.json" green
    assert_commit
    mapfile -t targets < <(jq -r '.positiveTargets[1:][]' "$payload")
    run_logged snapshot-siblings pnpm test "${targets[@]}" --maxWorkers=1 --reporter=verbose --reporter=json --outputFile="$evidence/snapshot-siblings.json"
    assert_commit
    run_logged extensions-types pnpm tsgo:extensions
    assert_commit
    run_logged core-types pnpm tsgo:core
    assert_commit
    run_logged plugin-test-types pnpm tsgo:extensions:test
    assert_commit
    run_logged changed-check pnpm check:changed --base "$base" --head HEAD --timed
    assert_commit
    ;;
  export)
    assert_commit
    run_logged bundle-create git bundle create "$RUNNER_TEMP/candidate.bundle" "$base..HEAD"
    run_logged bundle-verify git bundle verify "$RUNNER_TEMP/candidate.bundle"
    jq -n --arg commit "$(git rev-parse HEAD)" --arg base "$base" --arg tree "$tree" --arg payload "$PATCH_SHA256" --arg controller "$GITHUB_SHA" --arg run "$GITHUB_RUN_ID" --arg attempt "$GITHUB_RUN_ATTEMPT" --arg bundle "$(sha256sum "$RUNNER_TEMP/candidate.bundle" | cut -d ' ' -f1)" '{commit:$commit,parent:$base,base:$base,tree:$tree,payloadSha256:$payload,suite:"provider-rebase-focused",mode:"pin-rollback-first-native-commit",controller:$controller,runId:$run,attempt:$attempt,bundleSha256:$bundle,scope:"Exact M store suite, controlled P native refusal RED/outer/restoration, full P store and snapshot siblings, canonical hooks/format/production and plugin test types/changed-check; full build and R separately admitted"}' > "$RUNNER_TEMP/candidate.json"
    cp "$RUNNER_TEMP/candidate.json" "$evidence/candidate.json"
    ;;
  *) exit 2 ;;
esac
