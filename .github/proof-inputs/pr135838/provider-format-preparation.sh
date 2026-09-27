#!/usr/bin/env bash
# REVIEWED CI RECIPE: preparation only; never commit, rebase, adopt, or validate runtime.
set -Eeuo pipefail
export GIT_OPTIONAL_LOCKS=0 GIT_NO_LAZY_FETCH=1
export FORMAT_EVIDENCE="$RUNNER_TEMP/pr159178-format-preparation"
mkdir -p "$FORMAT_EVIDENCE"
mode="${1:-prepare}"
case "$mode:$#" in before-setup:1|prepare:0|prepare:1) ;; *) exit 2 ;; esac
files=(
  extensions/crabbox/src/crabbox-worker-warm-image-admission.test-support.ts
  extensions/crabbox/src/crabbox-worker-warm-image-authority.test.ts
  extensions/crabbox/src/crabbox-worker-warm-image-capture.ts
  extensions/crabbox/src/crabbox-worker-warm-image-sibling-admission.test-support.ts
  extensions/crabbox/src/crabbox-worker-warm-image-sibling-admission.test.ts
  extensions/crabbox/src/crabbox-worker-warm-image-store.test.ts
  src/plugin-sdk/sqlite-runtime-testing.ts
  test/helpers/sqlite-worker-admission.ts
)
printf '%s\n' "${files[@]}" > "$FORMAT_EVIDENCE/allowed-paths.txt"
cat > "$FORMAT_EVIDENCE/before-eight.sha256" <<'HASHES'
0a35c10e67ffd6caa77bcd86707ef7639d0a503c9a4895029fc414d56b3bb94c  extensions/crabbox/src/crabbox-worker-warm-image-admission.test-support.ts
38fcc1e2c7584ff30b61cd0e43dbce7648724db7bff7abc6b5774cda803b103f  extensions/crabbox/src/crabbox-worker-warm-image-authority.test.ts
d8b950dbf93c5447dd4a2964c5baae92c3200cd88ba600f24807fc43ac36e102  extensions/crabbox/src/crabbox-worker-warm-image-capture.ts
4cd401b936bb5cdb81f099eb978c5d9c631f811c8722a2bbe72d153c1ce06484  extensions/crabbox/src/crabbox-worker-warm-image-sibling-admission.test-support.ts
33da919d109d279fdac327f18005e64f80b858d2fe4807ebab6c756d677be089  extensions/crabbox/src/crabbox-worker-warm-image-sibling-admission.test.ts
cd9ed6dc1459d4cb7b44c26c04b3a09993bc6a285f2b86313a0b732b39010047  extensions/crabbox/src/crabbox-worker-warm-image-store.test.ts
9bdc44ada90697a0c4abadae6e4bbebe32f1b42c2cbcc6efa3d33920b017149d  src/plugin-sdk/sqlite-runtime-testing.ts
2288e34c223bf0621cb969dd16498340abbb5a2e2ba5874590ef3a4246e627bc  test/helpers/sqlite-worker-admission.ts
HASHES

# Hash every tracked source byte and executable/symlink mode, not mtimes or
# formatter output. Ignored dependency/build products are not source inputs.
snapshot() {
  python3 - "$1" <<'PY'
import hashlib, json, os, stat, subprocess, sys
from pathlib import Path
root = Path(os.environ['FORMAT_EVIDENCE']) / sys.argv[1]
root.mkdir(exist_ok=True)
def git(*args):
    return subprocess.check_output(['git', '-c', 'core.fsmonitor=false', *args])
def digest(data):
    return hashlib.sha256(data).hexdigest()
entries = git('ls-files', '--stage', '-z')
(root / 'index-entries.z').write_bytes(entries)
tracked = []
for raw in git('ls-files', '-z').split(bytes([0])):
    if not raw:
        continue
    name = os.fsdecode(raw)
    path = Path(name)
    try:
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode):
            data = os.fsencode(os.readlink(path))
            mode = '120000'
        elif stat.S_ISREG(info.st_mode):
            data = path.read_bytes()
            mode = '100755' if info.st_mode & 0o111 else '100644'
        else:
            tracked.append({'path': name, 'error': 'not regular or symlink'})
            continue
        tracked.append({'path': name, 'mode': mode, 'sha256': digest(data), 'bytes': len(data)})
    except OSError as error:
        tracked.append({'path': name, 'error': type(error).__name__})
source = {
    'head': git('rev-parse', 'HEAD').decode().strip(),
    'indexTree': git('write-tree').decode().strip(),
    'indexEntriesSha256': digest(entries),
    'unmerged': git('ls-files', '--unmerged', '-z').decode(),
    'untracked': git('ls-files', '--others', '--exclude-standard', '-z').decode().split(chr(0))[:-1],
    'tracked': tracked,
}
(root / 'source.json').write_text(json.dumps(source, indent=2) + '\n')
for filename, args in [
    ('status.txt', ['status', '--porcelain=v1', '--untracked-files=all']),
    ('head-diff.patch', ['diff', '--binary', '--full-index', 'HEAD']),
    ('expected-worktree.patch', ['diff', '--binary', '--full-index', os.environ['EXPECTED_TREE']]),
    ('expected-index.patch', ['diff', '--binary', '--full-index', '--cached', os.environ['EXPECTED_TREE']]),
    ('index-worktree.patch', ['diff', '--binary', '--full-index']),
]:
    (root / filename).write_bytes(git(*args))
PY
}

require_input_tree() {
  test "$(git rev-parse HEAD)" = "$BASE_SHA"
  test "$(git write-tree)" = "$EXPECTED_TREE"
  test -z "$(git ls-files --unmerged)"
  git diff --quiet
  git diff --cached --check
  sha256sum --check "$FORMAT_EVIDENCE/before-eight.sha256"
}

run_record() {
  local name="$1"; shift
  local start end
  start="$(date -u +%FT%T.%NZ)"
  printf '%s\0' "$@" > "$FORMAT_EVIDENCE/$name.argv.z"
  printf '%q ' "$@" > "$FORMAT_EVIDENCE/$name.argv.txt"
  printf '\n' >> "$FORMAT_EVIDENCE/$name.argv.txt"
  set +e
  "$@" 2>&1 | tee "$FORMAT_EVIDENCE/$name.log"
  local status=("${PIPESTATUS[@]}")
  set -e
  end="$(date -u +%FT%T.%NZ)"
  printf '{"startedAt":"%s","finishedAt":"%s","nativeExit":%s,"teeExit":%s}\n' \
    "$start" "$end" "${status[0]}" "${status[1]}" > "$FORMAT_EVIDENCE/$name.exit.json"
  if (( status[0] != 0 )); then return "${status[0]}"; fi
  if (( status[1] != 0 )); then return "${status[1]}"; fi
  test -s "$FORMAT_EVIDENCE/$name.log"
}

# Failed commands retain their real exit plus all available source/proposal bytes.
# This collector cannot turn a failed formatter, check, capture, or guard green.
finish() {
  local rc="$?" capture_rc=0
  trap - EXIT
  set +e
  snapshot final
  capture_rc="$?"
  if (( rc == 0 && capture_rc != 0 )); then rc="$capture_rc"; fi
  mkdir -p "$FORMAT_EVIDENCE/after-files" || rc=1
  for path in "${files[@]}"; do
    if [[ -f "$path" && ! -L "$path" ]]; then
      mkdir -p "$FORMAT_EVIDENCE/after-files/$(dirname "$path")" || rc=1
      cp -- "$path" "$FORMAT_EVIDENCE/after-files/$path" || rc=1
    else
      rc=1
    fi
  done
  if (( rc == 0 )); then
    (cd "$FORMAT_EVIDENCE/after-files" && sha256sum --check ../after-eight.sha256) || rc=1
  fi
  git diff --binary --full-index "$EXPECTED_TREE" > "$FORMAT_EVIDENCE/actual-worktree.patch" || rc=1
  git diff --binary --full-index --cached "$EXPECTED_TREE" > "$FORMAT_EVIDENCE/actual-index.patch" || rc=1
  python3 - "$rc" "$capture_rc" <<'PY'
import hashlib, json, os, sys
from datetime import datetime, timezone
from pathlib import Path
root = Path(os.environ['FORMAT_EVIDENCE'])
def load(name):
    path = root / name
    return json.loads(path.read_text()) if path.is_file() else None
def digest(name):
    path = root / name
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None
final = load('final/source.json')
receipt = {
    'status': 'PROPOSAL_ONLY_UNADOPTED' if sys.argv[1] == '0' else 'FAILED_UNADOPTED',
    'proposalOnly': True, 'adopted': False, 'runtimeValidated': False, 'nativeHistoryProof': False,
    'exitCode': int(sys.argv[1]), 'captureExitCode': int(sys.argv[2]),
    'finishedAt': datetime.now(timezone.utc).isoformat(),
    'runId': os.environ['GITHUB_RUN_ID'], 'attempt': os.environ['GITHUB_RUN_ATTEMPT'],
    'controller': os.environ['GITHUB_SHA'], 'hosted': os.environ.get('FORMAT_HOSTED'),
    'base': os.environ['BASE_SHA'], 'beforeTree': os.environ['EXPECTED_TREE'],
    'head': final['head'] if final else None, 'headIsOnlyMaterializationBase': True,
    'formattedIndexTree': final['indexTree'] if final else None,
    'noOp': final['indexTree'] == os.environ['EXPECTED_TREE'] if sys.argv[1] == '0' and final else None,
    'actualChangedPaths': load('actual-changed-paths.json'),
    'format': load('format.exit.json'), 'formatCheck': load('format-check.exit.json'),
    'inputPatchSha256': os.environ['PATCH_SHA256'],
    'formattingPatchSha256': digest('formatting.patch'),
    'beforeEightManifestSha256': digest('before-eight.sha256'),
    'afterEightManifestSha256': digest('after-eight.sha256'),
    'sourceBeforeSetupSha256': digest('before-setup/source.json'),
    'sourceBeforeFormatSha256': digest('before-format/source.json'),
    'sourceAfterFormatSha256': digest('after-format/source.json'),
    'sourceFinalSha256': digest('final/source.json'),
    'next': 'Parent review/adoption only, including a valid empty delta; normal hooks and actual-candidate validation remain separate. No automatic adoption or publication-policy decision.',
}
(root / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
PY
  if (( $? != 0 )); then rc=1; fi
  if (( rc != 0 )); then printf '[provider-format-preparation] FAILED (exit %s)\n' "$rc" >&2; fi
  exit "$rc"
}
if [[ "$mode" == prepare ]]; then trap finish EXIT; fi

test "$SUITE" = provider-format-preparation
test "$PATCH_ID" = provider-format-preparation
test "$BASE_SHA" = fd0b54a58f93b68a49eb07695705cd770ebb91b1
test "$EXPECTED_TREE" = b1c1331382cae5f993b46cc0e1495e9ba60d690d
test "$PATCH_SHA256" = ab6489032d4c91fa7a897ba4a159779b39bb9cf1b4170b7976ab19265ea07dab
test "$GITHUB_EVENT_NAME" = workflow_dispatch
test "$GITHUB_REPOSITORY" = roboclaw-bot/openclaw
test "$GITHUB_REF" = refs/heads/main
test "$GITHUB_SHA" = "$REBASE_WORKFLOW_SHA"
test "$FORMAT_HOSTED" = github-hosted
test "$RUNNER_OS" = Linux
test "$(sha256sum "$0" | cut -d ' ' -f1)" = "$FORMAT_RECIPE_SHA256"
require_input_tree
if [[ "$mode" == before-setup ]]; then
  snapshot before-setup
  exit 0
fi
snapshot before-format
cmp "$FORMAT_EVIDENCE/before-setup/source.json" "$FORMAT_EVIDENCE/before-format/source.json"
node --version > "$FORMAT_EVIDENCE/node-version.txt"
pnpm --version > "$FORMAT_EVIDENCE/pnpm-version.txt"
git --version > "$FORMAT_EVIDENCE/git-version.txt"
test "$(cat "$FORMAT_EVIDENCE/node-version.txt")" = v24.19.0
test "$(cat "$FORMAT_EVIDENCE/pnpm-version.txt")" = 12.5.0
python3 - <<'PY'
import json
from pathlib import Path
p = json.loads(Path('package.json').read_text())
assert p['scripts']['format'] == 'oxfmt --write --threads=1'
assert p['scripts']['format:check'] == 'oxfmt --check'
assert p['devDependencies']['oxfmt'] == '0.68.0'
assert p['packageManager'] == 'pnpm@12.5.0+sha512.9cdbaa34ffacae1768635ac0d23e94db6201c7d59bf3da236b23d67c8f6b794d1dab323bcd5bcc51b55c8cafbf6f19a24e4aa61d6ab7772aa3b5cc85e325dc4d'
PY
git diff --name-only --no-renames -z 0edae198d278686e16426f7ad254d0341bd6e3d3 "$EXPECTED_TREE" > "$FORMAT_EVIDENCE/check-paths.z"
test "$(sha256sum "$FORMAT_EVIDENCE/check-paths.z" | cut -d ' ' -f1)" = 25e952f5418ada9bcbea0cff045fc698eee7ba087647e5003f662fbe8f30885e
mapfile -d '' -t check_paths < "$FORMAT_EVIDENCE/check-paths.z"
test "${#check_paths[@]}" = 53
for path in "${check_paths[@]}"; do test -s "$path"; done
run_record format pnpm format "${files[@]}"
snapshot after-format
python3 - <<'PY'
import json, os
from pathlib import Path
root = Path(os.environ['FORMAT_EVIDENCE'])
before = json.loads((root / 'before-format/source.json').read_text())
after = json.loads((root / 'after-format/source.json').read_text())
for key in ['head', 'indexTree', 'indexEntriesSha256', 'unmerged', 'untracked']:
    assert before[key] == after[key], f'Formatter changed {key}'
old = {row['path']: row for row in before['tracked']}
new = {row['path']: row for row in after['tracked']}
assert old.keys() == new.keys()
changed = sorted(path for path in old if old[path] != new[path])
allowed = set((root / 'allowed-paths.txt').read_text().splitlines())
(root / 'actual-changed-paths.json').write_text(json.dumps(changed, indent=2) + '\n')
assert set(changed) <= allowed, 'Unexpected formatter source delta'
for path in allowed:
    assert old[path]['mode'] == new[path]['mode'] == '100644'
    assert old[path]['bytes'] > 0 and new[path]['bytes'] > 0
PY
run_record format-check pnpm format:check "${check_paths[@]}"
snapshot after-check
cmp "$FORMAT_EVIDENCE/after-format/source.json" "$FORMAT_EVIDENCE/after-check/source.json"
# Stage only the eight reviewed paths in this disposable CI checkout. No commit.
# A no-op is valid: retain the equal tree, empty patch and exact file hashes.
git add -- "${files[@]}"
final_tree="$(git write-tree)"
printf '%s\n' "$final_tree" > "$FORMAT_EVIDENCE/formatted-index-tree.txt"
git diff --quiet
test "$(git rev-parse HEAD)" = "$BASE_SHA"
test -z "$(git ls-files --unmerged)"
git diff --binary --full-index "$EXPECTED_TREE" "$final_tree" > "$FORMAT_EVIDENCE/formatting.patch"
git diff --name-only --no-renames -z "$EXPECTED_TREE" "$final_tree" > "$FORMAT_EVIDENCE/proposal-paths.z"
python3 - <<'PY'
import json, os
from pathlib import Path
root = Path(os.environ['FORMAT_EVIDENCE'])
paths = (root / 'proposal-paths.z').read_bytes().decode().split(chr(0))[:-1]
assert paths == json.loads((root / 'actual-changed-paths.json').read_text())
final_tree = (root / 'formatted-index-tree.txt').read_text().strip()
assert (final_tree == os.environ['EXPECTED_TREE']) == (not paths)
assert bool((root / 'formatting.patch').read_bytes()) == bool(paths)
PY
git diff --check "$EXPECTED_TREE" "$final_tree"
sha256sum "${files[@]}" > "$FORMAT_EVIDENCE/after-eight.sha256"
# EXIT collects complete after-files and a proposal-only receipt; it must succeed too.
