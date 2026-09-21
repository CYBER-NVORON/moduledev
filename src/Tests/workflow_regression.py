"""Own PostgreSQL/worker regressions. Run with Python 3 and Docker Compose.

Creates a unique project without published ports; always removes its containers
and volume. Uses real CLI publication, restricted worker calls and a real worker.
No Python packages or local .NET SDK are required.
"""

import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import uuid


ROOT = Path(__file__).resolve().parents[2]
SCHEMA = "https://json-schema.org/draft/2020-12/schema"


def literal(value):
    if not isinstance(value, str):
        value = json.dumps(value)
    return "'" + value.replace("'", "''") + "'"


def wait_for(read, accept, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = read()
        if accept(value):
            return value
        time.sleep(0.2)
    raise AssertionError(f"Timed out; last observation: {value}")


class Regression:
    def __init__(self, directory):
        self.directory = directory
        self.project = "moduledev-regression-" + uuid.uuid4().hex[:10]
        self.workers = set()
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("COURSE_", "PROVIDER_", "COMPOSE_"))}
        self.env.update(COURSE_TEST_PROFILE="1", COMPOSE_PARALLEL_LIMIT="2")
        for role in ("POSTGRES", "RUNTIME", "PUBLISHER", "MIGRATOR", "WORKER", "OUTBOX", "INBOX"):
            self.env[f"COURSE_{role}_PASSWORD"] = uuid.uuid4().hex
        (directory / "empty.env").write_text("", encoding="utf-8")
        init = directory / "init"
        init.mkdir()
        # Real old database, not a forged migration ledger: apply only 001..010.
        files = sorted((ROOT / "migrations").glob("*.sql"))
        files = [f for f in files if f.name < "011"]
        files += [ROOT / "src/Postgres" / name for name in
                  ("000_set_passwords.sh", "999_record_migrations.sh")]
        for source in files:
            (init / source.name).write_text(source.read_text(encoding="utf-8"),
                                            encoding="utf-8", newline="\n")
        override = {"services": {
            "postgres": {"volumes": [f"{init.as_posix()}:/docker-entrypoint-initdb.d:ro"]},
            "cli": {"volumes": [f"{directory.as_posix()}:/regression:ro"]},
            "worker-a": {"image": self.project + "-worker"},
            "worker-b": {"image": self.project + "-worker"},
        }}
        (directory / "compose.json").write_text(json.dumps(override), encoding="utf-8")
        self.compose = ["docker", "compose", "--env-file", str(directory / "empty.env"),
                        "-p", self.project, "-f", str(ROOT / "compose.yaml"),
                        "-f", str(directory / "compose.json")]

    def run(self, args, data=None, ok=True, timeout=120):
        result = subprocess.run(args, input=data, text=True, encoding="utf-8",
                                errors="replace", capture_output=True, cwd=ROOT,
                                env=self.env, timeout=timeout)
        if ok and result.returncode:
            raise AssertionError(f"Command failed: {args}\n{result.stdout}\n{result.stderr[-8000:]}")
        return result

    def sql(self, statement, ok=True):
        return self.run(self.compose + ["exec", "-T", "postgres", "psql", "-X", "-qAt",
                        "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", "course"], statement, ok)

    def query(self, expression, role=None):
        prefix = f"SET ROLE {role};\n" if role else ""
        return json.loads(self.sql(prefix + "SELECT " + expression + ";").stdout)

    def cli(self, *args, document=None, ok=True):
        if document is not None:
            (self.directory / "input.json").write_text(json.dumps(document), encoding="utf-8")
            args = (*args, "/regression/input.json")
        result = self.run(self.compose + ["run", "--rm", "-T", "--no-deps", "cli", *args], ok=ok)
        return result, json.loads(result.stdout)

    def publish(self, flow):
        self.cli("flow", "publish", document=flow)
        self.cli("flow", "activate", flow["flow_name"], "--version", str(flow["version"]))

    def start(self, flow, key, data):
        return self.query(f"workflow.start_process({literal(flow)}, {literal(key)}, {literal(data)}::jsonb)",
                          "course_publication")["processId"]

    def claim(self, owner):
        return self.query(f"workflow.claim_jobs({literal(owner)}, 1, 60)", "workflow_worker")

    def snapshot(self, pid):
        return self.query(f"""jsonb_build_object(
            'process', (SELECT state FROM workflow.process_instances WHERE process_id={literal(pid)}),
            'jobs', (SELECT jsonb_agg(to_jsonb(j) ORDER BY job_id) FROM workflow.jobs j WHERE process_id={literal(pid)}),
            'attempts', (SELECT jsonb_agg(to_jsonb(a) ORDER BY attempt_number) FROM workflow.attempts a
                JOIN workflow.jobs j USING(job_id) WHERE j.process_id={literal(pid)}),
            'events', (SELECT jsonb_agg(to_jsonb(e) ORDER BY event_id) FROM workflow.events e WHERE process_id={literal(pid)}),
            'effects', (SELECT count(*) FROM regression.effects WHERE process_id={literal(pid)}))""")

    def expire(self, job):
        self.sql(f"UPDATE workflow.jobs SET lease_until=clock_timestamp()-interval '1 second' WHERE job_id={literal(job['jobId'])};")

    def finish(self, job, owner):
        context = {"principal": "workflow-worker", "consumer": "internal",
                   "scopes": ["workflow:execute", "payment:internal"],
                   "requestId": job["executionId"], "correlationId": str(uuid.uuid4()),
                   **{key: job[key] for key in ("processId", "jobId", "executionId", "attemptId")}}
        return self.sql(f"""BEGIN; SET LOCAL ROLE workflow_worker;
            SELECT api.invoke('regression', 'nullable', 1, {literal(context)}::jsonb, '{{"value":"ok"}}');
            SELECT workflow.finish_job({literal(job['jobId'])}, {literal(owner)}, {job['leaseVersion']}, 'DONE', '{{}}');
            COMMIT;""", ok=False)

    def worker(self, failpoint=""):
        name = self.project + "-worker-" + uuid.uuid4().hex[:6]
        self.run(self.compose + ["run", "--rm", "-d", "--no-deps", "--name", name,
                                 "-e", "COURSE_FAILPOINT=" + failpoint, "worker-a"])
        self.workers.add(name)
        return name

    def stop_worker(self, name):
        self.run(["docker", "kill", name])
        wait_for(lambda: self.run(["docker", "inspect", name], ok=False).returncode, bool)
        self.workers.remove(name)

    def upgrade(self):
        self.run(self.compose + ["build", "postgres", "cli", "worker-a"], timeout=900)
        self.run(self.compose + ["up", "-d", "--wait", "postgres"], timeout=120)
        # pg_isready can succeed during initdb, before the migration ledger is filled.
        wait_for(lambda: self.sql("SELECT count(*) FROM catalog.migrations;", ok=False).stdout.strip(),
                 lambda count: count == "10", timeout=90)
        old = self.query("jsonb_object_agg(filename, checksum_sha256) FROM catalog.migrations")
        assert len(old) == 10, old
        assert old["004_workflow_schema.sql"] == "04374772050b5360a3cb8a1088ee2f92d158a7b32837da4ba81f4c479e2bed88"
        self.cli("migration", "apply", "/migrations")
        new = self.query("jsonb_object_agg(filename, checksum_sha256) FROM catalog.migrations")
        assert all(new[k] == v for k, v in old.items())
        assert "011_workflow_invariants.sql" in new
        self.cli("migration", "apply", "/migrations")
        assert new == self.query("jsonb_object_agg(filename, checksum_sha256) FROM catalog.migrations")
        print("PASS: upgrade 001..010 -> 011 and repeat migration", flush=True)

    def fixtures(self):
        self.sql((ROOT / "src/Tests/workflow_probe.sql").read_text(encoding="utf-8"))
        for action, value_type, policy in (("nullable", ["string", "null"], "workflow:execute"),
                                            ("strict", "string", "payment:internal"),
                                            ("forbidden", "string", "ungranted:scope")):
            manifest = {"contract_version": "course-1", "module": "regression", "action": action,
                        "version": 1, "http_method": "POST", "target_schema": "regression",
                        "target_function": "execute", "request_schema": {"$schema": SCHEMA,
                        "type": "object", "required": ["value"], "properties": {"value": {"type": value_type}},
                        "additionalProperties": False}, "response_schema": {"$schema": SCHEMA, "type": "object"},
                        "outcomes": ["DONE"], "required_policy": [policy], "idempotency_mode": "none",
                        "idempotency_scope": "none", "timeout_ms": 2000, "enabled": True, "is_default": True}
            self.cli("action", "publish", document=manifest)
        for action in ("nullable", "strict"):
            self.publish(flow_map(action))

    def immutability(self):
        for assignment in ("map_json=map_json || '{\"extra\":true}'", "map_hash='changed'",
                           "flow_name='changed'", "flow_version=99", "published_at=published_at+interval '1 second'"):
            result = self.sql("SET ROLE course_publication; UPDATE workflow.flow_versions SET " +
                              assignment + " WHERE flow_name='regression-nullable';", ok=False)
            assert result.returncode and "definition fields are immutable" in result.stderr, result.stderr
        second = flow_map("nullable")
        second["version"] = 2
        self.publish(second)
        self.cli("flow", "activate", "regression-nullable", "--version", "1")
        assert self.query("jsonb_agg(flow_version) FROM workflow.flow_versions WHERE flow_name='regression-nullable' AND is_active") == [1]
        print("PASS: publication-role immutability and CLI version activation", flush=True)

    def competing_claims_and_fencing(self):
        pid = self.start("regression-nullable", "competing", {"source": "ok"})
        barrier = threading.Barrier(2)

        def competing(owner):
            barrier.wait(timeout=10)
            result = self.sql(f"BEGIN; SET LOCAL ROLE workflow_worker; SELECT workflow.claim_jobs('{owner}',1,60); SELECT pg_sleep(1); COMMIT;")
            return owner, json.loads(result.stdout.splitlines()[0])

        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            claims = list(pool.map(competing, ("first", "second")))
        assert sorted(len(jobs) for _, jobs in claims) == [0, 1], claims
        owner, jobs = next((owner, jobs) for owner, jobs in claims if jobs)
        original = jobs[0]
        self.expire(original)
        reclaimed = self.claim("replacement")[0]
        assert all(original[k] == reclaimed[k] for k in ("jobId", "executionId", "processId"))
        assert original["attemptId"] != reclaimed["attemptId"]
        before = self.snapshot(pid)
        assert [a["status"] for a in before["attempts"]] == ["STALE", "RUNNING"]
        stale = self.finish(original, owner)
        assert stale.returncode and "workflow.lease_stale" in stale.stderr
        assert self.snapshot(pid) == before, "Stale finish must roll back the action effect and all workflow changes"
        current = self.finish(reclaimed, "replacement")
        assert current.returncode == 0, current.stderr
        after = self.snapshot(pid)
        assert after["process"] == "COMPLETED" and after["effects"] == 1
        assert [a["status"] for a in after["attempts"]] == ["STALE", "SUCCEEDED"]
        print("PASS: competing claims, reclaim identity, stale finish rollback", flush=True)

    def retry_budget(self):
        pid = self.start("regression-nullable", "retry-budget", {"source": "ok"})
        original = self.claim("expired")[0]
        self.expire(original)
        job = self.claim("retry")[0]
        for failure, expected, delay in ((1, "RETRY_WAIT", 2000), (2, "RETRY_WAIT", 4000), (3, "DEAD", None)):
            assert job["jobId"] == original["jobId"] and job["executionId"] == original["executionId"]
            result = self.query(f"workflow.fail_job({literal(job['jobId'])}, 'retry', {job['leaseVersion']}, 'test.retryable', true)", "workflow_worker")
            assert result["jobState"] == expected, result
            if delay:
                remaining = self.query(f"to_jsonb(extract(epoch FROM next_attempt_at-clock_timestamp())*1000) FROM workflow.jobs WHERE job_id={literal(job['jobId'])}")
                assert delay - 1500 < remaining <= delay, (delay, remaining)
                self.sql(f"UPDATE workflow.jobs SET next_attempt_at=clock_timestamp() WHERE job_id={literal(job['jobId'])};")
                job = self.claim("retry")[0]
        state = self.snapshot(pid)
        assert state["process"] == "FAILED" and state["effects"] == 0
        assert [a["status"] for a in state["attempts"]] == ["STALE", "FAILED", "FAILED", "FAILED"]
        assert len({a["attempt_id"] for a in state["attempts"]}) == 4
        assert sum(e["event_type"] == "TaskFailed" for e in state["events"]) == 1
        print("PASS: STALE does not consume retry budget; failure-indexed delays and exhaustion", flush=True)

    def signals(self):
        flow = {"contract_version": "course-1", "flow_name": "regression-signal", "version": 1,
                "start_step": "wait", "steps": [{"key": "wait", "type": "wait_signal", "signal_type": "test.done", "outcome": "DONE"},
                {"key": "end", "type": "end", "outcome": "DONE"}],
                "transitions": [{"from": "wait", "outcome": "DONE", "to": "end"}]}
        self.publish(flow)
        pid = self.start(flow["flow_name"], "signal", {})

        def signal(body):
            data = json.dumps(body)
            digest = hashlib.sha256(data.encode()).hexdigest()
            return self.query(f"workflow.accept_signal({literal(pid)}, 'test.done', 'regression-message', {literal(data)}::jsonb, '{digest}')", "course_publication")

        signal({"value": 1})
        before = self.snapshot(pid)
        assert before["process"] == "COMPLETED"
        assert signal({"value": 1})["status"] == "duplicate"
        assert signal({"value": 2})["code"] == "signal.conflict"
        assert self.snapshot(pid) == before
        assert self.query("to_jsonb(count(*)) FROM workflow.signals WHERE message_id='regression-message'") == 1
        assert sum(e["event_type"] == "SignalApplied" for e in before["events"]) == 1
        print("PASS: signal duplicate/conflict preserve state and history", flush=True)

    def mapping_and_policy(self):
        forbidden = flow_map("forbidden")
        for operation in ("validate", "publish"):
            result, envelope = self.cli("flow", operation, document=forbidden, ok=False)
            assert result.returncode and envelope["code"] == "map.invalid", envelope
        assert self.query("to_jsonb(count(*)) FROM workflow.flow_versions WHERE flow_name='regression-forbidden'") == 0
        # Bypass publication as owner to prove runtime has an independent policy check.
        self.sql(f"""INSERT INTO workflow.flow_definitions(flow_name) VALUES ('regression-forbidden');
            INSERT INTO workflow.flow_versions(flow_name,flow_version,map_json,map_hash,is_active)
            VALUES ('regression-forbidden',1,{literal(forbidden)}::jsonb,'test-only',true);""")
        cases = [("nullable", "null", {"source": None}, None),
                 ("nullable", "missing", {}, "workflow.mapping_missing"),
                 ("nullable", "wrong-type", {"source": 42}, "payload.invalid"),
                 ("strict", "null-rejected", {"source": None}, "payload.invalid"),
                 ("strict", "payment-policy", {"source": "ok"}, None),
                 ("forbidden", "policy-denied", {"source": "ok"}, "workflow.policy_denied")]
        processes = [(self.start("regression-" + action, key, data), error) for action, key, data, error in cases]
        worker = self.worker()
        try:
            for pid, error in processes:
                state = wait_for(lambda: self.snapshot(pid), lambda s: s["process"] in ("COMPLETED", "FAILED"))
                assert state["process"] == ("FAILED" if error else "COMPLETED"), state
                assert state["effects"] == (0 if error else 1), state
                assert len(state["attempts"]) == 1 and state["attempts"][0]["error_code"] == error
            null_payload = self.query(f"payload FROM regression.effects WHERE process_id={literal(processes[0][0])}")
            assert null_payload == {"value": None}
        finally:
            self.stop_worker(worker)
        print("PASS: missing/null/type validation, both contract scopes and denied policy at publish/runtime", flush=True)

    def crash_recovery(self):
        pid = self.start("regression-nullable", "crash", {"source": "ok"})
        worker = self.worker("after_action_before_finish")
        wait_for(lambda: self.run(["docker", "logs", worker]).stdout,
                 lambda log: '"event":"failpoint.reached"' in log)
        before = self.snapshot(pid)
        assert before["effects"] == 0 and before["jobs"][0]["state"] == "LEASED"
        self.stop_worker(worker)  # SIGKILL while the action/finish transaction is open.
        worker = self.worker()
        try:
            after = wait_for(lambda: self.snapshot(pid), lambda s: s["process"] == "COMPLETED")
        finally:
            self.stop_worker(worker)
        assert after["effects"] == 1
        assert all(before["jobs"][0][k] == after["jobs"][0][k] for k in ("job_id", "execution_id"))
        assert [a["status"] for a in after["attempts"]] == ["STALE", "SUCCEEDED"]
        assert len({a["attempt_id"] for a in after["attempts"]}) == 2
        assert sum(e["event_type"] == "TaskCompleted" for e in after["events"]) == 1
        print("PASS: crash after action rolls back effect; reclaim completes exactly once", flush=True)

    def close(self):
        for name in self.workers:
            self.run(["docker", "rm", "-f", name], ok=False)
        self.run(self.compose + ["down", "--volumes", "--remove-orphans"], timeout=120)


def flow_map(action):
    policy = {"nullable": "workflow:execute", "strict": "payment:internal", "forbidden": "ungranted:scope"}[action]
    return {"contract_version": "course-1", "flow_name": "regression-" + action, "version": 1,
            "start_step": "work", "steps": [{"key": "work", "type": "automatic", "task": {
                "service": "postgres", "module": "regression", "action": action, "action_version": 1,
                "required_policy": [policy], "timeout_ms": 2000, "retry": {"max_attempts": 3, "delays_ms": [2000, 4000]},
                "input_constants": {}, "input_mapping": {"/value": "/source"}}},
                {"key": "end", "type": "end", "outcome": "DONE"}],
            "transitions": [{"from": "work", "outcome": "DONE", "to": "end"}]}


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="moduledev-regression-") as temporary:
        suite = Regression(Path(temporary))
        try:
            for test in (suite.upgrade, suite.fixtures, suite.immutability,
                         suite.competing_claims_and_fencing, suite.retry_budget,
                         suite.signals, suite.mapping_and_policy, suite.crash_recovery):
                test()
            print("All workflow DB regressions passed.", flush=True)
        finally:
            suite.close()
