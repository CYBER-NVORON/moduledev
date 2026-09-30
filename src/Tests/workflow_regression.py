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
        # Containers run as unprivileged users; tempfile defaults to owner-only access.
        directory.chmod(0o755)
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
        (directory / "ports.yaml").write_text("services:\n  gateway:\n    ports: !reset []\n", encoding="utf-8")
        self.compose = ["docker", "compose", "--env-file", str(directory / "empty.env"),
                        "-p", self.project, "-f", str(ROOT / "compose.yaml"),
                        "-f", str(directory / "compose.json"), "-f", str(directory / "ports.yaml")]

    def run(self, args, data=None, ok=True, timeout=120):
        result = subprocess.run(args, input=data, text=True, encoding="utf-8",
                                errors="replace", capture_output=True, cwd=ROOT.parent,
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
            'steps', (SELECT jsonb_agg(to_jsonb(s) ORDER BY step_instance_id) FROM workflow.step_instances s WHERE process_id={literal(pid)}),
            'attempts', (SELECT jsonb_agg(to_jsonb(a) ORDER BY attempt_number) FROM workflow.attempts a
                JOIN workflow.jobs j USING(job_id) WHERE j.process_id={literal(pid)}),
            'events', (SELECT jsonb_agg(to_jsonb(e) ORDER BY event_id) FROM workflow.events e WHERE process_id={literal(pid)}),
            'effects', (SELECT count(*) FROM regression.effects WHERE process_id={literal(pid)}))""")

    def expire(self, job):
        self.sql(f"UPDATE workflow.jobs SET lease_until=clock_timestamp()-interval '1 second' WHERE job_id={literal(job['jobId'])};")

    def finish(self, job, owner, wait_for_expiry=False, check_live_lease=False):
        context = {"principal": "workflow-worker", "consumer": "internal",
                   "scopes": ["workflow:execute", "payment:internal"],
                   "requestId": job["executionId"], "correlationId": str(uuid.uuid4()),
                   **{key: job[key] for key in ("processId", "jobId", "executionId", "attemptId", "leaseVersion")}}
        pause = (f"RESET ROLE; SELECT pg_sleep(greatest(0,extract(epoch FROM lease_until-clock_timestamp()))+0.05) "
                 f"FROM workflow.jobs WHERE job_id={literal(job['jobId'])}; SET LOCAL ROLE workflow_worker;"
                 if wait_for_expiry else "")
        check = (f"DO $$ BEGIN ASSERT (SELECT lease_until > now() FROM workflow.jobs "
                 f"WHERE job_id={literal(job['jobId'])}), 'test transaction must begin before lease expiry'; END $$;"
                 if wait_for_expiry or check_live_lease else "")
        return self.sql(f"""BEGIN; {check} SET LOCAL ROLE workflow_worker;
            SELECT api.invoke('regression', 'nullable', 1, {literal(context)}::jsonb, '{{"value":"ok"}}');
            {pause}
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

    def invoke(self, module, action, payload, key=None, principal="regression-client", extra=None):
        context = {"principal": principal, "consumer": "regression", "requestId": key or uuid.uuid4().hex,
                   "correlationId": str(uuid.uuid4()),
                   "scopes": ["payment:write", "payment:read", "payment:internal", "workflow:manual", "receipt:write", "diagnostics:read"]}
        context.update(extra or {})
        return self.query(f"api.invoke({literal(module)}, {literal(action)}, 1, "
                          f"{literal(context)}::jsonb, {literal(payload)}::jsonb)", "course_runtime")

    def operation(self, kind="PAYMENT_APPROVAL", amount="100000.01"):
        response = self.invoke("payment", "request", {"operationKind": kind, "amount": amount, "currency": "RUB"})
        assert response["status"] == "ok", response
        return response["result"]["operationId"]

    def event_types(self, oid, relation="autocheck.operation_events"):
        return self.query(f"COALESCE(jsonb_agg(event_type ORDER BY occurred_at,event_id),'[]') "
                          f"FROM {relation} WHERE operation_id={literal(oid)}")

    def upgrade(self):
        self.run(self.compose + ["build", "postgres", "cli", "worker-a"], timeout=900)
        self.run(self.compose + ["up", "-d", "--wait", "postgres"], timeout=120)
        # pg_isready can succeed during initdb, before the migration ledger is filled.
        wait_for(lambda: self.sql("SELECT count(*) FROM catalog.migrations;", ok=False).stdout.strip(),
                 lambda count: count == "10", timeout=90)
        old = self.query("jsonb_object_agg(filename, checksum_sha256) FROM catalog.migrations")
        assert len(old) == 10, old
        assert old["004_workflow_schema.sql"] == "04374772050b5360a3cb8a1088ee2f92d158a7b32837da4ba81f4c479e2bed88"
        # Synthetic historical rows exercise the read compatibility without rewriting audit history.
        legacy = self.operation()
        self.sql(f"""INSERT INTO payment.operation_events(operation_id,event_type,payload_hash)
            SELECT {literal(legacy)}, name, repeat('0',64)
            FROM unnest(ARRAY['OperationSubmitted','OperationCompleted','OperationRejected']) AS name;""")
        history = self.query(f"jsonb_agg(to_jsonb(e) ORDER BY event_id) FROM payment.operation_events e "
                             f"WHERE operation_id={literal(legacy)}")
        self.cli("migration", "apply", "/migrations")
        new = self.query("jsonb_object_agg(filename, checksum_sha256) FROM catalog.migrations")
        assert all(new[k] == v for k, v in old.items())
        assert "011_workflow_invariants.sql" in new
        assert "012_operation_event_contract.sql" in new
        assert "013_outbox_retry_policy.sql" in new
        assert "014_outbox_reliability.sql" in new
        assert "015_diagnostics.sql" in new
        assert "016_lease_deadlines_and_stalled_age.sql" in new
        assert history == self.query(f"jsonb_agg(to_jsonb(e) ORDER BY event_id) FROM payment.operation_events e "
                                     f"WHERE operation_id={literal(legacy)}")
        expected = sorted(["OPERATION_CREATED", "OPERATION_SUBMITTED", "OPERATION_COMPLETED", "OPERATION_REJECTED"])
        assert sorted(self.event_types(legacy)) == expected
        public = self.invoke("operation", "events", {"operationId": legacy})
        assert sorted(e["eventType"] for e in public["result"]["events"]) == expected
        for invalid in ("OperationSubmitted", "OPERATION_UNKNOWN"):
            result = self.sql(f"INSERT INTO payment.operation_events(operation_id,event_type,payload_hash) "
                              f"VALUES ({literal(legacy)},{literal(invalid)},repeat('0',64));", ok=False)
            assert result.returncode and "operation_events_canonical_type" in result.stderr
        for statement in ("UPDATE payment.operation_events SET event_type='OPERATION_SUBMITTED'",
                          "DELETE FROM payment.operation_events"):
            result = self.sql(statement + f" WHERE operation_id={literal(legacy)};", ok=False)
            assert result.returncode and "append-only" in result.stderr
        self.cli("migration", "apply", "/migrations")
        assert new == self.query("jsonb_object_agg(filename, checksum_sha256) FROM catalog.migrations")
        print("PASS: forward migrations, legacy event compatibility, append-only and canonical event guard", flush=True)

    def fixtures(self):
        self.sql((ROOT / "src/Tests/workflow_probe.sql").read_text(encoding="utf-8"))
        for action, value_type, policy in (("nullable", ["string", "null"], "workflow:execute"),
                                         ("strict", "string", "payment:internal"),
                                         ("context", "string", "workflow:execute"),
                                         ("forbidden", "string", "ungranted:scope")):
            manifest = {"contract_version": "course-1", "module": "regression", "action": action,
                        "version": 1, "http_method": "POST", "target_schema": "regression",
                        "target_function": "execute", "request_schema": {"$schema": SCHEMA,
                        "type": "object", "required": ["value"], "properties": {"value": {"type": value_type}},
                        "additionalProperties": False}, "response_schema": {"$schema": SCHEMA, "type": "object"},
                        "outcomes": ["DONE"], "required_policy": [policy], "idempotency_mode": "none",
                        "idempotency_scope": "none", "timeout_ms": 2000, "enabled": True, "is_default": True}
            if action == "context":
                manifest["request_schema"]["properties"].update({key: {"type": "string"} for key in
                    ("processId", "jobId", "executionId", "attemptId")})
                manifest["request_schema"]["properties"]["leaseVersion"] = {"type": "integer"}
            self.cli("action", "publish", document=manifest)
        for action in ("nullable", "strict"):
            self.publish(flow_map(action))
        context_flow = flow_map("context")
        context_flow["steps"][0]["task"]["input_constants"] = {
            **{key: "forged" for key in ("processId", "jobId", "executionId", "attemptId")}, "leaseVersion": -1}
        self.publish(context_flow)

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
        assert reclaimed["leaseVersion"] > original["leaseVersion"]
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

    def expired_completion(self):
        for action in ("finish", "fail", "locked-finish"):
            pid = self.start("regression-nullable", "expired-" + action, {"source": "ok"})
            job = self.query("workflow.claim_jobs('expiry-owner',1,2)", "workflow_worker")[0]
            before = self.snapshot(pid)
            if action == "finish":
                result = self.finish(job, "expiry-owner", wait_for_expiry=True)
            elif action == "fail":
                result = self.sql(f"""BEGIN;
                    DO $$ BEGIN ASSERT (SELECT lease_until > now() FROM workflow.jobs WHERE job_id={literal(job['jobId'])}),
                        'test transaction must begin before lease expiry'; END $$;
                    SELECT pg_sleep(greatest(0,extract(epoch FROM lease_until-clock_timestamp()))+0.05)
                    FROM workflow.jobs WHERE job_id={literal(job['jobId'])};
                    SET LOCAL ROLE workflow_worker;
                    SELECT workflow.fail_job({literal(job['jobId'])},'expiry-owner',{job['leaseVersion']},'test.retryable',true);
                    COMMIT;""", ok=False)
            else:
                with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                    holder = pool.submit(self.sql, f"""BEGIN; SET application_name='expiry-blocker';
                        SELECT 1 FROM workflow.jobs WHERE job_id={literal(job['jobId'])} FOR UPDATE;
                        SELECT pg_sleep(3); COMMIT;""")
                    wait_for(lambda: self.query("to_jsonb(EXISTS(SELECT 1 FROM pg_stat_activity "
                        "WHERE application_name='expiry-blocker' AND wait_event='PgSleep'))"), bool)
                    result = self.finish(job, "expiry-owner", check_live_lease=True)
                    holder.result(timeout=10)
            assert result.returncode and "workflow.lease_stale" in result.stderr, f"Expired {action} accepted: {result.stdout}"
            assert self.snapshot(pid) == before, "Expiry rejection must preserve jobs, steps, attempts, events and effects"
            replacement = self.claim("replacement")[0]
            assert replacement["executionId"] == job["executionId"]
            assert replacement["leaseVersion"] > job["leaseVersion"]
            assert self.finish(replacement, "replacement").returncode == 0
            after = self.snapshot(pid)
            assert after["effects"] == 1 and after["process"] == "COMPLETED"
        pid = self.start("regression-nullable", "null-fencing", {"source": "ok"})
        job = self.claim("valid-owner")[0]
        before = self.snapshot(pid)
        for owner, version in (("NULL", str(job["leaseVersion"])), ("'valid-owner'", "NULL")):
            for action, arguments in (("finish", "'DONE','{}'"), ("fail", "'test.retryable',true")):
                result = self.sql(f"SET ROLE workflow_worker; SELECT workflow.{action}_job("
                    f"{literal(job['jobId'])},{owner},{version},{arguments});", ok=False)
                assert result.returncode and "workflow.lease_stale" in result.stderr
                assert self.snapshot(pid) == before
        assert self.finish(job, "valid-owner").returncode == 0
        print("PASS: expiry before reclaim and after lock wait rejects finish/fail; rollback, recovery and NULL fencing", flush=True)

    def outbox_retry_policy(self):
        # No dispatcher/worker runs here. Check delays against wall-clock bounds;
        # a transaction-start timestamp would hide skipped backoff in a long transaction.
        self.sql("""BEGIN;
            SET LOCAL plpgsql.check_asserts = on;
            SET LOCAL course.outbox_jitter_max_ms = 0;
            DO $$
            DECLARE
                scenario text;
                oid uuid;
                pid uuid;
                external_id text;
                claimed record;
                current_row delivery.outbox%ROWTYPE;
                before_row jsonb;
                result jsonb;
                attempt integer;
                failure_started timestamptz;
                failure_finished timestamptz;
            BEGIN
                FOREACH scenario IN ARRAY ARRAY['exhausted','success','terminal','confirmed'] LOOP
                    oid := gen_random_uuid();
                    pid := gen_random_uuid();
                    external_id := gen_random_uuid()::text;
                    INSERT INTO workflow.process_instances(process_id,business_key,flow_name,flow_version)
                        VALUES(pid,external_id,'regression-nullable',1);
                    INSERT INTO payment.operations(operation_id,principal,request_id,operation_kind,amount)
                        VALUES(oid,'regression',external_id,'PAYMENT_EXECUTION',1);
                    INSERT INTO delivery.external_requests(external_request_id,operation_id,process_id,correlation_id,payload_hash)
                        VALUES(external_id,oid,pid,gen_random_uuid(),repeat('0',64));
                    INSERT INTO delivery.outbox(external_request_id) VALUES(external_id);

                    FOR attempt IN 1..4 LOOP
                        SET LOCAL ROLE outbox_dispatcher;
                        SELECT * INTO STRICT claimed FROM delivery.claim_outbox('retry-probe',1);
                        RESET ROLE;
                        ASSERT claimed.external_request_id = external_id, 'claim selected wrong request';
                        SELECT * INTO STRICT current_row FROM delivery.outbox WHERE outbox_id=claimed.outbox_id;
                        ASSERT current_row.attempt_count = attempt AND current_row.state = 'LEASED', 'attempt count';
                        before_row := to_jsonb(current_row);

                        SET LOCAL ROLE outbox_dispatcher;
                        result := delivery.fail_outbox(claimed.outbox_id,'wrong-owner',claimed.lease_version,'test.retryable');
                        ASSERT result = '{"updated":false}'::jsonb, 'wrong owner accepted';
                        result := delivery.fail_outbox(claimed.outbox_id,'retry-probe',claimed.lease_version-1,'test.retryable');
                        ASSERT result = '{"updated":false}'::jsonb, 'stale lease accepted';
                        RESET ROLE;
                        ASSERT (SELECT to_jsonb(o) FROM delivery.outbox o WHERE outbox_id=claimed.outbox_id) = before_row,
                            'rejected failure changed outbox';

                        IF scenario = 'confirmed' THEN
                            -- Simulate the state committed by an early receipt.
                            UPDATE delivery.outbox SET state='CONFIRMED' WHERE outbox_id=claimed.outbox_id;
                        END IF;
                        SET LOCAL ROLE outbox_dispatcher;
                        failure_started := clock_timestamp();
                        IF scenario = 'success' AND attempt = 4 THEN
                            result := delivery.succeed_outbox(claimed.outbox_id,'retry-probe',claimed.lease_version,'provider-id');
                        ELSE
                            result := delivery.fail_outbox(claimed.outbox_id,'retry-probe',claimed.lease_version,
                                CASE WHEN scenario = 'terminal' THEN 'response.invalid.terminal' ELSE 'test.retryable' END);
                        END IF;
                        failure_finished := clock_timestamp();
                        RESET ROLE;
                        ASSERT result->>'updated' = (scenario <> 'confirmed')::text, 'unexpected update result';
                        SELECT * INTO STRICT current_row FROM delivery.outbox WHERE outbox_id=claimed.outbox_id;
                        ASSERT current_row.attempt_count = attempt, 'failure changed attempt count';

                        IF scenario IN ('terminal','confirmed') OR attempt = 4 THEN
                            ASSERT current_row.state = CASE scenario WHEN 'success' THEN 'DELIVERED'
                                WHEN 'confirmed' THEN 'CONFIRMED' ELSE 'DEAD' END, 'final state';
                            before_row := to_jsonb(current_row);
                            SET LOCAL ROLE outbox_dispatcher;
                            result := delivery.fail_outbox(claimed.outbox_id,'retry-probe',claimed.lease_version,'test.retryable');
                            ASSERT result = '{"updated":false}'::jsonb, 'final state accepted failure';
                            RESET ROLE;
                            ASSERT (SELECT to_jsonb(o) FROM delivery.outbox o WHERE outbox_id=claimed.outbox_id) = before_row,
                                'final row changed';
                            UPDATE delivery.outbox SET next_attempt_at=now()-interval '1 second' WHERE outbox_id=claimed.outbox_id;
                            SET LOCAL ROLE outbox_dispatcher;
                            ASSERT NOT EXISTS (SELECT 1 FROM delivery.claim_outbox('retry-probe',1)), 'final state reclaimed';
                            RESET ROLE;
                            EXIT;
                        END IF;

                        ASSERT current_row.state = 'RETRY_WAIT', 'retry stopped before fourth attempt';
                        ASSERT current_row.next_attempt_at BETWEEN
                            failure_started + make_interval(secs=>(ARRAY[0.2,0.4,0.8])[attempt]) AND
                            failure_finished + make_interval(secs=>(ARRAY[0.2,0.4,0.8])[attempt]),
                            'incorrect retry delay';
                        SET LOCAL ROLE outbox_dispatcher;
                        ASSERT NOT EXISTS (SELECT 1 FROM delivery.claim_outbox('retry-probe',1)), 'retry claimed too early';
                        RESET ROLE;
                        UPDATE delivery.outbox SET next_attempt_at=now()-interval '1 second' WHERE outbox_id=claimed.outbox_id;
                    END LOOP;
                END LOOP;
            END;
            $$;
            ROLLBACK;""")
        print("PASS: Outbox four attempts, exact 200/400/800 ms delays, exhaustion, success, terminal errors and fencing", flush=True)

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
        pending_logs = self.run(["docker", "logs", worker]).stdout
        assert '"event":"worker.invoke"' in pending_logs
        assert '"event":"worker.finish"' not in pending_logs, "No success log before commit"
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
        context = self.query(f"context FROM regression.effects WHERE process_id={literal(pid)}")
        assert context["leaseVersion"] == after["jobs"][0]["lease_version"]
        assert context["attemptId"] == after["attempts"][-1]["attempt_id"]
        print("PASS: crash after action rolls back effect; reclaim completes exactly once", flush=True)

    def telemetry_and_context(self):
        cases = [("context", "sensitive-payload-value", "COMPLETED", 1),
                 ("strict", "retry-once", "COMPLETED", 2),
                 ("strict", "raise-error", "FAILED", 3),
                 ("strict", "null-result", "FAILED", 1)]
        processes = [(self.start("regression-" + action, "logs-" + value, {"source": value}), final, attempts)
                     for action, value, final, attempts in cases]
        worker = self.worker()
        try:
            for pid, final, attempt_count in processes:
                state = wait_for(lambda: self.snapshot(pid), lambda s: s["process"] == final)
                assert len(state["attempts"]) == attempt_count
                assert state["effects"] == (1 if final == "COMPLETED" else 0)
                if final == "COMPLETED":
                    context = self.query(f"context FROM regression.effects WHERE process_id={literal(pid)}")
                    assert context["processId"] == pid
                    assert context["jobId"] == state["jobs"][0]["job_id"]
                    assert context["executionId"] == state["jobs"][0]["execution_id"]
                    assert context["attemptId"] == state["attempts"][-1]["attempt_id"]
                    assert type(context["leaseVersion"]) is int
                    assert context["leaseVersion"] == state["attempts"][-1]["lease_version"]
                logs = wait_for(lambda: self.run(["docker", "logs", worker]).stdout,
                                lambda log: any(e.get("processId") == pid and
                                                e.get("event") in ("worker.finish", "worker.fail") and
                                                e.get("attemptId") == state["attempts"][-1]["attempt_id"]
                                                for e in map(json.loads, log.splitlines())))
                assert "sensitive-payload-value" not in logs and "sensitive-regression-message" not in logs
                events = [e for e in map(json.loads, logs.splitlines()) if e.get("processId") == pid]
                for attempt in state["attempts"]:
                    chain = [e for e in events if e["attemptId"] == attempt["attempt_id"]]
                    for event in chain:
                        assert event["jobId"] == state["jobs"][0]["job_id"]
                        assert event["executionId"] == attempt["execution_id"]
                        assert event["leaseVersion"] == attempt["lease_version"]
                        assert event["instanceId"] == "worker-a" and event["timestamp"]
                    names = [e["event"] for e in chain]
                    if attempt["status"] == "SUCCEEDED":
                        assert names == ["worker.claim", "worker.invoke", "worker.finish"], names
                    elif attempt != state["attempts"][-1]:
                        assert names == ["worker.claim", "worker.invoke", "worker.fail", "worker.retry"], names
                    else:
                        assert names == ["worker.claim", "worker.invoke", "worker.fail"], names
            null_state = self.snapshot(processes[-1][0])
            assert null_state["attempts"][0]["error_code"] == "action.contract_violation"
        finally:
            self.stop_worker(worker)
        print("PASS: real worker context, payload spoof rejection, correlated retry/failure logs and safe errors", flush=True)

    def payment_events(self):
        # A rolled-back submit must leave neither process nor event nor operation transition.
        oid = self.operation()
        context = {"principal": "regression-client", "consumer": "regression", "scopes": ["payment:write"],
                   "correlationId": str(uuid.uuid4()), "requestId": "rollback-submit"}
        self.sql(f"""BEGIN; SET LOCAL ROLE course_runtime;
            SELECT api.invoke('payment','submit',1,{literal(context)}::jsonb,
                              {literal({'operationId': oid})}::jsonb); ROLLBACK;""")
        assert self.query(f"to_jsonb(status='CREATED' AND process_id IS NULL) FROM payment.operations WHERE operation_id={literal(oid)}")
        assert self.event_types(oid) == ["OPERATION_CREATED"]
        assert self.query(f"count(*) FROM workflow.process_instances WHERE business_key={literal(oid)}") == 0

        worker = self.worker()
        try:
            for kind, decision, distinct in (("PAYMENT_APPROVAL", "APPROVED", False),
                                             ("PAYMENT_APPROVAL", "REJECTED", True),
                                             ("PAYMENT_APPROVAL", None, False),
                                             ("PAYMENT_EXECUTION", "COMPLETED", False),
                                             ("PAYMENT_EXECUTION", "REJECTED", False)):
                oid = self.operation(kind, "1000.00" if decision is None else "100000.01")
                shared_key = uuid.uuid4().hex
                keys = [uuid.uuid4().hex if distinct else shared_key for _ in range(20)]
                with concurrent.futures.ThreadPoolExecutor(max_workers=20) as pool:
                    responses = list(pool.map(lambda key: self.invoke("payment", "submit", {"operationId": oid}, key), keys))
                assert all(r["status"] == "ok" for r in responses), responses
                pid = responses[0]["result"]["processId"]
                assert all(r["result"] == responses[0]["result"] for r in responses)
                assert self.query(f"count(*) FROM workflow.process_instances WHERE business_key={literal(oid)}") == 1
                if kind == "PAYMENT_EXECUTION":
                    wait_for(lambda: self.snapshot(pid), lambda s: s["process"] == "WAITING_SIGNAL")
                    external = self.query(f"to_jsonb(external_request_id) FROM delivery.external_requests WHERE operation_id={literal(oid)}")
                    message_id = uuid.uuid4().hex
                    receipt = {"version": 1, "messageId": message_id, "externalRequestId": external,
                               "providerPaymentId": message_id, "outcome": decision, "occurredAt": "2026-01-01T00:00:00Z"}
                    # Trusted SQL fixture: HMAC/adapter transport is exercised by the official checker.
                    body_hash = hashlib.sha256(json.dumps(receipt, sort_keys=True).encode()).hexdigest()
                    response = self.invoke("receipt", "accept", receipt, extra={"payloadHash": body_hash,
                                            "transport": {"signatureVerified": True, "signatureVersion": 1}})
                    assert response["status"] == "ok", response
                    assert self.query("delivery.reconcile_inbox(10)", "inbox_reconciler") == 1
                elif decision is not None:
                    wait_for(lambda: self.snapshot(pid), lambda s: s["process"] == "WAITING_MANUAL")
                    sid = self.query(f"to_jsonb(step_instance_id) FROM workflow.step_instances WHERE process_id={literal(pid)} AND step_type='MANUAL'")
                    response = self.invoke("workflow", "manual", {"processId": pid, "stepInstanceId": sid,
                                           "decision": decision, "reason": "regression"}, principal="reviewer")
                    assert response["status"] == "ok", response
                wait_for(lambda: self.snapshot(pid), lambda s: s["process"] == "COMPLETED")
                final = "REJECTED" if decision == "REJECTED" else "COMPLETED"
                assert self.query(f"to_jsonb(status) FROM payment.operations WHERE operation_id={literal(oid)}") == final
                expected = ["OPERATION_CREATED", "OPERATION_SUBMITTED", "OPERATION_" + final]
                assert self.event_types(oid) == expected
                assert self.event_types(oid, "payment.operation_events") == expected
                read = self.invoke("operation", "events", {"operationId": oid})
                assert [e["eventType"] for e in read["result"]["events"]] == expected
                repeat = self.invoke("payment", "submit", {"operationId": oid})
                assert repeat["result"] == responses[0]["result"] and self.event_types(oid) == expected
        finally:
            self.stop_worker(worker)
        print("PASS: concurrent submit, atomic rollback and canonical events for receipt/auto/manual finals", flush=True)

    def outbox_metrics_index(self):
        # Real production query, mostly terminal history; all fixture DDL/DML rolls back.
        evidence = json.loads(self.sql("""BEGIN;
            SET LOCAL plpgsql.check_asserts = on;
            CREATE TEMP TABLE metric_evidence(value jsonb);
            DO $$
            DECLARE pid uuid; baseline bigint; fast jsonb; slow jsonb; before jsonb; after jsonb;
            BEGIN
                SELECT outbox_pending INTO baseline FROM autocheck.metrics;
                INSERT INTO workflow.process_instances(business_key,flow_name,flow_version)
                VALUES ('metrics-index-fixture','payment-processing',1) RETURNING process_id INTO pid;
                CREATE TEMP TABLE metric_ids AS SELECT gen_random_uuid() AS id,n FROM generate_series(1,20063) n;
                INSERT INTO payment.operations(operation_id,principal,request_id,operation_kind,amount,currency,process_id)
                SELECT id,'metrics-index-fixture',id::text,'PAYMENT_EXECUTION',1,'RUB',pid FROM metric_ids;
                INSERT INTO delivery.external_requests(external_request_id,operation_id,process_id,correlation_id,payload_hash)
                SELECT id::text,id,pid,gen_random_uuid(),repeat('0',64) FROM metric_ids;
                INSERT INTO delivery.outbox(external_request_id,state,created_at,next_attempt_at)
                SELECT id::text,CASE WHEN n<=20000 THEN 'CONFIRMED' WHEN n=20001 THEN 'DEAD'
                    WHEN n=20002 THEN 'DELIVERED' ELSE (ARRAY['PENDING','LEASED','RETRY_WAIT'])[n%3+1] END,
                    now()-interval '1 hour',now()+interval '1 hour' FROM metric_ids;
                ANALYZE delivery.outbox;
                SELECT jsonb_build_array(outbox_pending,outbox_oldest_age_seconds) INTO before FROM autocheck.metrics;
                ASSERT (before->>0)::bigint=baseline+61, 'Outbox metric must include all active states, including future retry';
                ASSERT (before->>1)::numeric>=3600, 'Oldest pending age must use created_at';
                EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
                    SELECT outbox_pending,outbox_oldest_age_seconds FROM autocheck.metrics' INTO fast;
                DROP INDEX delivery.outbox_pending_created_at_idx;
                EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
                    SELECT outbox_pending,outbox_oldest_age_seconds FROM autocheck.metrics' INTO slow;
                SELECT jsonb_build_array(outbox_pending,outbox_oldest_age_seconds) INTO after FROM autocheck.metrics;
                ASSERT before=after, 'Index must not change metric values';
                INSERT INTO metric_evidence VALUES(jsonb_build_object('indexed',fast->0,'unindexed',slow->0));
            END $$;
            SELECT value FROM metric_evidence;
            ROLLBACK;""").stdout)
        plans = {k: v["Plan"] for k, v in evidence.items()}
        assert "outbox_pending_created_at_idx" in json.dumps(plans["indexed"]), plans["indexed"]
        blocks = {k: v["Shared Hit Blocks"] + v["Shared Read Blocks"] for k, v in plans.items()}
        assert blocks["indexed"] < blocks["unindexed"], blocks
        print(f"PASS: unchanged Outbox metrics; query buffers indexed={blocks['indexed']}, unindexed={blocks['unindexed']}", flush=True)

    def delivery_recovery_trace(self):
        oid = self.operation("PAYMENT_EXECUTION", "100.00")
        response = self.invoke("payment", "submit", {"operationId": oid})
        pid = response["result"]["processId"]
        worker = self.worker()
        try:
            wait_for(lambda: self.snapshot(pid), lambda s: s["process"] == "WAITING_SIGNAL")
        finally:
            self.stop_worker(worker)
        external = self.query(f"to_jsonb(external_request_id) FROM delivery.external_requests WHERE operation_id={literal(oid)}")

        def claim(owner):
            return self.query(f"COALESCE(jsonb_agg(to_jsonb(c)),'[]') FROM delivery.claim_outbox({literal(owner)},1) c", "outbox_dispatcher")

        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            claims = list(pool.map(claim, ("first", "second")))
        assert sorted(map(len, claims)) == [0, 1], claims
        first = next(c[0] for c in claims if c)
        owner = "first" if claims[0] else "second"
        outbox_id = literal(first["outbox_id"])
        before_expiry = self.query(f"to_jsonb(o) FROM delivery.outbox o WHERE outbox_id={outbox_id}")
        self.sql(f"""BEGIN;
            DO $$ BEGIN ASSERT (SELECT lease_until > now() FROM delivery.outbox WHERE outbox_id={outbox_id}),
                'test transaction must begin before Outbox lease expiry'; END $$;
            SELECT pg_sleep(greatest(0,extract(epoch FROM lease_until-clock_timestamp()))+0.05)
            FROM delivery.outbox WHERE outbox_id={outbox_id};
            SET LOCAL ROLE outbox_dispatcher;
            DO $$ BEGIN
                ASSERT delivery.succeed_outbox({outbox_id},{literal(owner)},{first['lease_version']},'expired') = '{{"updated":false}}'::jsonb;
                ASSERT delivery.fail_outbox({outbox_id},{literal(owner)},{first['lease_version']},'test.retryable') = '{{"updated":false}}'::jsonb;
            END $$;
            COMMIT;""")
        assert self.query(f"to_jsonb(o) FROM delivery.outbox o WHERE outbox_id={outbox_id}") == before_expiry
        reclaimed = wait_for(lambda: claim("replacement"), bool, timeout=15)[0]
        assert reclaimed["outbox_id"] == first["outbox_id"]
        assert reclaimed["lease_version"] > first["lease_version"]
        outbox_id = literal(first["outbox_id"])
        stale = self.query(f"delivery.fail_outbox({outbox_id},{literal(owner)},{first['lease_version']},'test.retryable')", "outbox_dispatcher")
        assert stale == {"updated": False}
        for attempt in (2, 3, 4):
            result = self.query(f"delivery.fail_outbox({outbox_id},'replacement',{reclaimed['lease_version']},'test.retryable')", "outbox_dispatcher")
            assert result["updated"] and result["attemptCount"] == attempt, result
            assert result["state"] == ("DEAD" if attempt == 4 else "RETRY_WAIT"), result
            if attempt < 4:
                reclaimed = wait_for(lambda: claim("replacement"), bool)[0]
        dead = self.query(f"to_jsonb(o) FROM delivery.outbox o WHERE outbox_id={outbox_id}")
        assert dead["dead_at"] and dead["last_error_code"] == "test.retryable"
        assert self.snapshot(pid)["process"] == "WAITING_SIGNAL"
        assert self.query(f"to_jsonb(status) FROM payment.operations WHERE operation_id={literal(oid)}") == "PROCESSING"
        stalled = self.invoke("diagnostics", "stalled", {})
        assert {"operationId": oid, "processId": pid, "externalRequestId": external} not in stalled["result"]["items"]
        # A single statement freezes the observation time; roll back synthetic timestamps.
        self.sql(f"""BEGIN; DO $$
            DECLARE offset_us integer; items jsonb;
            BEGIN
                FOREACH offset_us IN ARRAY ARRAY[-1,0,1] LOOP
                    UPDATE delivery.outbox SET dead_at=statement_timestamp()-interval '10 seconds'
                        + offset_us*interval '1 microsecond' WHERE outbox_id={outbox_id};
                    items := diagnostics.stalled_v1('{{}}','{{}}')#>'{{result,items}}';
                    ASSERT (items @> jsonb_build_array(jsonb_build_object('operationId',{literal(oid)}))) = (offset_us<=0),
                        'stalled age boundary must include exactly 10 seconds';
                END LOOP;
            END $$; ROLLBACK;""")
        assert self.query(f"to_jsonb(o) FROM delivery.outbox o WHERE outbox_id={outbox_id}") == dead

        message_id = uuid.uuid4().hex
        receipt = {"version": 1, "messageId": message_id, "externalRequestId": external,
                   "providerPaymentId": message_id, "outcome": "COMPLETED", "occurredAt": "2026-01-01T00:00:00Z"}
        extra = {"payloadHash": hashlib.sha256(json.dumps(receipt).encode()).hexdigest(),
                 "transport": {"signatureVerified": True, "signatureVersion": 1}}
        accepted = self.invoke("receipt", "accept", receipt, key=message_id, extra=extra)
        assert accepted["status"] == "ok", accepted
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            counts = list(pool.map(lambda _: self.query("delivery.reconcile_inbox(10)", "inbox_reconciler"), range(2)))
        assert sum(counts) == 1, counts
        worker = self.worker()
        try:
            state = wait_for(lambda: self.snapshot(pid), lambda s: s["process"] == "COMPLETED")
        finally:
            self.stop_worker(worker)
        confirmed = self.query(f"to_jsonb(o) FROM delivery.outbox o WHERE outbox_id={outbox_id}")
        assert confirmed["state"] == "CONFIRMED"
        assert all(confirmed[k] == dead[k] for k in ("dead_at", "last_error_code", "attempt_count"))
        assert self.invoke("receipt", "accept", receipt, key=message_id, extra=extra)["status"] == "ok"
        assert not self.invoke("diagnostics", "stalled", {})["result"]["items"]
        trace = self.invoke("diagnostics", "trace", {"identifier": oid})["result"]
        identifiers = {"operationId": oid, "processId": pid, "externalRequestId": external, "messageId": message_id,
                       "requestId": trace["operation"]["requestId"], "correlationId": trace["dispatches"][0]["correlationId"],
                       "stepInstanceId": trace["steps"][0]["stepInstanceId"], "jobId": trace["jobs"][0]["jobId"],
                       "executionId": trace["jobs"][0]["executionId"], "attemptId": trace["attempts"][0]["attemptId"]}
        facts = {k: v for k, v in trace.items() if k != "query"}
        for kind, identifier in identifiers.items():
            actual = self.invoke("diagnostics", "trace", {"identifier": identifier})["result"]
            assert kind in actual["query"]["matchedBy"], (kind, actual["query"])
            assert {k: v for k, v in actual.items() if k != "query"} == facts, kind
        decision_id = self.query("to_jsonb(decision_id) FROM delivery.decisions ORDER BY created_at DESC LIMIT 1")
        decision_trace = self.invoke("diagnostics", "trace", {"identifier": decision_id})["result"]
        assert decision_trace["query"]["matchedBy"] == ["decisionId"]
        assert any(d["decisionId"] == decision_id for d in decision_trace["decisions"])
        assert self.invoke("diagnostics", "trace", {"identifier": "unknown-"+uuid.uuid4().hex})["code"] == "diagnostics.trace_not_found"
        print("PASS: concurrent delivery/reconciliation, expiry, DEAD, late receipt, retained diagnostics and all 11 trace identifiers", flush=True)

    def close(self):
        for name in self.workers:
            self.run(["docker", "rm", "-f", name], ok=False)
        self.run(self.compose + ["down", "--volumes", "--remove-orphans"], timeout=120)


def flow_map(action):
    policy = {"nullable": "workflow:execute", "context": "workflow:execute", "strict": "payment:internal", "forbidden": "ungranted:scope"}[action]
    return {"contract_version": "course-1", "flow_name": "regression-" + action, "version": 1,
            "start_step": "work", "steps": [{"key": "work", "type": "automatic", "task": {
                "service": "postgres", "module": "regression", "action": action, "action_version": 1,
                "required_policy": [policy], "timeout_ms": 2000, "retry": {"max_attempts": 3, "delays_ms": [2000, 4000]},
                "input_constants": {}, "input_mapping": {"/value": "/source"}}},
                {"key": "end", "type": "end", "outcome": "DONE"}],
            "transitions": [{"from": "work", "outcome": "DONE", "to": "end"}]}


if __name__ == "__main__":
    # Workspace paths are shared reliably by Docker Desktop across Windows/WSL.
    with tempfile.TemporaryDirectory(prefix=".regression-", dir=ROOT / "scripts") as temporary:
        suite = Regression(Path(temporary))
        try:
            for test in (suite.upgrade, suite.fixtures, suite.immutability,
                         suite.competing_claims_and_fencing, suite.expired_completion, suite.retry_budget, suite.outbox_retry_policy,
                         suite.signals, suite.mapping_and_policy, suite.crash_recovery,
                         suite.telemetry_and_context, suite.payment_events, suite.delivery_recovery_trace,
                         suite.outbox_metrics_index):
                test()
            print("All workflow DB regressions passed.", flush=True)
        finally:
            suite.close()
