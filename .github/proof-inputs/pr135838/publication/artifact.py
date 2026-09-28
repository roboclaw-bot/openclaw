#!/usr/bin/env python3
"""Fixed publication artifact data contract. Never imports candidate modules."""
from pathlib import Path, PurePosixPath
import hashlib, io, json, os, posixpath, re, stat, subprocess, sys, zipfile

def sha(data):
    return hashlib.sha256(data).hexdigest()

def encode(value):
    return (json.dumps(value, indent=2) + chr(10)).encode()

def safe_name(name):
    assert name and not name.startswith('/') and chr(92) not in name and ':' not in name
    assert chr(0) not in name and all(p not in ('', '.', '..') for p in name.rstrip('/').split('/'))
    return name.rstrip('/')

def checked_zip(data, expected=None):
    if expected:
        assert len(data) == expected['size_in_bytes']
        assert 'sha256:' + sha(data) == expected['digest']
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        entries = archive.infolist(); seen = set(); files = {}; modes = {}; directories = set()
        assert entries and len(entries) <= 150000
        assert sum(x.file_size for x in entries) <= 4 * 1024**3
        for item in entries:
            name = safe_name(item.filename)
            assert name not in seen and not item.flag_bits & 1
            seen.add(name)
            mode = item.external_attr >> 16
            kind = stat.S_IFMT(mode)
            assert kind in (0, stat.S_IFREG, stat.S_IFDIR), (name, mode)
            assert not mode & 0o7000
            if item.is_dir():
                assert kind in (0, stat.S_IFDIR); directories.add(name)
            else:
                assert kind in (0, stat.S_IFREG)
                files[name] = item; modes[name] = mode & 0o777
        assert not set(files) & directories
        for name in seen:
            assert not any(str(p) in files for p in PurePosixPath(name).parents)
        assert archive.testzip() is None, 'ZIP CRC failure before extraction'
        result = {name: archive.read(item) for name, item in files.items()}
        rows = [{'path': name, 'bytes': len(result[name]), 'sha256': sha(result[name]),
                 'mode': modes[name], 'crc32': files[name].CRC} for name in sorted(files)]
        return result, rows

def output_roots(owner):
    source = owner.decode()
    marker = 'const TSDOWN_PACKAGE_NAMES = ['
    assert source.count(marker) == 1
    table = source.split(marker, 1)[1].split('] as const;', 1)[0]
    names = [json.loads(line.strip().removesuffix(',')) for line in table.splitlines() if line.strip()]
    assert len(names) == len(set(names)) == 16, 'Reviewed candidate must retain all sixteen package dist roots'
    assert all(isinstance(name, str) and name and all(c in 'abcdefghijklmnopqrstuvwxyz0123456789-' for c in name) for name in names)
    return ['dist', *['packages/'+name+'/dist' for name in names]]

def dependency_link_source(name):
    # The actual source build owner links only plugin-installed package roots.
    match = re.fullmatch(r'dist/extensions/([A-Za-z0-9_-]+)/node_modules/([.]bin|[A-Za-z0-9_-][A-Za-z0-9_.-]*|@[A-Za-z0-9_-][A-Za-z0-9_.-]*/[A-Za-z0-9_-][A-Za-z0-9_.-]*)', name)
    assert match, 'Unowned output symlink: ' + name
    return 'extensions/'+match[1]+'/node_modules/'+match[2]

def validate_links(links, files):
    assert isinstance(links, list) and links == sorted(links, key=lambda row: row['path'])
    names = set()
    for row in links:
        assert set(row) == {'path','target','targetSha256','mode','source','canonicalTarget'}
        name = safe_name(row['path']); assert name not in names and name not in files
        names.add(name)
        assert row['source'] == dependency_link_source(name) and row['mode'] == 0o777
        target = row['target']; assert isinstance(target,str) and target and not target.startswith('/')
        assert chr(0) not in target and chr(92) not in target and ':' not in target
        assert sha(target.encode()) == row['targetSha256']
        canonical = row['canonicalTarget']
        if canonical != '.': safe_name(canonical)
        assert posixpath.normpath(posixpath.join(posixpath.dirname(name),target)) == canonical
        assert canonical == '.' or canonical.startswith(('node_modules/','extensions/','packages/'))
    for name in names:
        assert not any(path.startswith(name+'/') for path in set(files)|names)
        assert not any(str(parent) in files for parent in PurePosixPath(name).parents)
    return links

def restore_links(links):
    root = Path.cwd().resolve()
    for row in links:
        target = root/row['path']; source = root/row['source']
        canonical = source.resolve(strict=True)
        assert canonical.is_relative_to(root) and canonical.is_dir()
        assert canonical.relative_to(root).as_posix() == row['canonicalTarget']
        assert os.path.relpath(canonical,target.parent) == row['target']
        # Only recreate the native producer's exact link text, never copy dependencies.
        target.parent.mkdir(parents=True,exist_ok=True)
        assert target.parent.resolve().is_relative_to(root/'dist')
        assert not target.exists() and not target.is_symlink()
        target.symlink_to(row['target'],target_is_directory=True)
        assert os.readlink(target) == row['target'] and target.resolve(strict=True) == canonical

def build_archive(data, candidate, tree, bundle_sha):
    files, rows = checked_zip(data)
    m = json.loads(files['manifest.json'])
    assert m['schema'] == 'pr135838-native-dist-v1'
    assert m['candidateSha'] == candidate and m['candidateTree'] == tree
    assert m['sourceBundleSha256'] == bundle_sha
    validate_links(m['outputLinks'], files)
    expected = m['members']
    actual = [{k: row[k] for k in ('path', 'bytes', 'sha256', 'mode')}
              for row in rows if row['path'] != 'manifest.json']
    assert actual == expected
    native = json.loads(files['native/build.result.json'])
    assert set(native) == {'command', 'startedAt', 'endedAt', 'nativeExitStatus', 'teeExitStatus'}
    assert native['command'] == 'build' and native['nativeExitStatus'] == native['teeExitStatus'] == 0
    assert files['native/build.command.txt'] == b'pnpm build ' + bytes([10])
    assert native == m['nativeBuildResult']
    assert files['native/build-after-HEAD.txt'] == (candidate + chr(10)).encode()
    assert files['native/build-after-tracked-status.txt'] == b''
    assert files['native/build-after-source-checks.exit.txt'] == b'0' + bytes([10])
    info = json.loads(files['dist/build-info.json'])
    assert info['commit'] == candidate and isinstance(info['buildId'], str) and info['buildId']
    assert sha(files['dist/build-info.json']) == m['buildInfoSha256']
    assert info['buildId'] == m['buildId']
    assert sha(files['native/build-recipe.sh']) == m['recipeSha256']
    assert sha(files['native/source-payload.json']) == m['sourcePayloadSha256']
    payload = json.loads(files['native/source-payload.json'])
    assert (payload['commit'], payload['tree'], payload['bundleSha256']) == (candidate, tree, bundle_sha)
    roots = output_roots(files['native/output-roots-owner.mts'])
    assert m['outputRoots'] == roots
    assert all(any(name.startswith(root+'/') for root in roots) or name.startswith('native/') or name == 'manifest.json' for name in files)
    assert all(any(name.startswith(root+'/') for name in files) for root in roots)
    for required in ('dist/plugin-sdk/process-runtime.js', 'dist/extensions/crabbox/index.js'):
        assert required in files, required
    # Adapt the observed native receipt, never emit a literal/synthetic pass.
    receipt = {'candidateSha': candidate, 'recipe': files['native/build.command.txt'].decode().strip(),
               'exitCode': native['nativeExitStatus'], 'candidateTree': tree,
               'buildInfoSha256': m['buildInfoSha256'], 'buildId': info['buildId'],
               'nativeResultSha256': sha(files['native/build.result.json']),
               'recipeSha256': m['recipeSha256'], 'sourceBundleSha256': bundle_sha,
               'controller': m['controller'], 'runId': m['runId'], 'attempt': m['attempt']}
    return files, m, receipt, rows

def retain():
    assert os.environ['SUITE'] == 'provider-resume-build'
    assert os.environ['GITHUB_ACTIONS'] == 'true' and os.environ['SAME_COMMIT_HOSTED'] == 'github-hosted'
    assert not any(os.environ.get(k) for k in ('GH_TOKEN', 'GITHUB_TOKEN', 'NPM_TOKEN', 'NODE_AUTH_TOKEN', 'NODE_OPTIONS', 'GIT_COMMIT', 'GIT_SHA'))
    temp = Path(os.environ['RUNNER_TEMP']); evidence = temp/'pr159178-same-commit'
    payload = json.loads((temp/'same-commit-payload.json').read_bytes())
    def git(*args): return subprocess.check_output(['git', *args]).decode().strip()
    candidate, tree = git('rev-parse', 'HEAD'), git('rev-parse', 'HEAD^{tree}')
    assert candidate == payload['commit'] and tree == payload['tree'] == git('write-tree')
    subprocess.run(['git', 'diff', '--quiet', 'HEAD'], check=True)
    files = {}; links = []; workspace = Path.cwd().resolve()
    owner = Path('scripts/lib/tsdown-output-roots.mts').read_bytes()
    roots = output_roots(owner)
    for root in roots:
        assert Path(root).is_dir() and not Path(root).is_symlink()
        for p in sorted(Path(root).rglob('*')):
            if p.is_symlink():
                name = p.as_posix(); source = dependency_link_source(name)
                canonical = Path(source).resolve(strict=True)
                assert canonical.is_relative_to(workspace) and canonical.is_dir()
                assert p.resolve(strict=True) == canonical
                target = os.readlink(p)
                assert target == os.path.relpath(canonical,p.parent)
                links.append({'path':name,'target':target,'targetSha256':sha(target.encode()),
                              'mode':stat.S_IMODE(p.lstat().st_mode),'source':source,
                              'canonicalTarget':canonical.relative_to(workspace).as_posix()})
                continue
            if p.is_dir(): continue
            assert p.is_file() and not p.stat().st_mode & 0o7000
            files[p.as_posix()] = (p.read_bytes(), stat.S_IMODE(p.stat().st_mode))
    links.sort(key=lambda row:row['path']); validate_links(links,files)
    sources = {'dependency-links-owner.mjs': Path('scripts/lib/bundled-plugin-dependency-links.mjs'),
               'build.result.json': evidence/'build.result.json',
               'build.command.txt': evidence/'build.command.txt',
               'build-after-HEAD.txt': evidence/'build-after/HEAD.txt',
               'build-after-tracked-status.txt': evidence/'build-after/tracked-status.txt',
               'build-after-source-checks.exit.txt': evidence/'build-after/source-checks.exit.txt',
               'build-recipe.sh': temp/'validate-candidate.sh',
               'source-payload.json': temp/'same-commit-payload.json',
               'output-roots-owner.mts': Path('scripts/lib/tsdown-output-roots.mts')}
    for name, p in sources.items():
        assert p.is_file() and not p.is_symlink(); files['native/'+name] = (p.read_bytes(), 0o644)
    info = json.loads(files['dist/build-info.json'][0])
    m = {'schema': 'pr135838-native-dist-v1', 'candidateSha': candidate, 'candidateTree': tree,
         'outputRoots': roots, 'outputLinks':links, 'sourceBundleSha256': payload['bundleSha256'], 'sourcePayloadSha256': sha(files['native/source-payload.json'][0]),
         'controller': os.environ['GITHUB_SHA'], 'runId': os.environ['GITHUB_RUN_ID'], 'attempt': os.environ['GITHUB_RUN_ATTEMPT'],
         'recipeSha256': sha(files['native/build-recipe.sh'][0]), 'nativeBuildResult': json.loads(files['native/build.result.json'][0]),
         'buildInfoSha256': sha(files['dist/build-info.json'][0]), 'buildId': info['buildId'],
         'members': [{'path': name, 'bytes': len(b), 'sha256': sha(b), 'mode': mode} for name, (b, mode) in sorted(files.items())]}
    files['manifest.json'] = (encode(m), 0o644)
    output = temp/'candidate-built-dist.zip'
    assert not output.exists()
    with zipfile.ZipFile(output, 'x', compression=zipfile.ZIP_DEFLATED, compresslevel=1) as archive:
        for name, (data, mode) in sorted(files.items()):
            z = zipfile.ZipInfo(name); z.create_system = 3; z.external_attr = (stat.S_IFREG | mode) << 16
            z.compress_type = zipfile.ZIP_DEFLATED; archive.writestr(z, data)
    _, _, receipt, _ = build_archive(output.read_bytes(), candidate, tree, payload['bundleSha256'])
    (evidence/'build-retention.json').write_bytes(encode({'zipSha256': sha(output.read_bytes()), 'bytes': output.stat().st_size, 'nativeReceipt': receipt}))

if __name__ == '__main__':
    assert sys.argv[1:] == ['retain']
    retain()
