import pathlib,os,subprocess,json,hashlib,tarfile,sys
root=pathlib.Path(sys.argv[1]);tarball=pathlib.Path(sys.argv[2]);expected=sys.argv[3]
prefix=root/'install';home=root/'home';state=home/'real-state';link=home/'state-link';state.mkdir(parents=True,mode=0o700);home.chmod(0o700);state.chmod(0o700);link.symlink_to('real-state',target_is_directory=True)
config=state/'openclaw.json';raw='Warning: shell profile noise\n{"gateway":{"mode":"local","port":18999}}\n';config.write_text(raw);config.chmod(0o600)
env=dict(os.environ,HOME=str(home),OPENCLAW_STATE_DIR=str(link),NPM_CONFIG_USERCONFIG='/dev/null')
def run(label,args,timeout=1800):
    with (root/(label+'.log')).open('w') as log:r=subprocess.run(args,env=env,cwd=root,stdout=log,stderr=subprocess.STDOUT,timeout=timeout)
    print('O_INSTALLED_COMMAND',json.dumps({'label':label,'exit':r.returncode}),flush=True)
    return r.returncode,(root/(label+'.log')).read_text()
def identity():
    package=prefix/'lib/node_modules/openclaw';manifest=json.loads((package/'package.json').read_text());info=package/'dist/build-info.json'
    return {'version':manifest['version'],'build':json.loads(info.read_text()) if info.exists() else None,'entrySha256':hashlib.sha256((package/'openclaw.mjs').read_bytes()).hexdigest()}
rc,text=run('install-stable',['npm','install','--global','--prefix',str(prefix),'openclaw@2026.10.9']);assert rc==0,text[-5000:]
cli=prefix/'bin/openclaw';assert cli.resolve().is_relative_to(prefix.resolve())
old=identity();assert old['version']=='2026.10.9';rc,version=run('stable-version',[str(cli),'--version']);assert rc==0 and '2026.10.9' in version
print('O_OLD_INSTALLED',json.dumps(old),flush=True)
rc,text=run('stable-doctor',[str(cli),'doctor','--fix','--non-interactive'],900)
assert rc!=0 and 'Atomic replace parent must be a real directory' in text,text[-6000:]
assert config.read_text()==raw;assert os.readlink(link)=='real-state'
backups={x.name:hashlib.sha256(x.read_bytes()).hexdigest() for x in state.glob('openclaw.json.clobbered.*')};assert backups
print('O_STABLE_RED',json.dumps({'exit':rc,'originalUnchanged':True,'configBackupCount':len(backups),'exactError':'Atomic replace parent must be a real directory'}),flush=True)
rc,text=run('install-candidate',['npm','install','--global','--prefix',str(prefix),str(tarball)]);assert rc==0,text[-6000:]
new=identity();assert new['build']['commit']==expected,new
assert new['build']['buildId'] and new['build']!=old['build'];assert cli.resolve().is_relative_to(prefix.resolve())
package=prefix/'lib/node_modules/openclaw';verified=0
with tarfile.open(tarball) as archive:
    for member in archive:
        if not member.isfile():continue
        if member.name.startswith('package/dist/') or member.name in ['package/openclaw.mjs','package/package.json']:
            rel=pathlib.PurePosixPath(member.name).relative_to('package');assert '..' not in rel.parts
            installed=package.joinpath(*rel.parts);expected_bytes=archive.extractfile(member).read();assert installed.read_bytes()==expected_bytes,str(rel);verified+=1
assert verified>50,verified
print('O_NEW_INSTALLED',json.dumps({'identity':new,'tarballSha256':hashlib.sha256(tarball.read_bytes()).hexdigest(),'verifiedInstalledArtifactFiles':verified}),flush=True)
assert config.read_text()==raw,'installation must preserve the same broken config before Doctor'
rc,text=run('candidate-version',[str(cli),'--version']);assert rc==0
rc,text=run('candidate-doctor',[str(cli),'doctor','--fix','--non-interactive'],900)
assert rc==0,text[-10000:]
repaired=json.loads(config.read_text());assert repaired['gateway']['mode']=='local' and repaired['gateway']['port']==18999
assert os.readlink(link)=='real-state';assert state.stat().st_mode&0o7777==0o700
for name,digest in backups.items():assert hashlib.sha256((state/name).read_bytes()).hexdigest()==digest
archives=list(state.glob('openclaw.json.clobbered.*'));assert any(x.read_text()==raw for x in archives);assert len(archives)>len(backups)
print('O_INSTALLED_UPGRADE_GREEN',json.dumps({'expectedCommit':expected,'doctorExit':rc,'sameState':True,'oldBackupsPreserved':True,'exactOriginalSaved':True,'linkPreserved':True,'stateMode':'700','gateway':repaired['gateway'],'newBuildId':new['build']['buildId'],'allInstalledRuntimeFilesMatchArchive':True}),flush=True)
