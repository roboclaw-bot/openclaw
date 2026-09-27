#!/usr/bin/env bash
# REVIEWED CI RECIPE: preparation only; never commit, rebase, adopt, or validate runtime.
set -Eeuo pipefail
export GIT_OPTIONAL_LOCKS=0
export FORMAT_EVIDENCE="$RUNNER_TEMP/pr159178-format-preparation"
mkdir -p "$FORMAT_EVIDENCE"
mode="${1:-prepare}"
case "$mode:$#" in before-setup:1|prepare:0|prepare:1) ;; *) exit 2 ;; esac
files=(
  extensions/crabbox/src/crabbox-worker-warm-image-authority.test.ts
  extensions/crabbox/src/crabbox-worker-warm-image-capture.ts
  extensions/crabbox/src/crabbox-worker-warm-image-sibling-admission.test-support.ts
  extensions/crabbox/src/crabbox-worker-warm-image-sibling-admission.test.ts
  extensions/crabbox/src/crabbox-worker-warm-image.ts
)
printf '%s\n' "${files[@]}" > "$FORMAT_EVIDENCE/allowed-paths.txt"
cat > "$FORMAT_EVIDENCE/before-five.sha256" <<'HASHES'
c85ebafc5ebb241b70072ccafab5c894933282a6a785bb70bcc7778f9930e385  extensions/crabbox/src/crabbox-worker-warm-image-authority.test.ts
af6c7783dadcf9c8f402fef1138c808700c63ba1ca30318aa0ddbaa0343aa523  extensions/crabbox/src/crabbox-worker-warm-image-capture.ts
4e0d94d4a9df8bf50e1d8b86885bc48731beddbfbf76c9a979a14135e9295f57  extensions/crabbox/src/crabbox-worker-warm-image-sibling-admission.test-support.ts
6b36b46b2fe82189336912ba7a859d05ac73704f145638de8caa6655e22ea2ce  extensions/crabbox/src/crabbox-worker-warm-image-sibling-admission.test.ts
ac7784a6221044752095607adbe062a6bd42dc8e33b74c364a9976fcba849a2a  extensions/crabbox/src/crabbox-worker-warm-image.ts
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
  sha256sum --check "$FORMAT_EVIDENCE/before-five.sha256"
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
    (cd "$FORMAT_EVIDENCE/after-files" && sha256sum --check ../after-five.sha256) || rc=1
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
    'format': load('format.exit.json'), 'formatCheck': load('format-check.exit.json'),
    'inputPatchSha256': os.environ['PATCH_SHA256'],
    'formattingPatchSha256': digest('formatting.patch'),
    'beforeFiveManifestSha256': digest('before-five.sha256'),
    'afterFiveManifestSha256': digest('after-five.sha256'),
    'sourceBeforeSetupSha256': digest('before-setup/source.json'),
    'sourceBeforeFormatSha256': digest('before-format/source.json'),
    'sourceAfterFormatSha256': digest('after-format/source.json'),
    'sourceFinalSha256': digest('final/source.json'),
    'next': 'Parent review/adoption only; then resume actual 7365e3003e1c6ab9e372fc5b1fe673f82c18389e history and ordinary sixth commit/validation separately.',
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
test "$BASE_SHA" = 0edae198d278686e16426f7ad254d0341bd6e3d3
test "$EXPECTED_TREE" = 2596c1fa0781b0d2d28b23186da2a429151d1fc7
test "$PATCH_SHA256" = 6879b9a11abfc16f09db4c334a8fc061ecf782d6e426daa40904ccdd91c21659
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
git diff --name-only --no-renames -z "$BASE_SHA" "$EXPECTED_TREE" > "$FORMAT_EVIDENCE/check-paths.z"
test "$(sha256sum "$FORMAT_EVIDENCE/check-paths.z" | cut -d ' ' -f1)" = b68cc4d5a9384d4c20c5b309925cca55fd28be14941582521fd09f520b90f67d
mapfile -d '' -t check_paths < "$FORMAT_EVIDENCE/check-paths.z"
test "${#check_paths[@]}" = 50
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
assert changed and set(changed) <= allowed, 'Empty or unexpected formatter source delta'
for path in allowed:
    assert old[path]['mode'] == new[path]['mode'] == '100644'
    assert old[path]['bytes'] > 0 and new[path]['bytes'] > 0
PY
run_record format-check pnpm format:check "${check_paths[@]}"
snapshot after-check
cmp "$FORMAT_EVIDENCE/after-format/source.json" "$FORMAT_EVIDENCE/after-check/source.json"
# Stage only the five reviewed paths in this disposable CI checkout. No commit.
git add -- "${files[@]}"
final_tree="$(git write-tree)"
test "$final_tree" != "$EXPECTED_TREE"
printf '%s\n' "$final_tree" > "$FORMAT_EVIDENCE/formatted-index-tree.txt"
git diff --quiet
test "$(git rev-parse HEAD)" = "$BASE_SHA"
test -z "$(git ls-files --unmerged)"
git diff --binary --full-index "$EXPECTED_TREE" "$final_tree" > "$FORMAT_EVIDENCE/formatting.patch"
test -s "$FORMAT_EVIDENCE/formatting.patch"
git diff --name-only --no-renames -z "$EXPECTED_TREE" "$final_tree" > "$FORMAT_EVIDENCE/proposal-paths.z"
python3 - <<'PY'
import json, os
from pathlib import Path
root = Path(os.environ['FORMAT_EVIDENCE'])
paths = (root / 'proposal-paths.z').read_bytes().decode().split(chr(0))[:-1]
assert paths == json.loads((root / 'actual-changed-paths.json').read_text())
PY
git diff --check "$EXPECTED_TREE" "$final_tree"
sha256sum "${files[@]}" > "$FORMAT_EVIDENCE/after-five.sha256"
# EXIT collects complete after-files and a proposal-only receipt; it must succeed too.
