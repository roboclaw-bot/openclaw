#!/usr/bin/env python3
"""Hosted-only, fixed native command; passive /proc argv capture, no test hooks."""
import datetime
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

out = Path(os.environ["RUNNER_TEMP"]) / "pr159178-migration-diagnostic"
command = ["/usr/bin/time", "-p", "-o", str(out / "native.time.txt"),
           "node", "--import", "tsx", "scripts/ci-run-node-test-shard.mts"]
(out / "native.argv.json").write_text(json.dumps(command, indent=2) + "\n")
started = datetime.datetime.now(datetime.timezone.utc).isoformat()
(out / "native.started.txt").write_text(started + "\n")
child = subprocess.Popen(command)
# Descendant tracking is observational: no pool, affinity, grants, preload, or signal injection.
seen = set()
known = {}
keys = {"OPENCLAW_VITEST_MAX_WORKERS", "OPENCLAW_VITEST_RUNTIME",
        "OPENCLAW_TEST_PROJECTS_PARALLEL", "OPENCLAW_VITEST_SHARD_NAME",
        "OPENCLAW_VITEST_INCLUDE_FILE", "OPENCLAW_VITEST_POST_SHARD_INCLUDE_FILE",
        "OPENCLAW_VITEST_FS_MODULE_CACHE_ROOT", "OPENCLAW_VITEST_FS_MODULE_CACHE_PATH",
        "NODE_OPTIONS", "VITEST_POOL_ID", "VITEST_WORKER_ID"}
interrupted = []
def forward(signum, _frame):
    interrupted.append(signum)
    if child.poll() is None:
        child.send_signal(signum)
signal.signal(signal.SIGTERM, forward)
signal.signal(signal.SIGINT, forward)
with (out / "native.processes.jsonl").open("w", buffering=1) as log:
    while True:
        processes = {}
        for directory in Path("/proc").iterdir():
            if not directory.name.isdigit():
                continue
            try:
                fields = (directory / "stat").read_text().rsplit(")", 1)[1].split()
                processes[int(directory.name)] = (int(fields[1]), fields[19], directory)
            except (OSError, ValueError, IndexError):
                continue
        descendants = {child.pid} | {pid for pid, birth in known.items()
                                     if pid in processes and processes[pid][1] == birth}
        while True:
            expanded = descendants | {pid for pid, (ppid, _, _) in processes.items()
                                      if ppid in descendants}
            if expanded == descendants:
                break
            descendants = expanded
        known = {pid: processes[pid][1] for pid in descendants & processes.keys()}
        for pid in sorted(known):
            ppid, birth, directory = processes[pid]
            try:
                argv = [v.decode(errors="replace") for v in (directory / "cmdline").read_bytes().split(b"\0") if v]
                identity = (pid, birth, tuple(argv))
                if not argv or identity in seen:
                    continue
                # Retain only declared routing fields, never the complete environment.
                env = {}
                for item in (directory / "environ").read_bytes().split(b"\0"):
                    key, _, value = item.partition(b"=")
                    if key.decode(errors="replace") in keys:
                        env[key.decode()] = value.decode(errors="replace")
                record = {"observedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                          "pid": pid, "ppid": ppid, "startTicks": birth,
                          "exe": os.readlink(directory / "exe"), "argv": argv, "routing": env}
                log.write(json.dumps(record) + "\n")
                seen.add(identity)
            except (OSError, ValueError):
                continue
        if child.poll() is not None:
            break
        time.sleep(0.2)
returncode = child.wait()
status = returncode if returncode >= 0 else 128 - returncode
(out / "native.exit.txt").write_text(str(status) + "\n")
(out / "native.result.json").write_text(json.dumps({
    "startedAt": started, "endedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "argv": command, "nativeExitStatus": status, "forwardedSignals": interrupted,
    "observation": "Passive 200ms snapshots; absence of a short-lived process is not proof of nonexecution.",
    "classification": "UNCLASSIFIED: nonzero is not RED; green is at most non-reproduction."
}, indent=2) + "\n")
sys.exit(status)
