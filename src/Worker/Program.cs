using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;
using Json.Schema;
using Npgsql;
using System.Runtime.InteropServices;
using Worker;

var owner = Environment.GetEnvironmentVariable("COURSE_WORKER_OWNER")
    ?? throw new InvalidOperationException("COURSE_WORKER_OWNER not set");
var dbConn = Environment.GetEnvironmentVariable("COURSE_DB_CONNECTION")
    ?? throw new InvalidOperationException("COURSE_DB_CONNECTION not set");
var testProfile = Environment.GetEnvironmentVariable("COURSE_TEST_PROFILE") == "1";
var failpoint = Environment.GetEnvironmentVariable("COURSE_FAILPOINT");

var leaseSec = testProfile ? 2 : 30;
var pollMs = testProfile ? 100 : 1000;

EmitEvent("worker.started", owner);

var cts = new CancellationTokenSource();
Console.CancelKeyPress += (_, e) =>
{
    e.Cancel = true;
    cts.Cancel();
};
AppDomain.CurrentDomain.ProcessExit += (_, _) =>
{
    cts.Cancel();
};
if (OperatingSystem.IsLinux())
{
    PosixSignalRegistration.Create(PosixSignal.SIGTERM, _ => cts.Cancel());
}

while (!cts.Token.IsCancellationRequested)
{
    try
    {
        var claimedJobs = await ClaimJobsAsync(dbConn, owner, 1, leaseSec, cts.Token);

        foreach (var job in claimedJobs)
        {
            EmitEvent("worker.claim", owner, job);
            try
            {
                await ProcessJobAsync(dbConn, owner, job, failpoint, cts.Token);
            }
            catch (OperationCanceledException) when (cts.IsCancellationRequested)
            {
                EmitEvent("worker.interrupted", owner, job);
                throw;
            }
            catch (Exception)
            {
                EmitEvent("worker.abandoned", owner, job, errorCode: "internal.error");
                throw;
            }
        }

        if (claimedJobs.Count == 0)
        {
            await Task.Delay(pollMs, cts.Token);
        }
    }
    catch (OperationCanceledException) when (cts.Token.IsCancellationRequested)
    {
        break;
    }
    catch (Exception)
    {
        EmitEvent("worker.poll_error", owner, errorCode: "internal.error");
        try
        {
            await Task.Delay(pollMs, cts.Token);
        }
        catch (OperationCanceledException)
        {
            break;
        }
    }
}

EmitEvent("worker.stopped", owner);

async Task<List<ClaimedJob>> ClaimJobsAsync(string connStr, string workerOwner, int limit, int leaseSeconds, CancellationToken ct)
{
    var list = new List<ClaimedJob>();
    try
    {
        await using var conn = new NpgsqlConnection(connStr);
        await conn.OpenAsync(ct);

        await using var cmd = new NpgsqlCommand("SELECT workflow.claim_jobs(@owner, @limit, @sec)", conn);
        cmd.Parameters.AddWithValue("owner", workerOwner);
        cmd.Parameters.AddWithValue("limit", limit);
        cmd.Parameters.AddWithValue("sec", leaseSeconds);

        var resultJson = await cmd.ExecuteScalarAsync(ct) as string;
        if (resultJson is null) return list;

        var array = JsonNode.Parse(resultJson)?.AsArray();
        if (array is null) return list;

        foreach (var node in array)
        {
            if (node is not JsonObject obj) continue;

            var jobId = Guid.Parse(obj["jobId"]!.GetValue<string>());
            var processId = Guid.Parse(obj["processId"]!.GetValue<string>());
            var stepInstanceId = Guid.Parse(obj["stepInstanceId"]!.GetValue<string>());
            var executionId = Guid.Parse(obj["executionId"]!.GetValue<string>());
            var attemptId = Guid.Parse(obj["attemptId"]!.GetValue<string>());
            var leaseVersion = obj["leaseVersion"]!.GetValue<long>();
            var stepKey = obj["stepKey"]!.GetValue<string>();
            var service = obj["service"]?.GetValue<string>() ?? "postgres";
            var module = obj["module"]!.GetValue<string>();
            var action = obj["action"]!.GetValue<string>();
            var actionVersion = obj["actionVersion"]!.GetValue<int>();
            var requiredPolicy = obj["requiredPolicy"]?.AsArray()?.Select(x => x?.GetValue<string>()).Where(x => x != null).Select(x => x!).ToList() ?? new();
            var timeoutMs = obj["timeoutMs"]?.GetValue<int>() ?? 5000;
            var inputMapping = obj["inputMapping"]?.AsObject() ?? new();
            var inputConstants = obj["inputConstants"]?.AsObject() ?? new();
            var processData = obj["processData"]?.AsObject() ?? new();
            var expectedOutcomes = obj["expectedOutcomes"]?.AsArray()?.Select(x => x?.GetValue<string>()).Where(x => x != null).Select(x => x!).ToList() ?? new();

            JsonSchema? reqSchema = null;
            if (obj["requestSchema"] is JsonNode reqNode)
            {
                try { reqSchema = JsonSchema.FromText(reqNode.ToJsonString()); } catch { }
            }

            JsonSchema? resSchema = null;
            if (obj["responseSchema"] is JsonNode resNode)
            {
                try { resSchema = JsonSchema.FromText(resNode.ToJsonString()); } catch { }
            }

            list.Add(new ClaimedJob(
                jobId, processId, stepInstanceId, executionId, attemptId,
                leaseVersion, stepKey, service, module, action, actionVersion,
                requiredPolicy, timeoutMs, inputMapping, inputConstants,
                processData, expectedOutcomes, reqSchema, resSchema
            ));
        }
    }
    catch (Exception) when (!ct.IsCancellationRequested)
    {
        EmitEvent("worker.claim_error", workerOwner, errorCode: "internal.error");
    }
    return list;
}

async Task ProcessJobAsync(string connStr, string workerOwner, ClaimedJob job, string? activeFailpoint, CancellationToken ct)
{
    // Failpoint: after_job_claim
    if (activeFailpoint == "after_job_claim")
    {
        EmitFailpoint("after_job_claim", workerOwner);
        await Task.Delay(Timeout.Infinite, ct);
        return;
    }

    // Apply mapping
    var payload = job.InputConstants.DeepClone().AsObject();
    foreach (var (targetPtr, srcPtrNode) in job.InputMapping)
    {
        var srcPtr = srcPtrNode?.GetValue<string>() ?? "";
        var (found, val) = JsonPointer.TryGet(job.ProcessData, srcPtr);
        if (!found)
        {
            await FailJobAsync(connStr, job, workerOwner, "workflow.mapping_missing", false);
            return;
        }
        JsonPointer.Set(payload, targetPtr, val);
    }

    // Validate request schema
    if (job.RequestSchema is not null)
    {
        var reqEval = job.RequestSchema.Evaluate(payload, new EvaluationOptions
        {
            OutputFormat = OutputFormat.List,
            RequireFormatValidation = true
        });
        if (!reqEval.IsValid)
        {
            await FailJobAsync(connStr, job, workerOwner, "payload.invalid", false);
            return;
        }
    }

    // Build trusted server-side context from the service principal's permissions.
    var workerScopes = Course.WorkflowPrincipal.Scopes;
    foreach (var policy in job.RequiredPolicy)
    {
        if (!workerScopes.Contains(policy))
        {
            await FailJobAsync(connStr, job, workerOwner, "workflow.policy_denied", false);
            return;
        }
    }

    var contextNode = new JsonObject
    {
        ["principal"] = "workflow-worker",
        ["consumer"] = "internal",
        ["scopes"] = JsonSerializer.SerializeToNode(workerScopes),
        ["correlationId"] = Guid.NewGuid().ToString(),
        ["requestId"] = job.ExecutionId.ToString(),
        ["processId"] = job.ProcessId.ToString(),
        ["jobId"] = job.JobId.ToString(),
        ["executionId"] = job.ExecutionId.ToString(),
        ["attemptId"] = job.AttemptId.ToString(),
        ["leaseVersion"] = job.LeaseVersion,
        ["deadline"] = DateTime.UtcNow.AddMilliseconds(job.TimeoutMs).ToString("o")
    };

    // Execute in one Npgsql transaction: api.invoke + validation + finish_job
    await using var conn = new NpgsqlConnection(connStr);
    await conn.OpenAsync(ct);
    await using var tx = await conn.BeginTransactionAsync(ct);

    try
    {
        // 1. Set statement timeout
        await using (var toCmd = new NpgsqlCommand("SELECT set_config('statement_timeout', @to, true)", conn, tx))
        {
            toCmd.Parameters.AddWithValue("to", $"{job.TimeoutMs}ms");
            await toCmd.ExecuteNonQueryAsync(ct);
        }

        // 2. Execute api.invoke
        await using var invokeCmd = new NpgsqlCommand(
            "SELECT api.invoke(@mod, @act, @ver, @ctx::jsonb, @pld::jsonb)", conn, tx);
        invokeCmd.CommandTimeout = Math.Max(1, (int)Math.Ceiling(job.TimeoutMs / 1000.0) + 2);
        invokeCmd.Parameters.AddWithValue("mod", job.Module);
        invokeCmd.Parameters.AddWithValue("act", job.Action);
        invokeCmd.Parameters.AddWithValue("ver", job.ActionVersion);
        invokeCmd.Parameters.AddWithValue("ctx", contextNode.ToJsonString());
        invokeCmd.Parameters.AddWithValue("pld", payload.ToJsonString());

        EmitEvent("worker.invoke", workerOwner, job);
        var invokeResultStr = await invokeCmd.ExecuteScalarAsync(ct) as string;
        if (invokeResultStr is null)
        {
            await tx.RollbackAsync(ct);
            await FailJobAsync(connStr, job, workerOwner, "action.contract_violation", false);
            return;
        }

        var resObj = JsonNode.Parse(invokeResultStr)?.AsObject();
        if (resObj is null)
        {
            await tx.RollbackAsync(ct);
            await FailJobAsync(connStr, job, workerOwner, "action.contract_violation", false);
            return;
        }

        var status = resObj["status"]?.GetValue<string>();
        if (status == "error")
        {
            var errCode = resObj["code"]?.GetValue<string>() ?? "internal.error";
            var retryable = resObj["retryable"]?.GetValue<bool>() ?? false;
            await tx.RollbackAsync(ct);
            await FailJobAsync(connStr, job, workerOwner, errCode, retryable);
            return;
        }

        var outcome = resObj["outcome"]?.GetValue<string>();
        if (outcome is null || !job.ExpectedOutcomes.Contains(outcome))
        {
            await tx.RollbackAsync(ct);
            await FailJobAsync(connStr, job, workerOwner, "workflow.unknown_outcome", false);
            return;
        }

        var resultData = resObj["result"];
        if (job.ResponseSchema is not null)
        {
            var resEval = job.ResponseSchema.Evaluate(resultData, new EvaluationOptions
            {
                OutputFormat = OutputFormat.List,
                RequireFormatValidation = true
            });
            if (!resEval.IsValid)
            {
                await tx.RollbackAsync(ct);
                await FailJobAsync(connStr, job, workerOwner, "action.contract_violation", false);
                return;
            }
        }

        // Failpoint: after_action_before_finish
        if (activeFailpoint == "after_action_before_finish")
        {
            EmitFailpoint("after_action_before_finish", workerOwner);
            await Task.Delay(Timeout.Infinite, ct);
            return;
        }

        // 3. Finish job in same transaction
        await using var finishCmd = new NpgsqlCommand(
            "SELECT workflow.finish_job(@jid, @owner, @lv, @outcome, @res::jsonb)", conn, tx);
        finishCmd.Parameters.AddWithValue("jid", job.JobId);
        finishCmd.Parameters.AddWithValue("owner", workerOwner);
        finishCmd.Parameters.AddWithValue("lv", job.LeaseVersion);
        finishCmd.Parameters.AddWithValue("outcome", outcome);
        finishCmd.Parameters.AddWithValue("res", resultData?.ToJsonString() ?? "null");

        await finishCmd.ExecuteNonQueryAsync(ct);

        // Commit both action effect and job completion atomically
        await tx.CommitAsync(ct);
        EmitEvent("worker.finish", workerOwner, job, outcome: outcome, jobState: "SUCCEEDED");
    }
    catch (PostgresException ex) when (ex.MessageText == "workflow.lease_stale")
    {
        try { await tx.RollbackAsync(ct); } catch { }
        EmitEvent("worker.stale", workerOwner, job, errorCode: "workflow.lease_stale");
    }
    catch (Exception ex) when (ex is PostgresException { SqlState: "57014" } || ex.InnerException is TimeoutException || ex is TimeoutException)
    {
        try { await tx.RollbackAsync(ct); } catch { }
        await FailJobAsync(connStr, job, workerOwner, "action.timeout", true);
    }
    catch (OperationCanceledException) when (ct.IsCancellationRequested)
    {
        try { await tx.RollbackAsync(CancellationToken.None); } catch { }
        throw;
    }
    catch (Exception)
    {
        try { await tx.RollbackAsync(ct); } catch { }
        await FailJobAsync(connStr, job, workerOwner, "internal.error", true);
    }
}

async Task FailJobAsync(string connStr, ClaimedJob job, string workerOwner, string errorCode, bool retryable)
{
    try
    {
        await using var conn = new NpgsqlConnection(connStr);
        await conn.OpenAsync();

        await using var cmd = new NpgsqlCommand(
            "SELECT workflow.fail_job(@jid, @owner, @lv, @code, @ret)", conn);
        cmd.Parameters.AddWithValue("jid", job.JobId);
        cmd.Parameters.AddWithValue("owner", workerOwner);
        cmd.Parameters.AddWithValue("lv", job.LeaseVersion);
        cmd.Parameters.AddWithValue("code", errorCode);
        cmd.Parameters.AddWithValue("ret", retryable);

        var result = await cmd.ExecuteScalarAsync() as string;
        var state = JsonNode.Parse(result!)?["jobState"]?.GetValue<string>();
        if (state is not ("RETRY_WAIT" or "DEAD"))
            throw new InvalidOperationException("Invalid fail_job result");
        EmitEvent("worker.fail", workerOwner, job, errorCode: errorCode, jobState: state);
        if (state == "RETRY_WAIT")
            EmitEvent("worker.retry", workerOwner, job, errorCode: errorCode, jobState: state);
    }
    catch (PostgresException ex) when (ex.MessageText == "workflow.lease_stale")
    {
        EmitEvent("worker.stale", workerOwner, job, errorCode: "workflow.lease_stale");
    }
    catch (Exception)
    {
        EmitEvent("worker.fail_unconfirmed", workerOwner, job, errorCode: "internal.error");
    }
}

void EmitEvent(string eventName, string instanceId, ClaimedJob? job = null,
    string? outcome = null, string? errorCode = null, string? jobState = null)
{
    // Only bounded contract codes are loggable; never serialize target messages or exceptions.
    if (errorCode is not null && (errorCode.Length > 128 ||
        !System.Text.RegularExpressions.Regex.IsMatch(errorCode, @"\A[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+\z")))
        errorCode = "internal.error";
    Console.WriteLine(JsonSerializer.Serialize(new
    {
        @event = eventName,
        timestamp = DateTime.UtcNow,
        instanceId,
        processId = job?.ProcessId,
        jobId = job?.JobId,
        executionId = job?.ExecutionId,
        attemptId = job?.AttemptId,
        leaseVersion = job?.LeaseVersion,
        outcome,
        errorCode,
        jobState
    }));
}

void EmitFailpoint(string name, string instanceId)
{
    Console.WriteLine(JsonSerializer.Serialize(new
    {
        @event = "failpoint.reached",
        name,
        instanceId
    }));
    Console.Out.Flush();
}

public record ClaimedJob(
    Guid JobId,
    Guid ProcessId,
    Guid StepInstanceId,
    Guid ExecutionId,
    Guid AttemptId,
    long LeaseVersion,
    string StepKey,
    string Service,
    string Module,
    string Action,
    int ActionVersion,
    List<string> RequiredPolicy,
    int TimeoutMs,
    JsonObject InputMapping,
    JsonObject InputConstants,
    JsonObject ProcessData,
    List<string> ExpectedOutcomes,
    JsonSchema? RequestSchema,
    JsonSchema? ResponseSchema
);
