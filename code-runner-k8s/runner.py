"""Runs INSIDE the sandbox Job pod (not in the API pod).

Reads the user's code from CODE_B64, runs it in a child interpreter with CPU and
memory rlimits plus a wall-clock timeout, and prints ONE JSON line with the result.
The runner exits 0 whenever it produced a result, so a non-zero container exit
means the sandbox itself failed (OOMKilled, deadline, crash).
"""
import base64
import json
import os
import resource
import shutil
import subprocess
import sys
import tempfile

TIMEOUT = int(os.environ.get("RUN_TIMEOUT", "5"))
MAX_OUT = 64 * 1024
CPU_LIMIT = TIMEOUT
MEM_LIMIT = 100 * 1024 * 1024


def limits():
    resource.setrlimit(resource.RLIMIT_CPU, (CPU_LIMIT, CPU_LIMIT))
    resource.setrlimit(resource.RLIMIT_AS, (MEM_LIMIT, MEM_LIMIT))
    # No RLIMIT_NPROC on purpose: it counts every process of this UID on the whole node,
    # across all pods. Process count is capped by the cgroup / kubelet pids limit instead.


def main() -> None:
    code = base64.b64decode(os.environ["CODE_B64"])
    tmp = tempfile.mkdtemp(dir="/tmp")
    try:
        with open(os.path.join(tmp, "script.py"), "wb") as f:
            f.write(code)
        try:
            r = subprocess.run(
                [sys.executable, "-I", "script.py"],
                cwd=tmp, capture_output=True, timeout=TIMEOUT,
                preexec_fn=limits,
                env={"PATH": "/usr/local/bin:/usr/bin:/bin"},   # CODE_B64 is NOT passed to the child
            )
            out = {
                "stdout": r.stdout.decode("utf-8", "replace")[-MAX_OUT:],
                "stderr": r.stderr.decode("utf-8", "replace")[-MAX_OUT:],
                "exit_code": r.returncode,
                "timed_out": False,
            }
        except subprocess.TimeoutExpired:
            out = {"stdout": "", "stderr": "", "exit_code": -1, "timed_out": True}
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print(json.dumps(out), flush=True)


if __name__ == "__main__":
    main()