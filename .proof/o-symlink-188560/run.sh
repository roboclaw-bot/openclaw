#!/usr/bin/env bash
set -euo pipefail
candidate_root="$1"
expected_sha="$2"
proof_root="$3"
harness_dir="$(cd -- "$(dirname -- "$0")" && pwd -P)"
test "$expected_sha" = d620e452247d70976c97b0c66532c33820be54b8
cd "$candidate_root"
test "$(git rev-parse HEAD)" = "$expected_sha"
if git config --get-regexp 'http\..*\.extraheader|credential\.helper' >"$proof_root/credential-check.private"; then
  echo 'Refusing credential-bearing candidate Git configuration' >&2
  exit 1
fi
python3 - "$expected_sha" <<'PROVENANCE'
import os,sys,json,pathlib
forbidden=['GH_TOKEN','GITHUB_TOKEN','NODE_AUTH_TOKEN','ACTIONS_RUNTIME_TOKEN','ACTIONS_ID_TOKEN_REQUEST_TOKEN','AWS_ACCESS_KEY_ID','AWS_SECRET_ACCESS_KEY','AWS_SESSION_TOKEN','AWS_PROFILE','OPENAI_API_KEY','ANTHROPIC_API_KEY','TAILSCALE_AUTH_KEY']
assert not any(os.environ.get(k) for k in forbidden),'Execution environment must be secretless'
assert pathlib.Path(os.environ['HOME']).stat().st_mode&0o777==0o700
assert pathlib.Path(os.environ['TMPDIR']).stat().st_mode&0o777==0o700
print('O_SECRETLESS_FORK_CI',json.dumps({'candidateSha':sys.argv[1],'credentialEnvironmentAbsent':True,'gitCredentialsAbsent':True,'homeMode':'700','tempMode':'700','cpus':os.cpu_count(),'memTotalLine':next(x for x in pathlib.Path('/proc/meminfo').read_text().splitlines() if x.startswith('MemTotal:'))}),flush=True)
PROVENANCE
pnpm_pin='pnpm@12.15.0+sha512.b3951d6d6ff4a9f13dc7cf56cd28d2b8eb37dbcc9c68e52e1e1191873ea9f82a017287ab50baadc5ccc494f036c67c0e47eb13608c2fa36f47711b61ea128e61'
node - "$pnpm_pin" <<'PIN'
const fs=require('node:fs');if(JSON.parse(fs.readFileSync('package.json','utf8')).packageManager!==process.argv[2])throw new Error('Unexpected package-manager pin');
PIN
mkdir -m700 "$proof_root/tool-bin"
cd "$proof_root"
corepack enable --install-directory "$proof_root/tool-bin"
corepack prepare "$pnpm_pin" --activate
export PATH="$proof_root/tool-bin:$PATH"
cd "$candidate_root"
node --version
pnpm --version
pnpm install --frozen-lockfile
set +e
/usr/bin/time -v /bin/bash "$harness_dir/head-proof.sh" "$expected_sha" "$proof_root" 2>&1 | tee "$proof_root/evidence/run.log"
pipe_status=("${PIPESTATUS[@]}")
proof_exit="${pipe_status[0]}"
if [ "$proof_exit" -eq 0 ] && [ "${pipe_status[1]}" -ne 0 ]; then proof_exit="${pipe_status[1]}"; fi
set -e
python3 - "$proof_root" "$proof_exit" <<'EVIDENCE'
import pathlib,shutil,sys,json
root=pathlib.Path(sys.argv[1]);out=root/'evidence'
for file in [root/'base-recovery-red.log',*(root/'installed').glob('*.log')]:
 if file.is_file():shutil.copyfile(file,out/file.name)
(out/'outcome.json').write_text(json.dumps({'exit':int(sys.argv[2]),'candidateSha':'d620e452247d70976c97b0c66532c33820be54b8'})+'\n')
EVIDENCE
exit "$proof_exit"
