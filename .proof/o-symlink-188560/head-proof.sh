set -euo pipefail
umask 077
expected_sha="$1"
source_root="$PWD"
test "$(git rev-parse HEAD)" = "$expected_sha"
proof_root="$2"
harness_dir="$(cd -- "$(dirname -- "$0")" && pwd -P)"
chmod 700 "$proof_root"
export TMPDIR="$proof_root/tmp"
mkdir -p -m700 "$TMPDIR"
printf 'O_FINAL_HEAD %s proof_root=%s\n' "$expected_sha" "$proof_root"
python3 - <<'TEST_COST'
import subprocess,time,json
started=time.monotonic();r=subprocess.run(['pnpm','test','src/config/io.symlinked-root.test.ts','--maxWorkers=1']);print('O_TEST_FILE_COST',json.dumps({'file':'src/config/io.symlinked-root.test.ts','wallSeconds':round(time.monotonic()-started,3),'exit':r.returncode}),flush=True);raise SystemExit(r.returncode)
TEST_COST
pnpm test src/config/io.observe-recovery.test.ts src/config/io.snapshot.promotion.test.ts src/config/io.write-config.test.ts src/config/mutate.test.ts src/config/io.prefix-recovery.test.ts src/commands/doctor-config-preflight.recovery.test.ts src/commands/doctor-config-health-freshness.test.ts --maxWorkers=1
git fetch --no-tags --depth=1 origin 385f0d8eaaf1d64ad67bbc46e25661049c298908
git worktree add --detach "$proof_root/main" 385f0d8eaaf1d64ad67bbc46e25661049c298908
cd "$proof_root/main"
pnpm install --frozen-lockfile
git -C "$source_root" show "$expected_sha:src/config/io.symlinked-root.test.ts" > src/config/io.symlinked-root.test.ts
set +e
pnpm test src/config/io.symlinked-root.test.ts --maxWorkers=1 -t "recovers a broken config through" > "$proof_root/base-recovery-red.log" 2>&1
base_exit=$?
set -e
python3 - "$proof_root/base-recovery-red.log" "$base_exit" <<'BASE_RED'
import pathlib,sys
s=pathlib.Path(sys.argv[1]).read_text();print('O_MAIN_CORE_REGRESSION_RED_EXIT',sys.argv[2],flush=True);print(s[-12000:],flush=True);assert sys.argv[2]=='1';assert 'Atomic replace parent must be a real directory' in s and 'prefix' in s and 'last-known-good' in s and '2 failed' in s
BASE_RED
git restore --source=HEAD --worktree -- src/config/io.symlinked-root.test.ts
cd "$source_root"
mkdir -m700 "$proof_root/package"
node scripts/package-openclaw-for-docker.mjs --source-dir "$source_root" --allow-unreleased-changelog --runtime-only --output-dir "$proof_root/package" --output-name openclaw-current.tgz
test "$(git rev-parse HEAD)" = "$expected_sha"
git diff --exit-code
cp -- "$harness_dir/installed-upgrade-proof.py" "$proof_root/installed-proof.py"
mkdir -m700 "$proof_root/installed"
python3 "$proof_root/installed-proof.py" "$proof_root/installed" "$proof_root/package/openclaw-current.tgz" "$expected_sha"
printf "O_PUBLICATION_PROOF_COMPLETE %s\n" "$expected_sha"
