"""Timed builds and one Compose up per empty volume, including CPU/RAM limits."""
import argparse
import concurrent.futures
from datetime import datetime, timezone
import json
from pathlib import Path
import tempfile
import time

from reliability_regression import Reliability
from workflow_regression import ROOT, literal, wait_for


def resource_evidence(suite, container, cpus, memory_mb):
    info = json.loads(suite.run(["docker", "inspect", container]).stdout)[0]
    host = info["HostConfig"]
    actual_cpus = host["NanoCpus"] / 1e9 if host["NanoCpus"] else host["CpuQuota"] / host["CpuPeriod"]
    assert actual_cpus == cpus and host["Memory"] == memory_mb * 1024**2, host
    assert not info["State"]["OOMKilled"], "Container was killed by the memory limit"
    # Docker Desktop and current Linux CI use cgroup v2; limits are also checked above.
    stats = suite.run(["docker", "exec", container, "cat", "/sys/fs/cgroup/cpu.stat"], ok=False)
    counters = dict(line.split() for line in stats.stdout.splitlines()) if stats.returncode == 0 else {}
    return {"cpus": actual_cpus, "memoryMiB": memory_mb,
            "throttledPeriods": int(counters["nr_throttled"]) if "nr_throttled" in counters else None}


def first_up(delay=0, broken=False, cpus=None, memory_mb=None, limited_build=False):
    with tempfile.TemporaryDirectory(prefix=".regression-", dir=ROOT / "scripts") as directory:
        suite = Reliability(Path(directory))
        builder = None
        builder_evidence = None
        build_seconds = None
        if cpus is not None:
            path = Path(directory) / "compose.json"
            override = json.loads(path.read_text())
            services = suite.run(suite.compose + ["config", "--services"]).stdout.splitlines()
            for service in services:
                override["services"].setdefault(service, {})["deploy"] = {
                    "resources": {"limits": {"cpus": str(cpus), "memory": f"{memory_mb}M"}}}
            path.write_text(json.dumps(override), encoding="utf-8")
        # Use every real migration, rather than the old-schema upgrade fixture.
        for source in (ROOT / "migrations").glob("*.sql"):
            (Path(directory) / "init" / source.name).write_text(
                source.read_text(encoding="utf-8"), encoding="utf-8", newline="\n")
        if delay:
            (Path(directory) / "init/000_delay.sh").write_text(f"sleep {delay}\n", encoding="utf-8", newline="\n")
        if broken:
            (Path(directory) / "init/998_invalid.sql").write_text(
                "DO $$ BEGIN RAISE EXCEPTION 'startup-regression-migration-failure'; END $$;\n", encoding="utf-8")
        tcp_ready = None
        tcp_observed_at = None
        print(json.dumps({"test": "first-up-start", "delaySeconds": delay, "brokenMigration": broken,
            "runtimeCpuLimitPerContainer": cpus, "runtimeMemoryMiBPerContainer": memory_mb,
            "limitedColdBuild": limited_build}), flush=True)
        try:
            build_command = suite.compose + ["build"]
            if limited_build:
                # Service limits do not constrain BuildKit. Use a private builder without changing the default.
                builder = suite.project + "-builder"
                config = Path(directory) / "buildkitd.toml"
                config.write_text('[worker.oci]\n  max-parallelism = 2\n', encoding="utf-8")
                setup_started = time.monotonic()
                suite.run(["docker", "buildx", "create", "--name", builder, "--driver", "docker-container",
                    "--driver-opt", "cpu-period=100000,cpu-quota=100000,memory=2g,memory-swap=2g,default-load=true",
                    "--buildkitd-config", str(config), "--bootstrap"], timeout=300)
                builder_evidence = resource_evidence(suite, "buildx_buildkit_" + builder + "0", 1, 2048)
                builder_evidence["setupSeconds"] = round(time.monotonic() - setup_started, 2)
                build_command += ["--builder", builder, "--pull", "--no-cache"]
            build_started = time.monotonic()
            suite.run(build_command, timeout=1800)
            build_seconds = round(time.monotonic() - build_started, 2)
            if builder:
                builder_evidence.update(resource_evidence(suite, "buildx_buildkit_" + builder + "0", 1, 2048))
            print(json.dumps({"test": "build", "seconds": build_seconds, "budgetSeconds": 1800,
                "cold": limited_build, "builderResources": builder_evidence}), flush=True)
            started = time.monotonic()
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                # Do not retry up: a second call would hide the original startup defect.
                launch = pool.submit(suite.run, suite.compose + ["up", "-d", "--no-build"], ok=False, timeout=600)
                while not launch.done():
                    probe = suite.run(suite.compose + ["exec", "-T", "postgres", "pg_isready",
                        "-h", "127.0.0.1", "-U", "postgres", "-d", "course"], ok=False)
                    if probe.returncode == 0:
                        tcp_ready = time.monotonic()
                        tcp_observed_at = datetime.now(timezone.utc)
                        break
                    time.sleep(1)
                result = launch.result(timeout=600)
            up_seconds = round(time.monotonic() - started, 2)
            pg_id = suite.run(suite.compose + ["ps", "-a", "-q", "postgres"]).stdout.strip()
            pg_state = json.loads(suite.run(["docker", "inspect", "--format", "{{json .State}}", pg_id]).stdout)
            if broken:
                logs = suite.run(suite.compose + ["logs", "postgres"]).stdout
                assert result.returncode != 0 and pg_state["ExitCode"] != 0, result.stdout + result.stderr
                assert "startup-regression-migration-failure" in logs, logs[-3000:]
                assert tcp_ready is None, "Failed initialization must never become TCP-ready"
                print(json.dumps({"test": "failed-migration", "expectedFailure": True,
                    "buildSeconds": build_seconds, "upSeconds": up_seconds, "upExitCode": result.returncode,
                    "postgresExitCode": pg_state["ExitCode"], "tcpReady": False}), flush=True)
                return
            assert result.returncode == 0, result.stdout + result.stderr
            assert suite.run(suite.compose + ["exec", "-T", "postgres", "pg_isready", "-h", "127.0.0.1",
                "-U", "postgres", "-d", "course"]).returncode == 0
            tcp_ready = tcp_ready or time.monotonic()
            tcp_observed_at = tcp_observed_at or datetime.now(timezone.utc)
            cli_id = suite.run(suite.compose + ["ps", "-a", "-q", "cli"]).stdout.strip()
            cli_state = wait_for(lambda: json.loads(suite.run(
                ["docker", "inspect", "--format", "{{json .State}}", cli_id]).stdout),
                lambda state: state["Status"] == "exited", timeout=60)
            assert cli_state["ExitCode"] == 0, suite.run(suite.compose + ["logs", "cli"]).stdout
            cli_observed_seconds = round(time.monotonic() - started, 2)
            wait_for(lambda: suite.http("gateway", "/health/ready"), lambda response: response["status"] == 200, timeout=60)
            ready_seconds = round(time.monotonic() - started, 2)
            assert suite.query("count(*) FROM catalog.migrations") == len(list((ROOT / "migrations").glob("*.sql")))
            resources = {}
            payment_seconds = None
            if cpus is not None:
                # Exercise HTTP, the real worker and the provider callback with the original lease/timeout settings.
                for service in services:
                    if service not in ("postgres", "cli", "provider-simulator"):
                        probe = "receipt-adapter" if service in ("gateway", "api", "receipt-adapter") else "outbox-dispatcher"
                        wait_for(lambda: {"service": service, **suite.http(service, "/health/ready", probe_service=probe)},
                            lambda r: r["status"] == 200, timeout=60)
                payment_started = time.monotonic()
                response = suite.http("gateway", "/api/payment/request",
                    {"operationKind": "PAYMENT_EXECUTION", "amount": "1000.00", "currency": "RUB"}, suite.project + "-request")
                assert response["status"] == 200, response
                oid = json.loads(response["body"])["result"]["operationId"]
                response = suite.http("gateway", "/api/payment/submit", {"operationId": oid}, suite.project + "-submit")
                assert response["status"] == 200, response
                wait_for(lambda: suite.http("gateway", "/api/operation/get", {"operationId": oid}),
                    lambda r: r["status"] == 200 and json.loads(r["body"])["result"]["status"] == "COMPLETED", timeout=30)
                payment_seconds = round(time.monotonic() - payment_started, 2)
                assert payment_seconds < 30, f"Payment scenario exceeded 30 seconds: {payment_seconds}"
                assert suite.event_types(oid).count("OPERATION_COMPLETED") == 1
                assert suite.query(f"count(*) FROM delivery.external_requests WHERE operation_id={literal(oid)}") == 1
                for service in services:
                    container = suite.run(suite.compose + ["ps", "-a", "-q", service]).stdout.strip()
                    resources[service] = resource_evidence(suite, container, cpus, memory_mb)
            tcp_age = (tcp_observed_at - datetime.fromisoformat(pg_state["StartedAt"].replace("Z", "+00:00"))).total_seconds()
            print(json.dumps({"test": "first-up", "delaySeconds": delay, "upExitCode": result.returncode,
                "buildSeconds": build_seconds, "limitedColdBuild": limited_build, "builderResources": builder_evidence,
                "upSeconds": up_seconds, "upBudgetSeconds": 600, "cliObservedAfterUpSeconds": cli_observed_seconds,
                "apiReadyObservedAfterUpSeconds": ready_seconds, "runtimeResources": resources,
                "paymentCompletedSeconds": payment_seconds,
                "tcpReadyAfterUpSeconds": round(tcp_ready - started, 2), "tcpReadyAfterContainerStartSeconds": round(tcp_age, 2),
                "cliExitCode": cli_state["ExitCode"], "apiReadiness": 200}), flush=True)
        except Exception:
            print(suite.run(suite.compose + ["logs", "--no-color", "--tail", "30"], ok=False).stdout, flush=True)
            raise
        finally:
            try:
                suite.close()
            finally:
                if builder:
                    suite.run(["docker", "buildx", "rm", "--force", builder], timeout=120)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--limited-build", action="store_true",
        help="also cold-build in a private BuildKit capped at 1 CPU / 2 GiB (requires Buildx)")
    args = parser.parse_args()
    first_up()
    first_up(delay=45)
    first_up(broken=True)
    first_up(cpus=0.5, memory_mb=512)
    first_up(cpus=0.25, memory_mb=256, limited_build=args.limited_build)
    print("All first-start regressions passed.", flush=True)
