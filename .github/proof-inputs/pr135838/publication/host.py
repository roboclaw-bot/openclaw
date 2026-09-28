#!/usr/bin/env python3
"""Controller-owned glue for the existing provider-resume-process suite only."""
from pathlib import Path
import json, os, shutil, stat, subprocess, sys, tarfile, time
from artifact import checked_zip, build_archive, encode, safe_name, sha, restore_links

TEMP = Path(os.environ['RUNNER_TEMP']).resolve()
HERE = Path(__file__).resolve().parent
PREFIX = '.github/proof-inputs/pr135838/'
assert os.environ['SUITE'] == 'provider-resume-process'
assert os.environ['GITHUB_ACTIONS'] == 'true' and os.environ['RUNNER_ENVIRONMENT'] == 'github-hosted'
assert os.environ['RUNNER_OS'] == 'Linux' and os.environ['RUNNER_ARCH'] == 'X64'
assert not any(os.environ.get(k) for k in ('GH_TOKEN', 'GITHUB_TOKEN', 'NPM_TOKEN', 'NODE_AUTH_TOKEN', 'NODE_OPTIONS'))

def git(*args):
    return subprocess.check_output(['git', *args], text=True).strip()

def put_env(values):
    with open(os.environ['GITHUB_ENV'], 'a') as out:
        for name, value in values.items():
            assert chr(10) not in str(value); out.write(name+'='+str(value)+chr(10))

def native_budget(elapsed):
    if type(elapsed) is not int or not 0 <= elapsed <= 2400:
        raise ValueError('Invalid elapsed job clock')
    budget = min(1680, 2400 - elapsed - 350 - 110 - 10)
    if budget < 1510:
        raise ValueError('Preallocation refusal: insufficient full-scenario and cleanup allowance')
    return budget

def elapsed_seconds(job_started, now, job_monotonic, now_monotonic):
    # Trusted same-VM timing inputs, not authorization or a job-start API.
    values = (job_started, now, job_monotonic, now_monotonic)
    if any(type(v) is not int or v <= 0 for v in values):
        raise ValueError('Invalid job clock')
    if now < job_started or now_monotonic < job_monotonic:
        raise ValueError('Negative job clock interval')
    elapsed = max(now - job_started, (now_monotonic - job_monotonic + 999999999) // 1000000000)
    return elapsed

def budget():
    receipt = {'status': 'PREALLOCATION_REFUSAL', 'proofMissing': True,
               'jobStartedEpochSeconds': None, 'jobStartedMonotonicNs': None,
               'allocatedAtEpochSeconds': int(time.time()), 'allocatedAtMonotonicNs': time.monotonic_ns(),
               'elapsedSeconds': None, 'nativeBudgetSeconds': None,
               'jobSeconds': 2400, 'cleanupReserveSeconds': 350, 'overheadReserveSeconds': 110,
               'unmeasuredSetupMarginSeconds': 30, 'wrapperAndStepMarginSeconds': 20,
               'uploadReserveSeconds': 60, 'outerKillMarginSeconds': 10}
    try:
        clocks = []
        for name in ('PUBLICATION_JOB_STARTED', 'PUBLICATION_JOB_STARTED_MONOTONIC_NS'):
            raw = os.environ.get(name, '')
            if not raw or len(raw) > 20 or not raw.isascii() or not raw.isdecimal():
                raise ValueError('Invalid job clock encoding')
            clocks.append(int(raw))
        receipt.update(jobStartedEpochSeconds=clocks[0], jobStartedMonotonicNs=clocks[1])
        receipt['elapsedSeconds'] = elapsed_seconds(clocks[0], receipt['allocatedAtEpochSeconds'], clocks[1], receipt['allocatedAtMonotonicNs'])
        receipt['nativeBudgetSeconds'] = native_budget(receipt['elapsedSeconds'])
        receipt['status'] = 'ALLOCATED_NOT_PROOF'
    except ValueError as exc:
        receipt['reason'] = str(exc)
        raise
    finally:
        (TEMP/'publication-budget.json').write_bytes(encode(receipt))
    print(receipt['nativeBudgetSeconds'])

def preserve():
    b = json.loads((HERE/'binding.json').read_bytes())
    assert b['reviewed'] is True and b['executionAuthorized'] is True
    assert git('rev-parse', 'HEAD') == os.environ['GITHUB_SHA'] == os.environ['REBASE_WORKFLOW_SHA']
    assert git('rev-parse', 'HEAD^') == b['controllerParent']
    assert b['controllerSha'] is None, 'Self SHA is recorded only from actual native workflow context'
    subprocess.run(['git', 'diff', '--quiet', 'HEAD'], check=True)
    for name, digest in b['integrationFiles'].items():
        assert '/' not in name and sha((HERE/name).read_bytes()) == digest
    root = TEMP/'publication-controller.git'
    # Independent object custody survives checkout's repository replacement.
    subprocess.run(['git', 'clone', '--bare', '--local', '--no-hardlinks', '.', str(root)], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    assert subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip() == os.environ['GITHUB_SHA']
    destination = TEMP/'publication-inputs'
    shutil.copytree(HERE, destination)
    b['controllerSha'] = os.environ['GITHUB_SHA']
    (destination/'binding.json').write_bytes(encode(b))
    put_env({'PUBLICATION_BINDING': destination/'binding.json',
             'PUBLICATION_BUILD_RECEIPT': TEMP/'publication-build-receipt.json',
             'PUBLICATION_CONTROLLER_ROOT': root,
             'CRABBOX_PROOF_BINARY': TEMP/'publication-crabbox/crabbox'})
    with open(os.environ['GITHUB_OUTPUT'], 'a') as out:
        out.write('build_run='+str(b['buildArtifact']['workflow_run']['id'])+chr(10))
        out.write('build_artifact='+str(b['buildArtifact']['id'])+chr(10))

def prepare():
    b = json.loads(Path(os.environ['PUBLICATION_BINDING']).read_bytes())
    assert git('rev-parse', 'HEAD') == b['candidateSha']
    assert git('rev-parse', 'HEAD^{tree}') == git('write-tree') == b['candidateTree']
    subprocess.run(['git', 'diff', '--quiet', 'HEAD'], check=True)
    archives = [p for p in (TEMP/'publication-download').iterdir() if p.is_file()]
    assert len(archives) == 1 and archives[0].is_file() and not archives[0].is_symlink()
    outer, _ = checked_zip(archives[0].read_bytes(), b['buildArtifact'])
    assert set(outer) == {'candidate.bundle', 'candidate.json', 'candidate-built-dist.zip'}
    c = json.loads(outer['candidate.json'])
    assert c['commit'] == b['candidateSha'] and c['tree'] == b['candidateTree']
    assert c['suite'] == 'provider-resume-build' and c['gateStatus'] == 'passed'
    assert c['runId'] == str(b['buildArtifact']['workflow_run']['id'])
    assert c['attempt'] == str(b['buildAttempt']) and c['controller'] == b['buildArtifact']['workflow_run']['head_sha']
    assert sha(outer['candidate.bundle']) == b['sourceBundleSha256'] == c['bundleSha256']
    assert outer['candidate.bundle'] == (TEMP/'pr159178-same-commit/retained/candidate.bundle').read_bytes()
    files, manifest, receipt, rows = build_archive(outer['candidate-built-dist.zip'], b['candidateSha'], b['candidateTree'], b['sourceBundleSha256'])
    assert sha(outer['candidate-built-dist.zip']) == b['builtDistSha256']
    assert manifest['recipeSha256'] == b['buildRecipeSha256']
    assert files['native/dependency-links-owner.mjs'] == Path('scripts/lib/bundled-plugin-dependency-links.mjs').read_bytes()
    assert (manifest['controller'], manifest['runId'], manifest['attempt']) == (c['controller'], c['runId'], c['attempt'])
    assert sha(encode(receipt)) == b['buildReceiptSha256']
    Path(os.environ['PUBLICATION_BUILD_RECEIPT']).write_bytes(encode(receipt))
    # Fresh isolated checkout only: setup output is not candidate source, and no
    # tracked dist path may be replaced. Use the reviewed built bytes, not a rebuild.
    for root in manifest['outputRoots']:
        assert not git('ls-files', root) and not Path(root).is_symlink()
        if Path(root).exists(): shutil.rmtree(root)
    for row in rows:
        if not any(row['path'].startswith(root+'/') for root in manifest['outputRoots']): continue
        target = Path(row['path']); target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(files[row['path']]); target.chmod(row['mode'])
        assert sha(target.read_bytes()) == row['sha256']
    restore_links(manifest['outputLinks'])
    assert sha(Path('dist/build-info.json').read_bytes()) == b['buildInfoSha256']
    # Public fixed release download; no repository credential or candidate API.
    archive = TEMP/'publication-crabbox.tar.gz'
    subprocess.run(['curl', '--fail', '--silent', '--show-error', '--location', '--proto', '=https', '--proto-redir', '=https',
                    '--max-time', '180', '--output', str(archive),
                    'https://github.com/openclaw/crabbox/releases/download/v0.66.0/crabbox_0.66.0_linux_amd64.tar.gz'],
                   env={'PATH': os.environ['PATH'], 'HOME': str(TEMP)}, check=True)
    assert archive.stat().st_size <= 128 * 1024**2 and sha(archive.read_bytes()) == b['crabboxArchiveSha256']
    with tarfile.open(archive, 'r:gz') as tar:
        members = tar.getmembers(); seen = set()
        assert len(members) <= 128 and sum(x.size for x in members) <= 512 * 1024**2
        for member in members:
            name = safe_name(member.name); assert name not in seen; seen.add(name)
            assert member.isfile() or member.isdir()
            assert not member.mode & 0o7000
        binaries = [m for m in members if m.name == 'crabbox' and m.isfile()]
        assert len(binaries) == 1
        data = tar.extractfile(binaries[0]).read()
    assert sha(data) == b['crabboxExecutableSha256']
    target = Path(os.environ['CRABBOX_PROOF_BINARY']); target.parent.mkdir(exist_ok=False); target.write_bytes(data); target.chmod(0o755)
    # Build adoption is complete BEFORE these only two additive proof files.
    patch = HERE/'proof-only-overlay.patch'
    assert sha(patch.read_bytes()) == b['integrationFiles']['proof-only-overlay.patch']
    for name in b['overlayFiles']: assert not Path(name).exists()
    subprocess.run(['git', 'apply', '--index', '--check', str(patch)], check=True)
    subprocess.run(['git', 'apply', '--index', str(patch)], check=True)
    assert git('write-tree') == b['overlayTree']
    assert set(git('diff', '--cached', '--name-only', 'HEAD').splitlines()) == set(b['overlayFiles'])
    assert all(line.startswith('A'+chr(9)) for line in git('diff', '--cached', '--name-status', 'HEAD').splitlines())
    subprocess.run(['git', 'diff', '--quiet'], check=True)
    assert git('rev-parse', 'HEAD') == b['candidateSha']

def verify_source():
    b = json.loads(Path(os.environ['PUBLICATION_BINDING']).read_bytes())
    assert git('rev-parse', 'HEAD') == b['candidateSha']
    assert git('rev-parse', 'HEAD^{tree}') == b['candidateTree']
    assert git('write-tree') == b['overlayTree']
    subprocess.run(['git', 'diff', '--quiet'], check=True)
    assert set(git('diff', '--cached', '--name-only', 'HEAD').splitlines()) == set(b['overlayFiles'])
    for name, digest in b['overlayFiles'].items():
        assert Path(name).is_file() and not Path(name).is_symlink() and sha(Path(name).read_bytes()) == digest

def collect():
    # Never upload a directory recursively. Missing cleanup is missing proof.
    destination = TEMP/'publication-sanitized'; destination.mkdir(exist_ok=True)
    allowed = {'binding.json', 'registered-provider-graph.json', 'commands.jsonl', 'live-publication.json',
               'metadata-staging.json', 'metadata-restoration.json', 'controller-run.json', 'controller-failure.json',
               'always-inventory.json', 'always-cleanup.json'}
    roots = [p for p in TEMP.glob('publication-v4-evidence.*') if p.is_dir() and not p.is_symlink()]
    assert len(roots) <= 1
    if roots:
        for name in sorted(allowed):
            source = roots[0]/name
            if source.exists():
                assert source.is_file() and not source.is_symlink()
                # Parse without printing; only the reviewed sanitizer's outputs.
                if name.endswith('.json'): json.loads(source.read_bytes())
                else:
                    for line in source.read_text().splitlines(): json.loads(line)
                shutil.copyfile(source, destination/name)
    run_path = destination/'controller-run.json'
    run_receipt = json.loads(run_path.read_bytes()) if run_path.exists() else {
        'nativeStarted': None, 'nativeExitStatus': None, 'exitCode': None, 'timedOut': None, 'proofMissing': True}
    for name, filename in (('budget', 'publication-budget.json'), ('outer', 'publication-outer.json')):
        source = TEMP/filename
        if source.exists():
            assert source.is_file() and not source.is_symlink()
            run_receipt[name] = json.loads(source.read_bytes())
    outer = run_receipt.get('outer', {})
    run_receipt['proofMissing'] = (run_receipt.get('proofMissing') is not False
        or outer.get('exitStatus') != 0 or run_receipt.get('timedOut') is not False
        or run_receipt.get('nativeExitStatus') != 0)
    run_path.write_bytes(encode(run_receipt))
    failure = TEMP/'publication-integration-failure.json'
    if failure.exists(): shutil.copyfile(failure, destination/'controller-failure.json')
    if not (destination/'always-cleanup.json').exists():
        if not (destination/'controller-failure.json').exists():
            (destination/'controller-failure.json').write_bytes(encode({'proofMissing': True, 'error': 'MissingCleanupReceipt',
                'message': 'Preparation, native execution, or same-VM cleanup did not produce its required receipt. VM disposal is containment only.'}))
        raise RuntimeError('No always-cleanup receipt; proof incomplete')

if __name__ == '__main__':
    assert len(sys.argv) == 2 and sys.argv[1] in ('preserve', 'prepare', 'verify-source', 'collect', 'budget')
    try:
        {'preserve': preserve, 'prepare': prepare, 'verify-source': verify_source, 'collect': collect, 'budget': budget}[sys.argv[1]]()
    except Exception:
        (TEMP/'publication-integration-failure.json').write_bytes(encode({'proofMissing': True,
            'error': 'IntegrationPreconditionFailure', 'phase': sys.argv[1],
            'message': 'Controller admission, build adoption, source preservation or evidence collection failed; inspect the failed fixed step.'}))
        raise
