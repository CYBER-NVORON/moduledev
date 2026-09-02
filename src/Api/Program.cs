using System.Collections.Concurrent;
using System.Globalization;
using System.IdentityModel.Tokens.Jwt;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Json.Schema;
using Microsoft.IdentityModel.Tokens;
using Npgsql;

var SchemaCache = new ConcurrentDictionary<string, JsonSchema>();

var builder = WebApplication.CreateBuilder(args);

builder.Logging.ClearProviders().AddJsonConsole();

builder.WebHost.ConfigureKestrel(k => k.Limits.MaxRequestBodySize = 1_048_576); // 1 MB

// --- JSON logging to stdout, no secrets ---

// --- Configuration ---
var jwtIssuer = builder.Configuration["COURSE_JWT_ISSUER"];
var jwtAudience = builder.Configuration["COURSE_JWT_AUDIENCE"];
var jwtSigningKey = builder.Configuration["COURSE_JWT_SIGNING_KEY"];
var dbConnection = builder.Configuration["COURSE_DB_CONNECTION"];

var signingKeyBytes = Encoding.UTF8.GetBytes(jwtSigningKey);
var securityKey = new SymmetricSecurityKey(signingKeyBytes);

var tokenValidationParams = new TokenValidationParameters
{
    ValidateIssuer = true,
    ValidIssuer = jwtIssuer,
    ValidateAudience = true,
    ValidAudience = jwtAudience,
    ValidateLifetime = true,
    ValidateIssuerSigningKey = true,
    IssuerSigningKey = securityKey,
    ValidAlgorithms = new[] { SecurityAlgorithms.HmacSha256 },
    ClockSkew = TimeSpan.FromSeconds(5),
    RequireExpirationTime = true,
    RequireSignedTokens = true,
};

var jwtHandler = new JwtSecurityTokenHandler();

var app = builder.Build();

// --- Health ---
app.MapGet("/health/live", () => Results.Ok(new { status = "ok", schema_cache_size = SchemaCache.Count }));
app.MapGet("/health/ready", async () =>
{
    try
    {
        await using var conn = new NpgsqlConnection(dbConnection);
        await conn.OpenAsync();
        await using var cmd = new NpgsqlCommand("SELECT to_regclass('catalog.actions') IS NOT NULL AND to_regproc('api.invoke') IS NOT NULL", conn);
        var ready = (bool)(await cmd.ExecuteScalarAsync() ?? false);
        if (!ready) return Results.Json(new { status = "error", code = "dependency.unavailable", message = "migrations not applied" }, statusCode: 503);
        return Results.Ok(new { status = "ok", schema_cache_size = SchemaCache.Count });
    }
    catch (Exception)
    {
        return Results.Json(new { status = "error", code = "dependency.unavailable", message = "database not ready" }, statusCode: 503);
    }
});

// --- OpenAPI ---
app.MapGet("/openapi/default.json", async () =>
{
    try
    {
        var actions = await LoadActions(enabled: true, isDefault: true);
        return Results.Json(BuildOpenApiDoc(actions, false));
    }
    catch (NpgsqlException)
    {
        return Results.Json(ErrorEnvelope("dependency.unavailable", "database unavailable", null), statusCode: 503);
    }
});

app.MapGet("/openapi/actions/{module}/{action}/{version}.json", async (string module, string action, int version) =>
{
    try
    {
        var actions = await LoadActions(module: module, action: action, version: version);
        if (actions.Count == 0) return Results.Json(ErrorEnvelope("action.not_found", "action not found", null), statusCode: 404);
        return Results.Json(BuildOpenApiDoc(actions, true));
    }
    catch (NpgsqlException)
    {
        return Results.Json(ErrorEnvelope("dependency.unavailable", "database unavailable", null), statusCode: 503);
    }
});

// --- Generic Action Route ---
app.MapPost("/api/{module}/{action}", async (HttpContext ctx, string module, string action) =>
{
    var stopwatch = System.Diagnostics.Stopwatch.StartNew();
    string? correlationId = Guid.NewGuid().ToString();
    int? actionVersion = null;
    string principal = "";
    string payloadHash = "";

    try
    {
        // 1. JWT Authentication
        var authHeader = ctx.Request.Headers.Authorization.FirstOrDefault();
        string tokenStr = authHeader?.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase) == true ? authHeader["Bearer ".Length..].Trim() : "";
        (principal, var consumer, var scopes, var authErr) = Api.ApiHelpers.ValidateJwt(tokenStr, tokenValidationParams, jwtHandler);
        if (authErr is not null)
            return await ErrorResultAsync(401, "auth.invalid", authErr);

        // 2. Read body to get hash, then parse (zero-allocation)
        ctx.Request.EnableBuffering();
        payloadHash = Convert.ToHexStringLower(await System.Security.Cryptography.SHA256.HashDataAsync(ctx.Request.Body, ctx.RequestAborted));
        ctx.Request.Body.Position = 0;

        // 3. Parse version header
        int? requestedVersion = null;
        if (ctx.Request.Headers.TryGetValue("X-Action-Version", out var versionHeader))
        {
            if (versionHeader.Count != 1
                || !int.TryParse(versionHeader[0], NumberStyles.None, CultureInfo.InvariantCulture, out var v)
                || v < 1)
                return await ErrorResultAsync(400, "request.invalid", "invalid X-Action-Version header");
            requestedVersion = v;
        }

        JsonObject? payload;
        try
        {
            var node = await System.Text.Json.JsonSerializer.DeserializeAsync<JsonNode>(ctx.Request.Body, cancellationToken: ctx.RequestAborted) ?? new JsonObject();
            payload = node as JsonObject;
            if (payload is null)
            {
                return await ErrorResultAsync(400, "request.invalid", "payload must be a JSON object");
            }
        }
        catch
        {
            return await ErrorResultAsync(400, "request.invalid", "invalid JSON body");
        }

        // 4-10. Load the manifest and invoke the action in one transaction.
        try
        {
            await using var conn = new NpgsqlConnection(dbConnection);
            await conn.OpenAsync(ctx.RequestAborted);
            await using var tx = await conn.BeginTransactionAsync(ctx.RequestAborted);

            try
            {
                // 5. Read the current manifest on every request.
                var manifest = await LoadManifest(module, action, requestedVersion, conn, tx);

                if (manifest is null)
                {
                    await tx.RollbackAsync();
                    return await ErrorResultAsync(404, "action.not_found", $"action {module}.{action} not found or disabled");
                }

                actionVersion = manifest.Version;

                // 6. Policy check (HTTP boundary)
                foreach (var requiredScope in manifest.RequiredPolicy)
                {
                    if (!scopes.Contains(requiredScope))
                    {
                        await tx.RollbackAsync();
                        return await ErrorResultAsync(403, "access.denied", $"missing required scope: {requiredScope}");
                    }
                }

                // 7. Idempotency-Key check
                var idempotencyKey = ctx.Request.Headers["Idempotency-Key"].FirstOrDefault();
                if (manifest.IdempotencyMode == "required" && string.IsNullOrEmpty(idempotencyKey))
                {
                    await tx.RollbackAsync();
                    return await ErrorResultAsync(400, "idempotency.required", "Idempotency-Key header is required");
                }

                // 8. Build server-side context
                var context = JsonSerializer.SerializeToNode(new { principal, consumer, scopes, correlationId, requestId = idempotencyKey ?? "", deadline = DateTime.UtcNow.AddMilliseconds(manifest.TimeoutMs) });

                // 8.5. Cross-version replay check (before schema validation)
                if (requestedVersion is null && !string.IsNullOrEmpty(idempotencyKey))
                {
                    await using var replayCmd = new NpgsqlCommand(
                        "SELECT api.check_replay(@module, @action, @context::jsonb, @payload::jsonb)", conn, tx);
                    replayCmd.Parameters.AddWithValue("module", module);
                    replayCmd.Parameters.AddWithValue("action", action);
                    replayCmd.Parameters.AddWithValue("context", context.ToJsonString());
                    replayCmd.Parameters.AddWithValue("payload", payload?.ToJsonString() ?? "{}");
                    var replayJson = await replayCmd.ExecuteScalarAsync() as string;
                    if (replayJson is not null)
                    {
                        await tx.CommitAsync();
                        var replayNode = JsonNode.Parse(replayJson);
                        var status = replayNode?["status"]?.ToString();
                        var code = replayNode?["code"]?.ToString();
                        if (status == "error" && code == "idempotency.conflict")
                        {
                            return await ErrorResultAsync(409, "idempotency.conflict", replayNode?["message"]?.ToString() ?? "conflict");
                        }
                        return Results.Json(replayNode, statusCode: 200);
                    }
                }

                // 9. Request schema validation
                if (manifest.RequestSchema is not null)
                {
                    var schemaResult = manifest.RequestSchema.Evaluate(payload, new EvaluationOptions
                    {
                        OutputFormat = OutputFormat.List,
                        RequireFormatValidation = true
                    });
                    if (!schemaResult.IsValid)
                    {
                        await tx.RollbackAsync();
                        return await ErrorResultAsync(422, "payload.invalid", "payload does not match schema");
                    }
                }

                // 10. Execute api.invoke (same conn/tx)
                await using var cmd = new NpgsqlCommand(
                    "SELECT api.invoke(@module, @action, @version, @context::jsonb, @payload::jsonb)", conn, tx);
                await using (var timeoutCmd = new NpgsqlCommand(
                    "SELECT set_config('statement_timeout', @timeout, true)", conn, tx))
                {
                    timeoutCmd.Parameters.AddWithValue("timeout", $"{manifest.TimeoutMs}ms");
                    await timeoutCmd.ExecuteNonQueryAsync(ctx.RequestAborted);
                }
                cmd.CommandTimeout = Math.Max(1, (int)Math.Ceiling(manifest.TimeoutMs / 1000.0) + 1);
                cmd.Parameters.AddWithValue("module", module);
                cmd.Parameters.AddWithValue("action", action);
                cmd.Parameters.AddWithValue("version", requestedVersion.HasValue ? (object)requestedVersion.Value : DBNull.Value);
                cmd.Parameters.AddWithValue("context", context?.ToJsonString() ?? "{}");
                cmd.Parameters.AddWithValue("payload", payload?.ToJsonString() ?? "{}");

                var dbResult = await cmd.ExecuteScalarAsync(ctx.RequestAborted) as string;
                if (dbResult is null)
                {
                    await tx.RollbackAsync();
                    return await ErrorResultAsync(500, "action.contract_violation", "database function returned null");
                }

                var dbNode = JsonNode.Parse(dbResult);
                if (dbNode is null)
                {
                    await tx.RollbackAsync();
                    return await ErrorResultAsync(500, "action.contract_violation", "database function returned invalid JSON");
                }

                var dbObject = dbNode.AsObject();
                var dbStatus = dbObject["status"]!.GetValue<string>();
                var dbOutcome = dbObject["outcome"]?.GetValue<string>();

                // If DB returned error -> ROLLBACK
                if (dbStatus == "error")
                {
                    await tx.RollbackAsync();
                    var errCode = dbObject["code"]!.GetValue<string>();
                    var errMsg = dbObject["message"]!.GetValue<string>();

                    // Idempotency conflict and access.denied pass through with proper HTTP codes
                    var httpStatus = errCode switch
                    {
                        "idempotency.conflict" => 409,
                        "access.denied" => 403,
                        "action.not_found" => 404,
                        "operation.not_found" => 404,
                        "payload.invalid" => 422,
                        "auth.invalid" => 401,
                        "request.invalid" => 400,
                        "idempotency.required" => 400,
                        "action.contract_violation" => 500,
                        "internal.error" => 500,
                        "dependency.unavailable" => 503,
                        "action.timeout" => 504,
                        _ => 400
                    };

                    if (httpStatus >= 500)
                    {
                        app.Logger.LogError("Target error hidden from client: {Code} - {Message}", errCode, errMsg);
                        var safeCode = errCode == "action.contract_violation" ? "action.contract_violation" : "internal.error";
                        var safeMessage = errCode == "action.contract_violation" ? "contract violation" : "internal server error";
                        return await ErrorResultAsync(httpStatus, safeCode, safeMessage);
                    }

                    return Results.Json(new
                    {
                        status = "error",
                        code = errCode,
                        message = errMsg,
                        retryable = false,
                        details = new { },
                        meta = new { correlationId, actionVersion }
                    }, statusCode: httpStatus);
                }

                var isReplay = dbObject.TryGetPropertyValue("__is_replay", out var isReplayNode)
                    && isReplayNode is JsonValue isReplayVal
                    && isReplayVal.TryGetValue<bool>(out var isRep)
                    && isRep;

                if (isReplay)
                {
                    await tx.CommitAsync();
                    dbObject.Remove("__is_replay");
                    return Results.Json(dbObject, statusCode: 200);
                }

                // Check outcome against manifest
                if (dbOutcome is null || !manifest.Outcomes.Contains(dbOutcome))
                {
                    await tx.RollbackAsync();
                    return await ErrorResultAsync(500, "action.contract_violation", $"unexpected outcome: {dbOutcome ?? "null"}");
                }

                // Validate result against response schema
                var hasResult = dbObject.ContainsKey("result");
                if (manifest.ResponseSchema is not null && !hasResult)
                {
                    await tx.RollbackAsync();
                    return await ErrorResultAsync(500, "action.contract_violation", "result is required when response schema is configured");
                }

                if (manifest.ResponseSchema is not null)
                {
                    var resultValidation = manifest.ResponseSchema.Evaluate(dbObject["result"], new EvaluationOptions
                    {
                        OutputFormat = OutputFormat.List,
                        RequireFormatValidation = true
                    });
                    if (!resultValidation.IsValid)
                    {
                        await tx.RollbackAsync();
                        return await ErrorResultAsync(500, "action.contract_violation", "result does not match response schema");
                    }
                }

                // All good -> COMMIT
                await tx.CommitAsync();

                return Results.Json(dbObject, statusCode: 200);
            }
            catch (NpgsqlException ex) when (ex is PostgresException { SqlState: "57014" }
                || ex.InnerException is TimeoutException)
            {
                try { await tx.RollbackAsync(); } catch { /* best effort */ }
                return await ErrorResultAsync(504, "action.timeout", "action execution timed out");
            }
            catch
            {
                try { await tx.RollbackAsync(); } catch { /* best effort */ }
                throw;
            }
        }
        catch (PostgresException pex)
        {
            app.Logger.LogError(pex, "Database error in action {Module}.{Action}", module, action);
            return await ErrorResultAsync(500, "internal.error", "internal server error");
        }
        catch (Exception ex) when (Api.ApiHelpers.IsTransientDatabaseError(ex))
        {
            return await ErrorResultAsync(503, "dependency.unavailable", "database unavailable");
        }
    }
    catch (Exception ex)
    {
        app.Logger.LogError(ex, "Unhandled error in action {Module}.{Action}", module, action);
        return await ErrorResultAsync(500, "internal.error", "internal server error");
    }

    async Task LogDispatchErrorAsync(string code, string? outcome)
    {
        if (string.IsNullOrEmpty(principal)) return; // Don't log if we don't have a principal
        if (string.IsNullOrEmpty(payloadHash)) return; // Pre-admission, don't log
        
        stopwatch.Stop();
        var reqId = ctx.Request.Headers["Idempotency-Key"].FirstOrDefault();
        try
        {
            await using var logConn = new NpgsqlConnection(dbConnection);
            await logConn.OpenAsync();
            await using var cmd = new NpgsqlCommand(
                "INSERT INTO catalog.action_dispatches (correlation_id, request_id, module, action, version, principal, payload_hash, status, outcome, error_code, duration_ms, replay_marker) " +
                "VALUES (@corr::uuid, @req, @mod, @act, @ver, @prin, @hash, 'ERROR', @out, @code, @dur, false)", logConn);
            cmd.Parameters.AddWithValue("corr", correlationId ?? Guid.NewGuid().ToString());
            cmd.Parameters.AddWithValue("req", (object?)reqId ?? DBNull.Value);
            cmd.Parameters.AddWithValue("mod", module);
            cmd.Parameters.AddWithValue("act", action);
            cmd.Parameters.AddWithValue("ver", actionVersion ?? 0);
            cmd.Parameters.AddWithValue("prin", principal);
            cmd.Parameters.AddWithValue("hash", payloadHash);
            cmd.Parameters.AddWithValue("out", (object?)outcome ?? DBNull.Value);
            cmd.Parameters.AddWithValue("code", code);
            cmd.Parameters.AddWithValue("dur", (int)stopwatch.ElapsedMilliseconds);
            await cmd.ExecuteNonQueryAsync();
        }
        catch { /* best effort */ }
    }

    async Task<IResult> ErrorResultAsync(int httpStatus, string code, string message, string? outcome = null)
    {
        await LogDispatchErrorAsync(code, outcome);
        return ErrorResult(httpStatus, code, message, correlationId, actionVersion);
    }
});

app.MapFallback((HttpContext ctx) =>
{
    if (ctx.Request.Path.StartsWithSegments("/api"))
    {
        // /api/{module}/{action} is the only valid pattern; check segment count
        var segments = ctx.Request.Path.Value!.Split('/', StringSplitOptions.RemoveEmptyEntries);
        // segments: ["api", module, action] = 3 segments is a valid route, just wrong method
        if (segments.Length == 3)
            return ErrorResult(405, "request.invalid", "method not allowed", Guid.NewGuid().ToString(), null);
        return ErrorResult(404, "action.not_found", "route not found", Guid.NewGuid().ToString(), null);
    }
    return Results.NotFound(new { status = "error", code = "not_found", message = "route not found" });
});

app.Run();



// --- Action Manifest Loading ---
async Task<ActionManifest?> LoadManifest(string module, string action, int? version,
    NpgsqlConnection conn, NpgsqlTransaction tx)
{
    var sql = "SELECT version, manifest_json, target_schema, target_function, outcomes, " +
              "required_policy, idempotency_mode, idempotency_scope, timeout_ms, enabled " +
              "FROM catalog.actions WHERE module=@m AND action=@a " +
              (version.HasValue ? "AND version=@v" : "AND is_default=true AND enabled=true");
    var cmd = new NpgsqlCommand(sql, conn, tx);
    cmd.Parameters.AddWithValue("m", module);
    cmd.Parameters.AddWithValue("a", action);
    if (version.HasValue) cmd.Parameters.AddWithValue("v", version.Value);

    await using (cmd)
    {
        await using var reader = await cmd.ExecuteReaderAsync();
        if (!await reader.ReadAsync()) return null;

        var ver = reader.GetInt32(0);
        var manifestJson = reader.GetString(1);
        var enabled = reader.GetBoolean(9);

        if (!enabled) return null;

        var manifestNode = JsonNode.Parse(manifestJson);
        var outcomes = JsonSerializer.Deserialize<List<string>>(reader.GetString(4)) ?? new();
        var requiredPolicy = JsonSerializer.Deserialize<List<string>>(reader.GetString(5)) ?? new();

        JsonSchema? GetSchema(string key)
        {
            if (manifestNode?[key] is not JsonNode n) return null;
            if (SchemaCache.Count > 1000) return JsonSchema.FromText(n.ToJsonString());
            return SchemaCache.GetOrAdd(n.ToJsonString(), text => JsonSchema.FromText(text));
        }
        var requestSchema = GetSchema("request_schema");
        var responseSchema = GetSchema("response_schema");

        return new ActionManifest(ver, reader.GetString(2), reader.GetString(3), outcomes, requiredPolicy, reader.GetString(6), reader.GetString(7), reader.GetInt32(8), requestSchema, responseSchema);
    }
}

// --- OpenAPI Builder ---
async Task<List<ActionInfo>> LoadActions(bool enabled = false, bool isDefault = false,
    string? module = null, string? action = null, int? version = null)
{
    await using var conn = new NpgsqlConnection(dbConnection);
    await conn.OpenAsync();

    var sql = "SELECT module, action, version, manifest_json, enabled, is_default FROM catalog.actions WHERE 1=1";
    var pars = new List<NpgsqlParameter>();
    if (enabled) { sql += " AND enabled=true"; }
    if (isDefault) { sql += " AND is_default=true"; }
    if (module is not null) { sql += " AND module=@m"; pars.Add(new("m", module)); }
    if (action is not null) { sql += " AND action=@a"; pars.Add(new("a", action)); }
    if (version.HasValue) { sql += " AND version=@v"; pars.Add(new("v", version.Value)); }
    sql += " ORDER BY module, action, version";

    await using var cmd = new NpgsqlCommand(sql, conn);
    cmd.Parameters.AddRange(pars.ToArray());
    await using var reader = await cmd.ExecuteReaderAsync();

    var list = new List<ActionInfo>();
    while (await reader.ReadAsync())
    {
        list.Add(new ActionInfo(
            reader.GetString(0), reader.GetString(1), reader.GetInt32(2),
            reader.GetString(3), reader.GetBoolean(4), reader.GetBoolean(5)));
    }
    return list;
}

object BuildOpenApiDoc(List<ActionInfo> actions, bool isVersionSpecific)
{
    var paths = actions.ToDictionary(a => $"/api/{a.Module}/{a.Action}", a =>
    {
        var manifestNode = JsonNode.Parse(a.ManifestJson);
        var req = manifestNode?["request_schema"];
        var res = manifestNode?["response_schema"];
        var outcomes = manifestNode?["outcomes"]?.AsArray()?.Select(x => x?.ToString()).ToList() ?? new List<string?>();
        var op = new
        {
            operationId = $"{a.Module}.{a.Action}.v{a.Version}",
            summary = $"{a.Module}.{a.Action} v{a.Version}",
            parameters = new[] { new { name = "X-Action-Version", @in = "header", required = isVersionSpecific, schema = new { @const = a.Version } } },
            requestBody = new { required = true, content = new Dictionary<string, object> { ["application/json"] = new { schema = req is not null ? JsonSerializer.Deserialize<object>(req.ToJsonString()) : new { type = "object" } } } },
            responses = new Dictionary<string, object>
            {
                ["200"] = new { description = "Success", content = new Dictionary<string, object> { ["application/json"] = new { schema = new { type = "object", required = res is not null ? new[] { "status", "outcome", "meta", "result" } : new[] { "status", "outcome", "meta" }, properties = new Dictionary<string, object> { ["status"] = new { @const = "ok" }, ["outcome"] = new { @enum = outcomes }, ["meta"] = new { type = "object", required = new[] { "correlationId", "actionVersion" } }, ["result"] = res is not null ? JsonSerializer.Deserialize<object>(res.ToJsonString())! : new { type = "object" } } } } } },
                ["400"] = new { description = "Bad Request" }
            }
        };
        return (object)new Dictionary<string, object> { ["post"] = op };
    });

    return new
    {
        openapi = "3.1.0",
        info = new { title = "Module API", version = "1.0.0" },
        paths
    };
}

// --- Envelope Helpers ---
IResult ErrorResult(int httpStatus, string code, string message, string? correlationId, int? actionVersion)
{
    return Results.Json(ErrorEnvelope(code, message, correlationId, actionVersion), statusCode: httpStatus);
}

object ErrorEnvelope(string code, string message, string? correlationId, int? actionVersion = null)
{
    return new
    {
        status = "error",
        code,
        message,
        retryable = false,
        details = new { },
        meta = new { correlationId, actionVersion }
    };
}





// --- Models ---

public record ActionManifest(int Version, string TargetSchema, string TargetFunction, List<string> Outcomes, List<string> RequiredPolicy, string IdempotencyMode, string IdempotencyScope, int TimeoutMs, JsonSchema? RequestSchema, JsonSchema? ResponseSchema);

public record ActionInfo(string Module, string Action, int Version, string ManifestJson, bool Enabled, bool IsDefault);
public partial class ApiProgram { }
