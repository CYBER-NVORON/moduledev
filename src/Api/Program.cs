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
var jwtIssuer = Env("COURSE_JWT_ISSUER");
var jwtAudience = Env("COURSE_JWT_AUDIENCE");
var jwtSigningKey = Env("COURSE_JWT_SIGNING_KEY");
var dbConnection = Env("COURSE_DB_CONNECTION");

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
app.MapGet("/health/live", () => Results.Ok(new { status = "ok" }));
app.MapGet("/health/ready", async () =>
{
    try
    {
        await using var conn = new NpgsqlConnection(dbConnection);
        await conn.OpenAsync();
        await using var cmd = new NpgsqlCommand("SELECT 1", conn);
        await cmd.ExecuteScalarAsync();
        return Results.Ok(new { status = "ok" });
    }
    catch
    {
        return Results.Json(new { status = "error", code = "dependency.unavailable", message = "database not ready" },
            statusCode: 503);
    }
});

// --- OpenAPI ---
app.MapGet("/openapi/default.json", async () =>
{
    try
    {
        var actions = await LoadActions(enabled: true, isDefault: true);
        return Results.Json(BuildOpenApiDoc(actions));
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
        return Results.Json(BuildOpenApiDoc(actions));
    }
    catch (NpgsqlException)
    {
        return Results.Json(ErrorEnvelope("dependency.unavailable", "database unavailable", null), statusCode: 503);
    }
});

// --- Generic Action Route ---
app.MapPost("/api/{module}/{action}", async (HttpContext ctx, string module, string action) =>
{
    string? correlationId = Guid.NewGuid().ToString();
    int? actionVersion = null;
    string principal = "";
    string payloadHash = "";

    try
    {
        // 1. JWT Authentication
        (principal, var consumer, var scopes, var authErr) = ValidateJwt(ctx);
        if (authErr is not null)
            return await ErrorResultAsync(401, "auth.invalid", authErr);

        // 2. Parse version header
        int? requestedVersion = null;
        if (ctx.Request.Headers.TryGetValue("X-Action-Version", out var versionHeader))
        {
            if (versionHeader.Count != 1
                || !int.TryParse(versionHeader[0], NumberStyles.None, CultureInfo.InvariantCulture, out var v)
                || v < 1)
                return await ErrorResultAsync(400, "request.invalid", "invalid X-Action-Version header");
            requestedVersion = v;
        }

        // 3. Read body to get hash, then parse (zero-allocation)
        ctx.Request.EnableBuffering();
        using (var sha = System.Security.Cryptography.SHA256.Create())
        {
            var bytes = await sha.ComputeHashAsync(ctx.Request.Body, ctx.RequestAborted);
            payloadHash = Convert.ToHexString(bytes).ToLowerInvariant();
        }
        ctx.Request.Body.Position = 0;

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

                // 8. Request schema validation
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

                // 9. Build server-side context
                var deadline = DateTime.UtcNow.AddMilliseconds(manifest.TimeoutMs).ToString("O");
                var context = new JsonObject
                {
                    ["principal"] = principal,
                    ["consumer"] = consumer,
                    ["scopes"] = JsonSerializer.SerializeToNode(scopes),
                    ["correlationId"] = correlationId,
                    ["requestId"] = idempotencyKey ?? "",
                    ["deadline"] = deadline
                };

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
                cmd.Parameters.AddWithValue("version", manifest.Version);
                cmd.Parameters.AddWithValue("context", context.ToJsonString());
                cmd.Parameters.AddWithValue("payload", payload.ToJsonString());

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

                if (dbNode is not JsonObject dbObject)
                {
                    await tx.RollbackAsync();
                    return await ErrorResultAsync(500, "action.contract_violation", "database function returned a non-object envelope");
                }

                var dbStatus = dbObject["status"] is JsonValue statusValue
                    && statusValue.TryGetValue<string>(out var parsedStatus)
                    ? parsedStatus
                    : null;
                var dbOutcome = dbObject["outcome"] is JsonValue outcomeValue
                    && outcomeValue.TryGetValue<string>(out var parsedOutcome)
                    ? parsedOutcome
                    : null;

                if (dbStatus != "ok" && dbStatus != "error")
                {
                    await tx.RollbackAsync();
                    return await ErrorResultAsync(500, "action.contract_violation", "database function returned an invalid status");
                }

                // If DB returned error -> ROLLBACK
                if (dbStatus == "error")
                {
                    await tx.RollbackAsync();
                    if (dbObject["code"] is not JsonValue codeValue
                        || !codeValue.TryGetValue<string>(out var errCode)
                        || string.IsNullOrWhiteSpace(errCode)
                        || dbObject["message"] is not JsonValue messageValue
                        || !messageValue.TryGetValue<string>(out var errMsg)
                        || string.IsNullOrWhiteSpace(errMsg))
                    {
                        return await ErrorResultAsync(500, "action.contract_violation", "database function returned an invalid error envelope");
                    }

                    // Idempotency conflict and access.denied pass through with proper HTTP codes
                    var httpStatus = errCode switch
                    {
                        "idempotency.conflict" => 409,
                        "access.denied" => 403,
                        "action.not_found" => 404,
                        "operation.not_found" => 404,
                        "action.contract_violation" => 500,
                        _ => 400
                    };

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

                // Idempotent replay: DB returned stored envelope with its own meta → pass through
                if (dbObject["meta"] is JsonObject existingMeta
                    && existingMeta["correlationId"] is not null)
                {
                    return Results.Json(dbObject, statusCode: 200);
                }

                return Results.Json(new
                {
                    status = "ok",
                    outcome = dbOutcome,
                    result = dbObject["result"],
                    meta = new { correlationId, actionVersion }
                }, statusCode: 200);
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
        catch (Exception ex) when (IsTransientDatabaseError(ex))
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
        var reqId = ctx.Request.Headers["Idempotency-Key"].FirstOrDefault();
        try
        {
            await using var logConn = new NpgsqlConnection(dbConnection);
            await logConn.OpenAsync();
            await using var cmd = new NpgsqlCommand(
                "INSERT INTO catalog.action_dispatches (correlation_id, request_id, module, action, version, principal, payload_hash, status, outcome) " +
                "VALUES (@corr::uuid, @req, @mod, @act, @ver, @prin, @hash, 'ERROR', @out)", logConn);
            cmd.Parameters.AddWithValue("corr", correlationId ?? Guid.NewGuid().ToString());
            cmd.Parameters.AddWithValue("req", (object?)reqId ?? DBNull.Value);
            cmd.Parameters.AddWithValue("mod", module);
            cmd.Parameters.AddWithValue("act", action);
            cmd.Parameters.AddWithValue("ver", actionVersion ?? 0);
            cmd.Parameters.AddWithValue("prin", principal);
            cmd.Parameters.AddWithValue("hash", payloadHash);
            cmd.Parameters.AddWithValue("out", (object?)outcome ?? DBNull.Value);
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

// --- JWT Validation ---
(string principal, string consumer, List<string> scopes, string? error) ValidateJwt(HttpContext ctx)
{
    var authHeader = ctx.Request.Headers.Authorization.FirstOrDefault();
    if (string.IsNullOrEmpty(authHeader) || !authHeader.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase))
        return (null!, null!, null!, "missing or invalid Authorization header");

    var token = authHeader["Bearer ".Length..].Trim();
    if (string.IsNullOrEmpty(token))
        return (null!, null!, null!, "empty token");

    try
    {
        var handler = jwtHandler;
        handler.ValidateToken(token, tokenValidationParams, out var validatedToken);

        if (validatedToken is not JwtSecurityToken jwt)
            return (null!, null!, null!, "invalid token type");

        // Strict claim type validation
        var issClaim = jwt.Payload["iss"];
        if (issClaim is not string)
            return (null!, null!, null!, "iss claim must be a string");

        if (!jwt.Payload.TryGetValue("aud", out var audClaim) || audClaim is not string)
            return (null!, null!, null!, "aud claim must be a string");
        if (!jwt.Payload.TryGetValue("iat", out var iatClaim) || !IsNumericDateClaim(iatClaim))
            return (null!, null!, null!, "iat claim must be a number");
        if (!jwt.Payload.TryGetValue("exp", out var expClaim) || !IsNumericDateClaim(expClaim))
            return (null!, null!, null!, "exp claim must be a number");

        // Reject non-string sub (e.g. numeric 42 in JWT payload)
        // JwtSecurityTokenHandler auto-converts "sub" to string, so we must inspect the raw JSON.
        var parts = token.Split('.');
        if (parts.Length != 3) return (null!, null!, null!, "invalid token format");
        
        var payloadJson = Base64UrlEncoder.Decode(parts[1]);
        var rawNode = JsonNode.Parse(payloadJson);
        if (rawNode?["sub"] is not JsonValue subVal || !subVal.TryGetValue<string>(out _) || subVal.GetValue<JsonElement>().ValueKind != JsonValueKind.String)
            return (null!, null!, null!, "sub claim must be a non-empty string");

        var sub = subVal.GetValue<string>();
        if (string.IsNullOrEmpty(sub))
            return (null!, null!, null!, "sub claim is required");

        var consumerClaim = jwt.Payload.TryGetValue("consumer", out var consumerObj) ? consumerObj : null;
        if (consumerClaim is not string consumerStr || string.IsNullOrEmpty(consumerStr))
            return (null!, null!, null!, "consumer claim must be a non-empty string");

        var scopeClaim = jwt.Payload.TryGetValue("scope", out var scopeObj) ? scopeObj : null;
        if (scopeClaim is not string scopeStr)
            return (null!, null!, null!, "scope claim must be a string");

        var scopes = string.IsNullOrWhiteSpace(scopeStr)
            ? new List<string>()
            : scopeStr.Split(' ', StringSplitOptions.RemoveEmptyEntries).ToList();

        return (sub, consumerStr, scopes, null);
    }
    catch (SecurityTokenExpiredException)
    {
        return (null!, null!, null!, "token expired");
    }
    catch (SecurityTokenException)
    {
        return (null!, null!, null!, "invalid token");
    }
    catch (Exception)
    {
        return (null!, null!, null!, "token validation failed");
    }
}

// --- Action Manifest Loading ---
async Task<ActionManifest?> LoadManifest(string module, string action, int? version,
    NpgsqlConnection conn, NpgsqlTransaction tx)
{
    string sql;
    NpgsqlCommand cmd;

    if (version.HasValue)
    {
        sql = "SELECT version, manifest_json, target_schema, target_function, outcomes, " +
              "required_policy, idempotency_mode, idempotency_scope, timeout_ms, enabled " +
              "FROM catalog.actions WHERE module=@m AND action=@a AND version=@v";
        cmd = new NpgsqlCommand(sql, conn, tx);
        cmd.Parameters.AddWithValue("m", module);
        cmd.Parameters.AddWithValue("a", action);
        cmd.Parameters.AddWithValue("v", version.Value);
    }
    else
    {
        sql = "SELECT version, manifest_json, target_schema, target_function, outcomes, " +
              "required_policy, idempotency_mode, idempotency_scope, timeout_ms, enabled " +
              "FROM catalog.actions WHERE module=@m AND action=@a AND is_default=true AND enabled=true";
        cmd = new NpgsqlCommand(sql, conn, tx);
        cmd.Parameters.AddWithValue("m", module);
        cmd.Parameters.AddWithValue("a", action);
    }

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

        JsonSchema? requestSchema = null;
        JsonSchema? responseSchema = null;
        if (manifestNode?["request_schema"] is JsonNode reqSchemaNode)
        {
            var reqText = reqSchemaNode.ToJsonString();
            requestSchema = SchemaCache.GetOrAdd(reqText, text => JsonSchema.FromText(text));
        }
        if (manifestNode?["response_schema"] is JsonNode resSchemaNode)
        {
            var resText = resSchemaNode.ToJsonString();
            responseSchema = SchemaCache.GetOrAdd(resText, text => JsonSchema.FromText(text));
        }

        return new ActionManifest
        {
            Version = ver,
            TargetSchema = reader.GetString(2),
            TargetFunction = reader.GetString(3),
            Outcomes = outcomes,
            RequiredPolicy = requiredPolicy,
            IdempotencyMode = reader.GetString(6),
            IdempotencyScope = reader.GetString(7),
            TimeoutMs = reader.GetInt32(8),
            RequestSchema = requestSchema,
            ResponseSchema = responseSchema,
        };
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

object BuildOpenApiDoc(List<ActionInfo> actions)
{
    var paths = new Dictionary<string, object>();
    foreach (var a in actions)
    {
        var path = $"/api/{a.Module}/{a.Action}";
        var manifestNode = JsonNode.Parse(a.ManifestJson);
        var requestSchema = manifestNode?["request_schema"];
        var responseSchema = manifestNode?["response_schema"];

        var responseRequired = responseSchema is not null
            ? new[] { "status", "outcome", "meta", "result" }
            : new[] { "status", "outcome", "meta" };

        var operation = new Dictionary<string, object>
        {
            ["operationId"] = $"{a.Module}.{a.Action}.v{a.Version}",
            ["summary"] = $"{a.Module}.{a.Action} v{a.Version}",
            ["parameters"] = new object[]
            {
                new Dictionary<string, object>
                {
                    ["name"] = "X-Action-Version",
                    ["in"] = "header",
                    ["required"] = false,
                    ["schema"] = new Dictionary<string, object> { ["const"] = a.Version }
                }
            },
            ["requestBody"] = new Dictionary<string, object>
            {
                ["required"] = true,
                ["content"] = new Dictionary<string, object>
                {
                    ["application/json"] = new Dictionary<string, object?>
                    {
                        ["schema"] = requestSchema is not null
                            ? JsonSerializer.Deserialize<object>(requestSchema.ToJsonString())
                            : new { type = "object" }
                    }
                }
            },
            ["responses"] = new Dictionary<string, object>
            {
                ["200"] = new Dictionary<string, object>
                {
                    ["description"] = "Success",
                    ["content"] = new Dictionary<string, object>
                    {
                        ["application/json"] = new Dictionary<string, object?>
                        {
                            ["schema"] = new Dictionary<string, object?>
                            {
                                ["type"] = "object",
                                ["required"] = responseRequired,
                                ["properties"] = new Dictionary<string, object?>
                                {
                                    ["status"] = new { type = "string" },
                                    ["outcome"] = new { type = "string" },
                                    ["meta"] = new { type = "object" },
                                    ["result"] = responseSchema is not null
                                        ? JsonSerializer.Deserialize<object>(responseSchema.ToJsonString())
                                        : new { type = "object" }
                                }
                            }
                        }
                    }
                }
            }
        };

        paths[path] = new Dictionary<string, object> { ["post"] = operation };
    }

    return new
    {
        openapi = "3.0.3",
        info = new { title = "Course Action Runtime", version = "1.0.0" },
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

string Env(string name) => Environment.GetEnvironmentVariable(name)
    ?? throw new InvalidOperationException($"{name} not set");

bool IsNumericDateClaim(object? value) => value switch
{
    byte or sbyte or short or ushort or int or uint or long or ulong => true,
    JsonElement element => element.ValueKind == JsonValueKind.Number && element.TryGetInt64(out _),
    _ => false
};

bool IsTransientDatabaseError(Exception ex) => ex switch
{
    PostgresException => false,
    NpgsqlException npgsql => npgsql.InnerException is System.Net.Sockets.SocketException
        or System.IO.IOException or TimeoutException,
    System.Net.Sockets.SocketException or System.IO.IOException or TimeoutException => true,
    _ when ex.InnerException is not null => IsTransientDatabaseError(ex.InnerException),
    _ => false
};

// --- Models ---

class ActionManifest
{
    public int Version { get; init; }
    public string TargetSchema { get; init; } = "";
    public string TargetFunction { get; init; } = "";
    public List<string> Outcomes { get; init; } = new();
    public List<string> RequiredPolicy { get; init; } = new();
    public string IdempotencyMode { get; init; } = "none";
    public string IdempotencyScope { get; init; } = "none";
    public int TimeoutMs { get; init; } = 5000;
    public JsonSchema? RequestSchema { get; init; }
    public JsonSchema? ResponseSchema { get; init; }
}

record ActionInfo(string Module, string Action, int Version, string ManifestJson, bool Enabled, bool IsDefault);
