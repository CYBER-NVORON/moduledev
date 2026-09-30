"""Week 4 crash-boundary checks in an isolated Compose project (Python stdlib).

Uses real HTTP/JWT/HMAC, SIGKILL and normal recovery loops. No host ports.
Run: python src/Tests/reliability_regression.py
"""
import base64
import concurrent.futures
import hashlib
import hmac
import json
from pathlib import Path
import tempfile
import time
import uuid

from workflow_regression import ROOT, Regression, literal, wait_for


class Reliability(Regression):
    def __init__(self, directory):
        super().__init__(directory)
        self.env.update(COURSE_JWT_ISSUER="regression", COURSE_JWT_AUDIENCE="regression",
                        COURSE_JWT_SIGNING_KEY=uuid.uuid4().hex+uuid.uuid4().hex,
                        PROVIDER_HMAC_SECRET=uuid.uuid4().hex, PROVIDER_CALLBACK_CAPABILITY=uuid.uuid4().hex,
                        PROVIDER_AUDIT_TOKEN=uuid.uuid4().hex, COURSE_AUTOCHECK_PASSWORD=uuid.uuid4().hex)
        self.token = self.jwt(["payment:write", "payment:read", "workflow:manual", "receipt:write", "diagnostics:read"])
        self.env["PROVIDER_CALLBACK_TOKEN"] = self.token
        path = directory / "compose.json"
        override = json.loads(path.read_text())
        for name in ("outbox-dispatcher", "outbox-dispatcher-b", "inbox-reconciler", "inbox-reconciler-b", "receipt-adapter"):
            override["services"][name] = {"image": self.project+"-python"}
        path.write_text(json.dumps(override), encoding="utf-8")

    def jwt(self, scopes):
        def part(value):
            return base64.urlsafe_b64encode(json.dumps(value, separators=(",", ":")).encode()).decode().rstrip("=")
        body = part({"alg": "HS256", "typ": "JWT"})+"."+part({"sub": "crash-reviewer", "consumer": "regression",
            "scope": " ".join(scopes), "iss": "regression", "aud": "regression",
            "iat": int(time.time()), "exp": int(time.time())+3600})
        signature = hmac.new(self.env["COURSE_JWT_SIGNING_KEY"].encode(), body.encode(), hashlib.sha256).digest()
        return body+"."+base64.urlsafe_b64encode(signature).decode().rstrip("=")

    def http(self, service, path, payload=None, key=None, signed=False, probe_service="receipt-adapter"):
        body = None if payload is None else json.dumps(payload, separators=(",", ":"), sort_keys=True)
        headers = {"Authorization": "Bearer "+self.token, "Content-Type": "application/json"}
        if key:
            headers["Idempotency-Key"] = key
        if signed:
            headers["X-Provider-Signature"] = "v1="+hmac.new(self.env["PROVIDER_HMAC_SECRET"].encode(), body.encode(), hashlib.sha256).hexdigest()
        port = 8082 if service == "receipt-adapter" else 8080
        # Public routes use the adapter; internal probes can use an existing Python service on course-net.
        code = """import json,sys,urllib.request,urllib.error
d=json.load(sys.stdin)
request=urllib.request.Request(d['url'],data=None if d['body'] is None else d['body'].encode(),headers=d['headers'])
try:
    with urllib.request.urlopen(request,timeout=20) as response:
        print(json.dumps({'status':response.status,'body':response.read().decode()}))
except urllib.error.HTTPError as error:
    print(json.dumps({'status':error.code,'body':error.read().decode()}))
except (OSError,urllib.error.URLError):
    print(json.dumps({'status':0,'body':''}))
"""
        result = self.run(self.compose+["exec", "-T", probe_service, "python", "-c", code],
                          data=json.dumps({"url": f"http://{service}:{port}{path}", "body": body, "headers": headers}), timeout=30)
        return json.loads(result.stdout)

    def component(self, service, failpoint=""):
        name = self.project+"-"+service+"-"+uuid.uuid4().hex[:6]
        self.run(self.compose+["run", "--rm", "-d", "--no-deps", "--name", name,
                               "-e", "COURSE_FAILPOINT="+failpoint, service])
        self.workers.add(name)
        return name

    def acknowledge(self, name, point):
        def read():
            lines = self.run(["docker", "logs", name]).stdout.splitlines()
            return any(json.loads(line).get("event") == "failpoint.reached" and json.loads(line).get("name") == point
                       for line in lines if line.startswith("{"))
        wait_for(read, bool)

    def setup_http(self):
        self.run(self.compose+["build", "api", "gateway", "outbox-dispatcher"], timeout=900)
        self.run(self.compose+["up", "-d", "--no-deps", "api", "gateway", "receipt-adapter", "provider-simulator"])
        wait_for(lambda: self.http("api", "/health/ready"), lambda r: r["status"] == 200)

    def worker_claim_crash(self):
        pid = self.start("regression-nullable", "claim-crash", {"source": "ok"})
        broken = self.component("worker-a", "after_job_claim")
        self.acknowledge(broken, "after_job_claim")
        before = self.snapshot(pid)
        assert before["effects"] == 0
        self.stop_worker(broken)
        replacement = self.worker()
        try:
            after = wait_for(lambda: self.snapshot(pid), lambda s: s["process"] == "COMPLETED")
            assert after["effects"] == 1
            assert after["jobs"][0]["execution_id"] == before["jobs"][0]["execution_id"]
            assert after["jobs"][0]["lease_version"] > before["jobs"][0]["lease_version"]
        finally:
            self.stop_worker(replacement)
        print("PASS: after_job_claim SIGKILL and automatic reclaim", flush=True)

    def payment(self, kind):
        oid = self.operation(kind)
        pid = self.invoke("payment", "submit", {"operationId": oid})["result"]["processId"]
        expected = "WAITING_SIGNAL" if kind == "PAYMENT_EXECUTION" else "WAITING_MANUAL"
        wait_for(lambda: self.snapshot(pid), lambda s: s["process"] == expected)
        return oid, pid

    def api_crashes(self):
        for point, kind in (("after_inbox_saved", "PAYMENT_EXECUTION"), ("after_manual_decision", "PAYMENT_APPROVAL")):
            oid, pid = self.payment(kind)
            key = uuid.uuid4().hex
            signed = point == "after_inbox_saved"
            if signed:
                external = self.query(f"to_jsonb(external_request_id) FROM delivery.external_requests WHERE operation_id={literal(oid)}")
                path = "/api/receipt/accept"
                payload = {"version": 1, "messageId": key, "externalRequestId": external,
                           "providerPaymentId": key, "outcome": "COMPLETED", "occurredAt": "2026-01-01T00:00:00Z"}
            else:
                sid = self.query(f"to_jsonb(step_instance_id) FROM workflow.step_instances WHERE process_id={literal(pid)} AND step_type='MANUAL'")
                path = "/api/workflow/manual"
                payload = {"processId": pid, "stepInstanceId": sid, "decision": "APPROVED", "reason": "sensitive-crash-reason"}
            api = self.component("api", point)
            wait_for(lambda: self.http(api, "/health/ready"), lambda r: r["status"] == 200)
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                request = pool.submit(self.http, api, path, payload, key, signed)
                try:
                    self.acknowledge(api, point)
                    if signed:
                        assert self.query(f"count(*) FROM delivery.inbox WHERE message_id={literal(key)} AND state='RECEIVED'") == 1
                    else:
                        assert self.query(f"count(*) FROM delivery.decisions WHERE process_id={literal(pid)}") == 0
                finally:
                    self.stop_worker(api)
                request.result(timeout=30)
            retry = self.http("api", path, payload, key, signed)
            assert retry["status"] == 200, retry
            reconciler = self.component("inbox-reconciler") if signed else None
            try:
                wait_for(lambda: self.snapshot(pid), lambda s: s["process"] == "COMPLETED")
                assert self.http("api", path, payload, key, signed)["status"] == 200
                table, condition = ("delivery.receipts", f"message_id={literal(key)}") if signed else ("delivery.decisions", f"process_id={literal(pid)}")
                assert self.query(f"count(*) FROM {table} WHERE {condition}") == 1
            finally:
                if reconciler:
                    self.stop_worker(reconciler)
            print(f"PASS: {point} SIGKILL, HTTP replay and one durable result", flush=True)

    def dispatcher_crashes(self):
        reconciler = self.component("inbox-reconciler")
        try:
            for point in ("after_outbox_claim", "after_provider_response"):
                oid, pid = self.payment("PAYMENT_EXECUTION")
                dispatcher = self.component("outbox-dispatcher", point)
                self.acknowledge(dispatcher, point)
                self.stop_worker(dispatcher)
                replacement = self.component("outbox-dispatcher-b")
                try:
                    wait_for(lambda: self.snapshot(pid), lambda s: s["process"] == "COMPLETED")
                    assert self.event_types(oid) == ["OPERATION_CREATED", "OPERATION_SUBMITTED", "OPERATION_COMPLETED"]
                    assert self.query(f"count(*) FROM delivery.receipts r JOIN delivery.external_requests e USING(external_request_id) WHERE e.operation_id={literal(oid)}") == 1
                finally:
                    self.stop_worker(replacement)
                print(f"PASS: {point} SIGKILL and normal delivery recovery", flush=True)
        finally:
            self.stop_worker(reconciler)

    def provider_outage(self):
        self.run(self.compose+["stop", "provider-simulator"])
        dispatcher = reconciler = None
        try:
            oid, pid = self.payment("PAYMENT_EXECUTION")
            external = self.query(f"to_jsonb(external_request_id) FROM delivery.external_requests WHERE operation_id={literal(oid)}")
            dispatcher = self.component("outbox-dispatcher")
            row = wait_for(lambda: self.query(f"to_jsonb(o) FROM autocheck.outbox o WHERE external_request_id={literal(external)}"),
                           lambda r: r["state"] == "DEAD", timeout=10)
            assert row["attempt_count"] == 4 and row["last_error_code"] == "transport.error.retryable", row
            assert self.snapshot(pid)["process"] == "WAITING_SIGNAL"
            assert self.http("api", "/health/ready")["status"] == 200
            assert self.query(f"to_jsonb(status) FROM payment.operations WHERE operation_id={literal(oid)}") == "PROCESSING"
            key = uuid.uuid4().hex
            receipt = {"version": 1, "messageId": key, "externalRequestId": external,
                       "providerPaymentId": key, "outcome": "COMPLETED", "occurredAt": "2026-01-01T00:00:00Z"}
            assert self.http("api", "/api/receipt/accept", receipt, key, True)["status"] == 200
            reconciler = self.component("inbox-reconciler")
            wait_for(lambda: self.snapshot(pid), lambda s: s["process"] == "COMPLETED")
            confirmed = self.query(f"to_jsonb(o) FROM autocheck.outbox o WHERE external_request_id={literal(external)}")
            assert confirmed["state"] == "CONFIRMED" and confirmed["dead_at"] == row["dead_at"]
            print("PASS: stopped provider DNS/HTTP deadline, four retries, DEAD and late signed receipt", flush=True)
        finally:
            for name in (dispatcher, reconciler):
                if name:
                    self.stop_worker(name)
            self.run(self.compose+["up", "-d", "--no-deps", "provider-simulator"])

    def stalled_age(self):
        self.run(self.compose+["stop", "provider-simulator"])
        dispatcher = self.component("outbox-dispatcher")
        reconciler = None
        operations = []

        def items():
            response = self.http("gateway", "/api/diagnostics/stalled", {})
            assert response["status"] == 200, response
            return json.loads(response["body"])["result"]["items"]

        try:
            for name in ("older", "fresh"):
                key = uuid.uuid4().hex
                response = self.http("gateway", "/api/payment/request",
                    {"operationKind": "PAYMENT_EXECUTION", "amount": "1000.00", "currency": "RUB"}, key)
                assert response["status"] == 200, response
                oid = json.loads(response["body"])["result"]["operationId"]
                response = self.http("gateway", "/api/payment/submit", {"operationId": oid}, uuid.uuid4().hex)
                assert response["status"] == 200, response
                pid = json.loads(response["body"])["result"]["processId"]
                row = wait_for(lambda: self.query(f"COALESCE((SELECT to_jsonb(o) FROM delivery.outbox o JOIN delivery.external_requests e "
                    f"USING(external_request_id) WHERE e.operation_id={literal(oid)}),'null'::jsonb)"),
                    lambda row: row is not None and row["state"] == "DEAD", timeout=20)
                assert row["attempt_count"] == 4
                operations.append((oid, pid, row))
                assert oid not in {item["operationId"] for item in items()}, "Fresh DEAD must not be stalled"
                if name == "older":
                    wait_for(lambda: self.query(f"to_jsonb(clock_timestamp() >= dead_at+interval '10 seconds') "
                        f"FROM delivery.outbox WHERE outbox_id={literal(row['outbox_id'])}"), bool, timeout=40)
            before = {pid: self.snapshot(pid) for _, pid, _ in operations}
            observed = items()
            identifiers = [item["operationId"] for item in observed]
            assert identifiers == sorted(set(identifiers))
            assert operations[0][0] in identifiers and operations[1][0] not in identifiers
            assert {pid: self.snapshot(pid) for _, pid, _ in operations} == before
            for oid, _, row in operations:
                assert self.query(f"to_jsonb(o) FROM delivery.outbox o WHERE outbox_id={literal(row['outbox_id'])}") == row
                assert self.query(f"count(*) FROM delivery.external_requests WHERE operation_id={literal(oid)}") == 1
            self.run(self.compose+["restart", "postgres", "api"], timeout=120)
            wait_for(lambda: self.http("api", "/health/ready"), lambda r: r["status"] == 200, timeout=60)
            assert operations[0][0] in {item["operationId"] for item in items()}, "Persisted age must survive restart"
            assert {pid: self.snapshot(pid) for _, pid, _ in operations} == before
            reconciler = self.component("inbox-reconciler")
            for oid, pid, row in operations:
                key = uuid.uuid4().hex
                receipt = {"version": 1, "messageId": key, "externalRequestId": row["external_request_id"],
                    "providerPaymentId": key, "outcome": "COMPLETED", "occurredAt": "2026-01-01T00:00:00Z"}
                assert self.http("gateway", "/api/receipt/accept", receipt, key, True)["status"] == 200
                wait_for(lambda: self.snapshot(pid), lambda s: s["process"] == "COMPLETED")
                assert oid not in {item["operationId"] for item in items()}
                assert self.event_types(oid).count("OPERATION_COMPLETED") == 1
                assert self.query(f"count(*) FROM delivery.external_requests WHERE operation_id={literal(oid)}") == 1
                confirmed = self.query(f"to_jsonb(o) FROM delivery.outbox o WHERE outbox_id={literal(row['outbox_id'])}")
                assert confirmed["state"] == "CONFIRMED" and confirmed["dead_at"] == row["dead_at"]
            print("PASS: HTTP stalled excludes fresh DEAD, includes 10-second-old DEAD, survives restart and clears on receipt", flush=True)
        finally:
            for name in (dispatcher, reconciler):
                if name:
                    self.stop_worker(name)
            self.run(self.compose+["up", "-d", "--no-deps", "provider-simulator"])


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix=".regression-", dir=ROOT / "scripts") as directory:
        suite = Reliability(Path(directory))
        try:
            suite.upgrade()
            suite.fixtures()
            suite.worker_claim_crash()
            suite.crash_recovery()
            suite.setup_http()
            worker = suite.worker()
            try:
                suite.api_crashes()
                suite.dispatcher_crashes()
                suite.provider_outage()
                suite.stalled_age()
            finally:
                suite.stop_worker(worker)
            print("All six crash boundaries passed.", flush=True)
        finally:
            suite.close()
