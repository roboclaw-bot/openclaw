#!/usr/bin/env python3
"""Fixed suite only. Trusted controller copy, never a candidate-provided command."""
import hashlib,json,os,pathlib,re,signal,subprocess,sys,tempfile,time
P=pathlib.Path
BASE=P(os.environ['RUNNER_TEMP']).resolve()
LOC=BASE/'publication-v4-locator.json'
assert os.environ.get('GITHUB_ACTIONS')=='true'
assert os.environ.get('RUNNER_ENVIRONMENT')=='github-hosted'
assert os.environ.get('RUNNER_OS')=='Linux'
def failure_hook(kind,exception,trace):
 message=str(exception)
 if 'private' in globals():message=message.replace(str(private),'<private>')
 message=re.sub(r'(?:https?|wss?)://\S+','<redacted-url>',message)
 record={'proofMissing':True,'error':kind.__name__,'message':message[:2000] or 'Controller precondition failed; inspect reviewed bindings'}
 if 'evidence' in globals():
  try:(evidence/'controller-failure.json').write_text(json.dumps(record,indent=2)+'\n')
  except OSError:pass
 print(json.dumps(record),file=sys.stderr)
sys.excepthook=failure_hook
mode=sys.argv[1]; assert mode in ('run','always')
sha=lambda b:hashlib.sha256(b).hexdigest()
def put(p,obj):
 t=p.with_suffix(p.suffix+'.new');t.write_text(json.dumps(obj,indent=2)+'\n');t.replace(p)
def ident(pid):
 try:
  a=P('/proc/'+str(pid)+'/stat').read_text().rsplit(')',1)[1].split()
  return {'pid':int(pid),'ppid':int(a[1]),'pgid':int(a[2]),'sid':int(a[3]),'start':a[19], 'boot':P('/proc/sys/kernel/random/boot_id').read_text().strip()}
 except (FileNotFoundError,ProcessLookupError):return None
def same(i):
 now=ident(i['pid'])
 return now is not None and all(now[k]==i[k] for k in ('pid','start','boot'))
def error(e):
 s=str(e).replace(str(private),'<private>')
 s=re.sub(r'(?:https?|wss?)://\S+','<redacted-url>',s)
 s=re.sub(r'-----BEGIN[\s\S]*?-----END[^-]+-----','<redacted-key>',s)
 s=re.sub(r'(token|secret|password|authorization|capability|setupCode)([=: ]+)\S+',r'\1\2<redacted>',s,flags=re.I)
 return s[:2000] or 'Controller assertion failed; proof incomplete'
def discover():
 for d in P('/proc').iterdir():
  if not d.name.isdigit() or int(d.name)==os.getpid():continue
  try: owns=('PUBLICATION_PRIVATE_DIR='+str(private)).encode() in (d/'environ').read_bytes().split(b'\0')
  except OSError:continue
  if owns:
   i=ident(d.name)
   if i: ledger[str(i['pid'])]=i
 put(private/'processes.json',ledger)
def run(args,timeout=180):
 # One recovery deadline includes the 60s TERM/10s KILL owner join. Reserve
 # the final 10s for joining a timed-out helper, then emit failed evidence.
 timeout=min(timeout,cleanupDeadline-time.monotonic()-10)
 if timeout<=0:raise RuntimeError('bounded exact cleanup budget exhausted; proof missing')
 with subprocess.Popen(args,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True) as child:
  identity=ident(child.pid)
  if identity:ledger[str(child.pid)]=identity;put(private/'processes.json',ledger)
  try:out,err=child.communicate(timeout=timeout)
  except subprocess.TimeoutExpired:
   # Recovery helper owns its exact initial process group; no global signals.
   if identity and same(identity):os.killpg(identity['pgid'],signal.SIGKILL)
   try:child.communicate(timeout=10)
   except subprocess.TimeoutExpired:raise RuntimeError('recovery descendants did not join; cleanup proof missing')
   raise RuntimeError('recovery command timed out; cleanup proof missing')
  if child.returncode:raise RuntimeError('command '+args[0].split('/')[-1]+' '+args[1]+' failed: '+error(err))
  return out.strip()
def inventory():
 return {'containers':sorted(run(['docker','ps','-aq','--no-trunc']).split()),'imageIds':sorted(set(run(['docker','image','ls','-aq','--no-trunc']).split()))}
if mode=='run':
 private=P(tempfile.mkdtemp(prefix='publication-v4-private.',dir=BASE));private.chmod(0o700)
 evidence=P(tempfile.mkdtemp(prefix='publication-v4-evidence.',dir=BASE))
 budget=json.loads((BASE/'publication-budget.json').read_text())
 nativeBudget=os.environ.get('PUBLICATION_NATIVE_BUDGET','')
 assert re.fullmatch('[0-9]{4}',nativeBudget)
 nativeBudget=int(nativeBudget);assert 1510<=nativeBudget<=1680
 assert budget['status']=='ALLOCATED_NOT_PROOF' and budget['nativeBudgetSeconds']==nativeBudget
 assert type(budget['elapsedSeconds']) is int and 0<=budget['elapsedSeconds']<=420
 assert nativeBudget==min(1680,2400-budget['elapsedSeconds']-350-110-10)
 startedNs=budget['allocatedAtMonotonicNs'];assert type(startedNs) is int and 0<startedNs<=time.monotonic_ns()
 deadlineNs=startedNs+nativeBudget*1000000000
 runReceipt={'budget':budget,'nativeStarted':False,'nativeStartedEpochSeconds':None,
             'nativeStartedMonotonicNs':None,'nativeExitStatus':None,'exitCode':None,
             'timedOut':None,'proofMissing':True}
 put(evidence/'controller-run.json',runReceipt)
 preflightEnv={'PATH':os.environ['PATH'],'HOME':str(private/'home'),'XDG_CONFIG_HOME':str(private/'config'),'CI':'1'}
 binding=P(os.environ['PUBLICATION_BINDING']).resolve();binary=P(os.environ['CRABBOX_PROOF_BINARY']).resolve()
 b=json.loads(binding.read_text());assert all(b.get(k) is True for k in ('reviewed','runtimeGraphReviewed','manualBuildOrderingReviewed','alwaysCleanupReviewed','bundleLinkageReviewed'))
 for k in ('candidateSha','candidateTree','overlayTree','controllerSha'):assert re.fullmatch('[a-f0-9]{40}',b.get(k) or ''),k
 assert b['provider']=='local-container'
 controllerRoot=P(os.environ['PUBLICATION_CONTROLLER_ROOT']).resolve()
 assert subprocess.check_output(['git','-C',str(controllerRoot),'rev-parse','HEAD'],text=True,env=preflightEnv).strip()==b['controllerSha']
 for name,digest in b['controllerFiles'].items():
  assert '/' not in name and name in ('hosted-run.sh','always-cleanup.sh','controller.py')
  assert sha((P(__file__).resolve().parent/name).read_bytes())==digest
 assert set(b['controllerFiles'])=={'hosted-run.sh','always-cleanup.sh','controller.py'}
 def git(*args):return subprocess.check_output(['git',*args],text=True,env=preflightEnv).strip()
 assert git('rev-parse','HEAD')==b['candidateSha'];assert git('rev-parse','HEAD^{tree}')==b['candidateTree']
 assert git('write-tree')==b['overlayTree'];subprocess.run(['git','diff','--quiet'],check=True,env=preflightEnv)
 assert set(git('diff','--cached','--name-only','HEAD').splitlines())==set(b['overlayFiles']);assert len(b['overlayFiles'])==2
 for f,h in b['overlayFiles'].items():assert sha(P(f).read_bytes())==h
 assert sha(binary.read_bytes())==b['crabboxExecutableSha256']
 assert subprocess.check_output(['node','--version'],text=True,env=preflightEnv).strip()=='v'+b['nodeVersion']
 receipt=P(os.environ['PUBLICATION_BUILD_RECEIPT']).read_bytes();assert sha(receipt)==b['buildReceiptSha256']
 build=json.loads(receipt);assert build['candidateSha']==b['candidateSha']
 assert isinstance(b['buildRecipe'],str) and b['buildRecipe'].strip()
 assert build['recipe']==b['buildRecipe'] and build['exitCode']==0
 meta=P('dist/build-info.json').read_bytes();assert sha(meta)==b['buildInfoSha256']
 assert json.loads(meta)['commit']==b['candidateSha'] and json.loads(meta)['buildId']
 target=P('build-info.json').absolute();assert not target.is_symlink()
 previous=target.read_bytes() if target.exists() else None
 if previous is not None:(private/'original-build-info').write_bytes(previous)
 put(private/'metadata.json',{'target':str(target),'existed':previous is not None,'beforeSha256':sha(previous) if previous is not None else None,'stagedSha256':sha(meta)})
 (evidence/'binding.json').write_bytes(binding.read_bytes())
 put(LOC,{'private':str(private),'evidence':str(evidence),'binary':str(binary),'cwd':os.getcwd()})
 target.write_bytes(meta);assert target.read_bytes()==meta
 put(evidence/'metadata-staging.json',{'generatedSha256':sha(meta),'rootSha256':sha(target.read_bytes()),'candidateSha':b['candidateSha'],'restored':False})
 for d in ('home','cache','config','state'):(private/d).mkdir()
else:
 loc=json.loads(LOC.read_text());private=P(loc['private']);evidence=P(loc['evidence']);binary=P(loc['binary']);os.chdir(loc['cwd'])
 assert private.parent==BASE and evidence.parent==BASE
 b=json.loads((evidence/'binding.json').read_text());assert sha(binary.read_bytes())==b['crabboxExecutableSha256']
env={'PATH':os.environ['PATH'],'HOME':str(private/'home'),'XDG_CONFIG_HOME':str(private/'config'),'XDG_STATE_HOME':str(private/'state'),'XDG_CACHE_HOME':str(private/'cache'),'CI':'1','GITHUB_ACTIONS':'true','RUNNER_ENVIRONMENT':'github-hosted','OPENCLAW_LIVE_TEST':'1','OPENCLAW_PUBLICATION_LIVE':'1','CRABBOX_PROOF_BINARY':str(binary),'PUBLICATION_BINDING':str(evidence/'binding.json'),'PUBLICATION_PRIVATE_DIR':str(private),'PUBLICATION_EVIDENCE_DIR':str(evidence),'CRABBOX_LOCAL_CONTAINER_RUNTIME':'docker','CRABBOX_LOCAL_CONTAINER_NETWORK':'bridge','CRABBOX_LOCAL_CONTAINER_DOCKER_SOCKET':'false','CRABBOX_LOCAL_CONTAINER_CPUS':'2','CRABBOX_LOCAL_CONTAINER_MEMORY':'4g','CRABBOX_LOCAL_CONTAINER_IMAGE':'docker.io/library/node:24-bookworm@sha256:be23f54a88d34e8824c741b19b91064094f92c1c97b194144bfc8b50d67258e2'}
ledger=json.loads((private/'processes.json').read_text()) if (private/'processes.json').exists() else {}
if mode=='run':
 # All native setup/import/Docker pull is inside this owner deadline. Slow
 # controller preflight cannot steal the original 1500s test allowance.
 if deadlineNs-time.monotonic_ns()<1500*1000000000:raise RuntimeError('Preallocation refusal: controller startup consumed full-scenario allowance')
 timedout=False
 with (private/'native-output.log').open('wb') as log:
  runReceipt.update(nativeStarted=None,nativeLaunchEpochSeconds=time.time(),nativeLaunchMonotonicNs=time.monotonic_ns())
  put(evidence/'controller-run.json',runReceipt)
  child=subprocess.Popen(['node','scripts/run-vitest.mjs','run','--config','test/vitest/vitest.live.config.ts','src/gateway/worker-environments/provider-publication.local-container.live.test.ts','--reporter=verbose'],env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
  first=ident(child.pid);assert first;ledger[str(child.pid)]=first;put(private/'processes.json',ledger)
  runReceipt.update(nativeStarted=True,nativeStartedEpochSeconds=time.time(),nativeStartedMonotonicNs=time.monotonic_ns())
  put(evidence/'controller-run.json',runReceipt)
  while child.poll() is None:
   discover()
   if time.monotonic_ns()>=deadlineNs:timedout=True;break
   time.sleep(.25)
  timedout=timedout or time.monotonic_ns()>=deadlineNs
  runReceipt.update(exitCode=child.poll(),nativeExitStatus=child.returncode,timedOut=timedout,
                    wallSeconds=(time.monotonic_ns()-startedNs)/1000000000,proofMissing=timedout or child.returncode!=0)
  put(evidence/'controller-run.json',runReceipt)
 sys.exit(124 if timedout else child.returncode)
cleanupDeadline=time.monotonic()+320
errors=[];forced=False;absence=False
try:
 discover()
 for sig,seconds in ((signal.SIGTERM,60),(signal.SIGKILL,10)):
  live=[i for i in ledger.values() if same(i)]
  if not live:break
  forced=True
  for i in live:
   if same(i):
    try:os.kill(i['pid'],sig)
    except ProcessLookupError:pass
  until=time.monotonic()+seconds
  while time.monotonic()<until:
   discover()
   if not any(same(i) for i in ledger.values()):break
   time.sleep(.25)
 assert not any(same(i) for i in ledger.values()),'owned command processes remain; no cleanup receipt'
 leases=set();lp=private/'owned-leases.jsonl'
 if lp.exists():
  for line in lp.read_text().splitlines():
   x=json.loads(line)['leaseId'];assert re.fullmatch('[A-Za-z0-9_-]+',x);leases.add(x)
 try:
  catalog=json.loads(run([str(binary),'checkpoint','list','--local-only','--json']));assert isinstance(catalog,list)
 except Exception as e:errors.append(error(e));catalog=[]
 images=[i for i in catalog if i.get('provider')=='local-container' and i.get('leaseId') in leases]
 for lease in sorted(leases):
  try:run([str(binary),'stop','--provider','local-container','--id',lease])
  except Exception as e:errors.append(error(e))
 try:catalogAfter=json.loads(run([str(binary),'checkpoint','list','--local-only','--json']))
 except Exception as e:errors.append(error(e));catalogAfter=[]
 byId={i['id']:i for i in images}
 for i in catalogAfter:
  if i.get('provider')=='local-container' and i.get('leaseId') in leases:byId[i['id']]=i
 for image in byId.values():
  try:
   assert re.fullmatch('chk_[A-Za-z0-9_-]+',image['id'])
   run([str(binary),'checkpoint','delete',image['id']])
  except Exception as e:errors.append(error(e))
 baseline=json.loads((private/'baseline.json').read_text());final=inventory();absence=baseline==final
 assert absence,'full daemon inventory differs; missing cleanup proof, dispose VM'
 discover();assert not any(same(i) for i in ledger.values()),'cleanup helper descendants remain'
 put(evidence/'always-inventory.json',{'baseline':baseline,'final':final,'absence':absence})
except Exception as e:errors.append(error(e))
finally:
 try:
  m=json.loads((private/'metadata.json').read_text());target=P(m['target'])
  assert not target.is_symlink() and sha(target.read_bytes())==m['stagedSha256'],'staged metadata changed; do not overwrite'
  if m['existed']:target.write_bytes((private/'original-build-info').read_bytes());assert sha(target.read_bytes())==m['beforeSha256']
  else:target.unlink()
  put(evidence/'metadata-restoration.json',{'restored':True,'beforeSha256':m['beforeSha256'],'stagedSha256':m['stagedSha256']})
 except Exception as e:errors.append(error(e))
 runReceipt=json.loads((evidence/'controller-run.json').read_text()) if (evidence/'controller-run.json').exists() else {}
 proof=json.loads((evidence/'live-publication.json').read_text()) if (evidence/'live-publication.json').exists() else {}
 outer=json.loads((BASE/'publication-outer.json').read_text()) if (BASE/'publication-outer.json').exists() else {}
 passed=not forced and not errors and absence and outer.get('exitStatus')==0 and runReceipt.get('timedOut') is False and runReceipt.get('nativeExitStatus')==0 and runReceipt.get('proofMissing') is False and proof.get('passed') is True
 put(evidence/'always-cleanup.json',{'passed':passed,'physicalAbsence':absence,'forcedProcessTermination':forced,'proofMissing':not passed,'errors':errors,'vmDisposalIsContainmentOnly':True})
 sys.exit(0 if passed else 1)
