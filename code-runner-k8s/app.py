"""Code-runner API, Kubernetes edition.

The API never executes user code itself. For every submission it creates a
short-lived Kubernetes Job in the locked-down `sandbox` namespace, waits for it,
reads the result from the pod log, then deletes the Job.
"""
import base64
import json
import logging
import os
import threading
import time
import uuid
logging.basicConfig(level=logging.INFO)
from flask import Flask, jsonify, render_template, request
from kubernetes import client, config
from kubernetes.client.rest import ApiException

app = Flask(__name__)
log = logging.getLogger("code-runner")


SANDBOX_NS = os.environ.get("SANDBOX_NAMESPACE", "sandbox")
RUNNER_IMAGE = os.environ["RUNNER_IMAGE"]                 # same image as the API; Job overrides the command
IMAGE_PULL_SECRET = os.environ.get("IMAGE_PULL_SECRET", "")  # registry-<name> secret that lets nodes pull from DOCR
TIMEOUT_SECONDS = int(os.environ.get("RUN_TIMEOUT", "5"))  # wall clock for the user's script
JOB_DEADLINE = int(os.environ.get("JOB_DEADLINE", "20"))   # k8s kills the Job after this (includes pod start-up)
WAIT_SECONDS = JOB_DEADLINE + 5                            # how long a request waits for the Job
MAX_CODE_BYTES = 64 * 1024
MAX_CONCURRENT_JOBS = int(os.environ.get("MAX_CONCURRENT_JOBS", "8"))
LOG_LIMIT_BYTES = 1024 * 1024

app.config["MAX_CONTENT_LENGTH"] = 128 * 1024

try:
    config.load_incluster_config()      # inside the cluster: uses the Pod's ServiceAccount token
except config.ConfigException:
    config.load_kube_config()           # on your laptop: uses ~/.kube/config
batch = client.BatchV1Api()
core = client.CoreV1Api()

slots = threading.BoundedSemaphore(MAX_CONCURRENT_JOBS)   # backpressure: no unbounded Job creation


def job_manifest(name: str, code_b64: str) -> dict:
    return {
        "apiVersion": "batch/v1",
        "kind": "Job",
        "metadata": {"name": name, "labels": {"app": "sandbox-run"}},
        "spec": {
            "backoffLimit": 0,                         # never retry user code
            "activeDeadlineSeconds": JOB_DEADLINE,     # hard kill by Kubernetes
            "ttlSecondsAfterFinished": 60,             # janitor if this API dies before cleanup
            "template": {
                "metadata": {"labels": {"app": "sandbox-run"}},
                "spec": {
                    "restartPolicy": "Never",
                    "automountServiceAccountToken": False,   # no k8s credentials inside the sandbox
                    "enableServiceLinks": False,
                    # "runtimeClassName": "gvisor",          # uncomment if your cluster offers it
                    "securityContext": {
                        "runAsNonRoot": True,
                        "runAsUser": 10001,
                        "runAsGroup": 10001,
                        "seccompProfile": {"type": "RuntimeDefault"},
                    },
                    # The sandbox Pods pull the SAME private image from DOCR, so they need the pull secret too
                    **({"imagePullSecrets": [{"name": IMAGE_PULL_SECRET}]} if IMAGE_PULL_SECRET else {}),
                    "containers": [{
                        "name": "run",
                        "image": RUNNER_IMAGE,
                        "imagePullPolicy": "IfNotPresent",
                        "command": ["python", "-I", "/app/runner.py"],
                        "env": [
                            {"name": "CODE_B64", "value": code_b64},
                            {"name": "RUN_TIMEOUT", "value": str(TIMEOUT_SECONDS)},
                        ],
                        "resources": {
                            "requests": {"cpu": "100m", "memory": "64Mi"},
                            "limits": {"cpu": "500m", "memory": "128Mi", "ephemeral-storage": "64Mi"},
                        },
                        "securityContext": {
                            "allowPrivilegeEscalation": False,
                            "readOnlyRootFilesystem": True,
                            "capabilities": {"drop": ["ALL"]},
                        },
                        "volumeMounts": [{"name": "tmp", "mountPath": "/tmp"}],
                    }],
                    "volumes": [{"name": "tmp", "emptyDir": {"sizeLimit": "64Mi"}}],
                },
            },
        },
    }


def wait_for_job(name: str) -> str:
    deadline = time.monotonic() + WAIT_SECONDS
    while time.monotonic() < deadline:
        pod = find_pod(name)
        if pod is not None:
            phase = pod.status.phase
            if phase == "Succeeded":
                return "succeeded"
            if phase == "Failed":
                return "failed"
        time.sleep(0.25)
    return "timeout"


def find_pod(name: str):
    pods = core.list_namespaced_pod(SANDBOX_NS, label_selector=f"job-name={name}").items
    return pods[0] if pods else None


# def read_result(pod):
#     """The runner prints exactly one JSON line; take the last non-empty log line."""
#     text = core.read_namespaced_pod_log(
#         pod.metadata.name, SANDBOX_NS, container="run", limit_bytes=LOG_LIMIT_BYTES
#     )
#     lines = [ln for ln in text.splitlines() if ln.strip()]
#     if not lines:
#         return None
#     try:
#         return json.loads(lines[-1])
#     except json.JSONDecodeError:
#         return None

def read_result(pod):
    """The runner prints exactly one JSON line; take the last non-empty log line."""
    resp = core.read_namespaced_pod_log(
        pod.metadata.name, SANDBOX_NS, container="run",
        limit_bytes=LOG_LIMIT_BYTES, _preload_content=False,
    )
    text = resp.data.decode("utf-8", "replace")
    lines = [ln for ln in text.splitlines() if ln.strip()]
    if not lines:
        log.warning("empty pod log for %s", pod.metadata.name)
        return None
    try:
        return json.loads(lines[-1])
    except json.JSONDecodeError:
        log.warning("unparseable pod log for %s: %r", pod.metadata.name, text[:200])
        return None


def failure_reason(pod) -> str:
    if pod is None:
        return "no pod was created"
    for cs in pod.status.container_statuses or []:
        t = cs.state.terminated
        if t and t.reason:
            return t.reason                      # e.g. OOMKilled, Error
    return pod.status.reason or pod.status.phase or "unknown"


def delete_job(name: str) -> None:
    try:
        batch.delete_namespaced_job(name, SANDBOX_NS, propagation_policy="Background")
    except ApiException as e:
        if e.status != 404:
            log.warning("could not delete job %s: %s", name, e.reason)


@app.route("/")
def health():
    return jsonify(status="ok", service="code-runner executor (k8s jobs)")


@app.route("/home")
def home():
    return render_template("index.html")


@app.route("/execute", methods=["POST"])
def execute():
    data = request.get_json(silent=True) or {}
    code = data.get("code")

    if not code or not isinstance(code, str):
        return jsonify(error="Missing 'code' (string)"), 400
    raw = code.encode("utf-8")
    if len(raw) > MAX_CODE_BYTES:
        return jsonify(error=f"Code too large (max {MAX_CODE_BYTES} bytes)"),413
    if not slots.acquire(blocking=False):
        resp = jsonify(error="Server busy ,retry shortly")
        resp.status_code = 503
        resp.headers["Retry-After"] = "2"
        return resp

    name = f"run-{uuid.uuid4().hex[:10]}"
    created = False

    try:
        try:
            batch.create_namespaced_job(SANDBOX_NS,job_manifest(name,base64.b64encode(raw).decode()))
            created = True
        except ApiException as e:
            if e.status == 403 and "exceeded quota" in (e.body or ""):
                resp = jsonify(error="Sandbox is at capacity,retry shortly")
                resp.status_code = 503
                resp.headers["Retry-After"] = "2"
                return resp
            log.error("job create failed: %s %s",e.status,e.reason)
            return jsonify(error="Could not start sandbox"),502
        outcome = wait_for_job(name)
        pod = find_pod(name)

        if outcome == "succeeded" and pod is not None:
            res = read_result(pod)
            if res is None:
                return jsonify(error="Sandbox produced no result"),502
            if res.get("timed_out"):
                return jsonify(error=f"Execution timed out after {TIMEOUT_SECONDS}s"),408
            return jsonify(stdout=res.get("stdout",""),stderr=res.get("stderr",""),exit_code=res.get("exit_code",-1))

        reason = failure_reason(pod)
        if reason == "OOMKilled":
            return jsonify(stdout="", stderr="Killed: memory limit exceeded", exit_code=137)
        if outcome == "timeout":
            return jsonify(error="Sandbox did not finish in time (cluster may be busy)"), 504
        return jsonify(error=f"Sandbox failed: {reason}"), 502
    finally:
        if created:
            delete_job(name)
        slots.release()


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 5000))
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 5000)), debug=False)