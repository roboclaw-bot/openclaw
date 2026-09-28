#!/usr/bin/env bash
# Controller-owned source admission shared by the five existing pre-push suites.
# C is imported once per isolated job from the producer's identical bundle bytes.
set -euo pipefail
base=e433bfda89c486f98dfb03586dacd1e23b6f820b
replayed_head=43d74a393a72e7da12456d66079ee291acc2f114
tree='6e181a3dd95b720f9bfbac1b7804c6ce23df431b'
candidate='5d116aa3f1e0d85f9408d95cce0640926a8d8c60'
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
test "$PATCH_SHA256" = 'e066f0eb79ebe75dc93f88cfacfe1a0049e04273971c33044a263d879dfbf2b2'
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
assert m['commit']=='5d116aa3f1e0d85f9408d95cce0640926a8d8c60' and m['tree']=='6e181a3dd95b720f9bfbac1b7804c6ce23df431b'
for x in m['retained']:
    assert set(x)=={'path','mode','bytes','sha256','base64'} and x['mode']=='100644'
    assert Path(x['path']).name==x['path'] and x['path'] not in ('','.','..')
    b=base64.b64decode(x['base64'],validate=True)
    assert len(b)==x['bytes'] and hashlib.sha256(b).hexdigest()==x['sha256']
    target=r/x['path'];assert not target.exists();target.write_bytes(b)
# Exact genuine rebase producer custody. Native schema is retained, never translated.
producer=m['producer']; receipt=json.loads((r/'candidate.json').read_bytes())
assert receipt['commit']==m['commit'] and receipt['tree']==m['tree'] and receipt['base']==m['base']
assert receipt['parent']==m['parent'] and receipt['bundleSha256']==m['bundleSha256']
assert receipt['controller']==producer['controller'] and receipt['runId']==str(producer['runId']) and receipt['attempt']==str(producer['attempt'])
assert producer['runConclusion']==producer['jobConclusion']=='success'
assert hashlib.sha256((r/'candidate.bundle').read_bytes()).hexdigest()==m['bundleSha256']
native=json.loads((r/'history.json').read_bytes());assert native==receipt['replay'] and len(native)==len(m['history'])==10
previous=m['base']; trees=[]
for h,row in zip(m['history'],native,strict=True):
    assert row['actual']==h['commit'] and row['parent']==previous and row['tree']==h['expectedRebasedTree']
    raw=(r/('raw-'+h['commit']+'.commit')).read_bytes()
    assert raw==base64.b64decode(h['rawBase64'],validate=True) and hashlib.sha256(raw).hexdigest()==h['rawSha256']
    assert hashlib.sha1(b'commit '+str(len(raw)).encode()+bytes([0])+raw).hexdigest()==h['commit']
    headers,message=raw.split(bytes([10,10]),1);lines=headers.splitlines()
    assert [x[7:].decode() for x in lines if x.startswith(b'parent ')]==[previous]
    tree=next(x[5:].decode() for x in lines if x.startswith(b'tree '));assert tree==h['expectedRebasedTree'];trees.append(tree)
    assert row['authorAndMessagePreserved'] is True
    previous=h['commit']
assert previous==m['commit'] and trees[-1]==m['tree'] and trees[1]==trees[2]
run=json.loads((r/'run.json').read_bytes());assert run['runId']==str(producer['runId']) and run['attempt']==str(producer['attempt']) and run['controller']==producer['controller'] and run['status']=='success'
steps=json.loads((r/'step-outcomes.json').read_bytes())
for phase in ('materialize','dependencies','format','commit','tests','export'):assert steps[phase]['outcome']=='success'
for phase in ('materialize','before-setup','after-setup','format','commit','tests','export'):assert json.loads((r/(phase+'.phase.json')).read_bytes())['exitStatus']==0
for label in ('native-rebase','normal-hooks','format','provider-authority','extensions-types','core-types','plugin-test-types','bundle-create','bundle-verify'):
    result=json.loads((r/(label+'.result.json')).read_bytes());assert result['nativeExitStatus']==result['teeExitStatus']==0
assert b'rebase --merge --reapply-cherry-picks --empty=keep --onto' in (r/'native-rebase.command.txt').read_bytes()
assert (r/'native-rebase.trace2.jsonl').stat().st_size>0
(e/'producer-custody.json').write_text(json.dumps(producer,indent=2)+chr(10))

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
