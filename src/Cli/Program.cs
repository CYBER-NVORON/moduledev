using System.Security.Cryptography;
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Json.Schema;
using Npgsql;
using Cli;

var jsonOpts = new JsonSerializerOptions { WriteIndented = true, PropertyNamingPolicy = null };

try
{
    var exitCode = await Run(args);
    Environment.Exit(exitCode);
}
catch (Exception ex)
{
    Console.Error.WriteLine($"{ex.GetType().Name}: {ex.Message}");
    WriteEnvelope(Error("internal.error", "internal error"));
    Environment.Exit(1);
}

async Task<int> Run(string[] args)
{
    if (args.Length < 1)
    {
        WriteEnvelope(Error("request.invalid", "usage: cli <command> [args]"));
        return 1;
    }

    string GetConn() => Environment.GetEnvironmentVariable("COURSE_DB_CONNECTION")
                     ?? Environment.GetEnvironmentVariable("POSTGRES_CONNECTION_STRING")
                     ?? throw new InvalidOperationException("COURSE_DB_CONNECTION not set");

    string GetMigrationConn() => Environment.GetEnvironmentVariable("COURSE_MIGRATION_DB_CONNECTION")
                              ?? GetConn();

    switch (args[0], args.ElementAtOrDefault(1))
    {
        case ("migration", "apply") when args.Length >= 3: return await MigrationApply(GetMigrationConn(), args[2]);
        case ("action", "validate") when args.Length >= 3: return ActionValidate(args[2]);
        case ("action", "publish") when args.Length >= 3: return await ActionPublish(GetConn(), args[2]);
        case ("action", "list"): return await ActionList(GetConn());
        case ("action", "activate") when args.Length >= 4: return await ActionActivate(GetConn(), args);
        case ("action", "disable") when args.Length >= 4: return await ActionDisable(GetConn(), args);
        case ("flow", "validate") when args.Length >= 3: return await FlowCommands.FlowValidate(GetConn(), args[2]);
        case ("flow", "publish") when args.Length >= 3: return await FlowCommands.FlowPublish(GetConn(), args[2]);
        case ("flow", "list"): return await FlowCommands.FlowList(GetConn());
        case ("flow", "activate") when args.Length >= 4: return await FlowCommands.FlowActivate(GetConn(), args);
        case ("flow", "start") when args.Length >= 3: return await FlowCommands.FlowStart(GetConn(), args);
        case ("flow", "get") when args.Length >= 3: return await FlowCommands.FlowGet(GetConn(), args[2]);
        case ("flow", "signal") when args.Length >= 3: return await FlowCommands.FlowSignal(GetConn(), args);
        case ("flow", "test-finish") when args.Length >= 3: return await FlowCommands.FlowTestFinish(GetConn(), args);
        default:
            WriteEnvelope(Error("request.invalid", $"unknown command: {string.Join(' ', args)}"));
            return 1;
    }
}

// --- Migration Apply ---

async Task<int> MigrationApply(string connStr, string directory)
{
    if (!Directory.Exists(directory))
    {
        WriteEnvelope(Error("request.invalid", $"directory not found: {directory}"));
        return 1;
    }

    var files = Directory.GetFiles(directory, "*.sql")
        .OrderBy(Path.GetFileName, StringComparer.Ordinal)
        .ToList();

    await using var conn = new NpgsqlConnection(connStr);
    await conn.OpenAsync();

    var applied = new List<string>();

    foreach (var file in files)
    {
        var filename = Path.GetFileName(file)!;
        var rawContent = await File.ReadAllTextAsync(file);
        
        var normalizedTemplate = rawContent.Replace("\r\n", "\n");
        var hash = CliHelpers.Sha256Hex(normalizedTemplate);

        // Check if already applied
        string? existing = null;
        try
        {
            await using var checkCmd = new NpgsqlCommand(
                "SELECT checksum_sha256 FROM catalog.migrations WHERE filename = @f", conn);
            checkCmd.Parameters.AddWithValue("f", filename);
            existing = await checkCmd.ExecuteScalarAsync() as string;
        }
        catch (PostgresException ex) when (ex.SqlState == "42P01")
        {
            // Table doesn't exist yet, which is expected for the first migration
        }

        if (existing is not null)
        {
            if (existing != hash)
            {
                WriteEnvelope(Error("migration.conflict",
                    $"migration {filename} was already applied with different checksum"));
                return 1;
            }
            Console.Error.WriteLine($"[skip] {filename} (already applied)");
            continue;
        }

        // Apply in its own transaction
        await using var tx = await conn.BeginTransactionAsync();
        try
        {
            await using var execCmd = new NpgsqlCommand(rawContent, conn, tx);
            execCmd.CommandTimeout = 120;
            await execCmd.ExecuteNonQueryAsync();

            await using var insertCmd = new NpgsqlCommand(
                "INSERT INTO catalog.migrations (filename, checksum_sha256) VALUES (@f, @h)", conn, tx);
            insertCmd.Parameters.AddWithValue("f", filename);
            insertCmd.Parameters.AddWithValue("h", hash);
            await insertCmd.ExecuteNonQueryAsync();

            await tx.CommitAsync();
            applied.Add(filename);
            Console.Error.WriteLine($"[applied] {filename}");
        }
        catch
        {
            await tx.RollbackAsync();
            throw;
        }
    }

    WriteEnvelope(Ok(new JsonObject
    {
        ["resource"] = "migration",
        ["operation"] = "applied",
        ["applied"] = JsonSerializer.SerializeToNode(applied)
    }));
    return 0;
}

// --- Action Validate ---

int ActionValidate(string manifestPath)
{
    if (!File.Exists(manifestPath))
    {
        WriteEnvelope(Error("request.invalid", $"file not found: {manifestPath}"));
        return 1;
    }

    var (valid, message, manifest) = CliHelpers.ValidateManifest(manifestPath);
    if (!valid)
    {
        WriteEnvelope(Error("manifest.invalid", message));
        return 1;
    }

    var m = manifest!;
    WriteEnvelope(Ok(new JsonObject
    {
        ["resource"] = "action",
        ["operation"] = "validated",
        ["key"] = $"{m["module"]!}.{m["action"]!}",
        ["version"] = (int)m["version"]!
    }));
    return 0;
}

// --- Action Publish ---

async Task<int> ActionPublish(string connStr, string manifestPath)
{
    if (!File.Exists(manifestPath))
    {
        WriteEnvelope(Error("request.invalid", $"file not found: {manifestPath}"));
        return 1;
    }

    var (valid, message, manifest) = CliHelpers.ValidateManifest(manifestPath);
    if (!valid)
    {
        WriteEnvelope(Error("manifest.invalid", message));
        return 1;
    }

    var m = manifest!;
    var module = (string)m["module"]!;
    var action = (string)m["action"]!;
    var version = (int)m["version"]!;
    var manifestText = File.ReadAllText(manifestPath);
    var hash = CliHelpers.Sha256Hex(manifestText);

    var targetSchema = (string)m["target_schema"]!;
    var targetFunction = (string)m["target_function"]!;

    await using var conn = new NpgsqlConnection(connStr);
    await conn.OpenAsync();
    await using var tx = await conn.BeginTransactionAsync();

    try
    {
        await using var sigCmd = new NpgsqlCommand(
            "SELECT proretset FROM pg_proc JOIN pg_namespace n ON n.oid = pronamespace WHERE proname = @fn AND n.nspname = @sn", conn, tx);
        sigCmd.Parameters.AddWithValue("fn", targetFunction);
        sigCmd.Parameters.AddWithValue("sn", targetSchema);
        var isSet = await sigCmd.ExecuteScalarAsync();
        
        if (isSet is null) {
            await tx.RollbackAsync();
            WriteEnvelope(Error("manifest.invalid", $"target function {targetSchema}.{targetFunction} not found"));
            return 1;
        }
        if ((bool)isSet) {
            await tx.RollbackAsync();
            WriteEnvelope(Error("manifest.invalid", $"target function {targetSchema}.{targetFunction} has invalid signature (set-returning)"));
            return 1;
        }

        // Call encapsulated PostgreSQL routine
        await using var insertCmd = new NpgsqlCommand(@"
            SELECT catalog.publish_action(
                @module, @action, @version, @manifest_json::jsonb, @manifest_hash,
                @target_schema, @target_function, @http_method, @outcomes::jsonb,
                @required_policy::jsonb, @idempotency_mode, @idempotency_scope,
                @timeout_ms
            )", conn, tx);

        insertCmd.Parameters.AddWithValue("module", module);
        insertCmd.Parameters.AddWithValue("action", action);
        insertCmd.Parameters.AddWithValue("version", version);
        insertCmd.Parameters.AddWithValue("manifest_json", manifestText);
        insertCmd.Parameters.AddWithValue("manifest_hash", hash);
        insertCmd.Parameters.AddWithValue("target_schema", (string)m["target_schema"]!);
        insertCmd.Parameters.AddWithValue("target_function", (string)m["target_function"]!);
        insertCmd.Parameters.AddWithValue("http_method", (string)m["http_method"]!);
        insertCmd.Parameters.AddWithValue("outcomes", m["outcomes"]!.ToJsonString());
        insertCmd.Parameters.AddWithValue("required_policy", m["required_policy"]!.ToJsonString());
        insertCmd.Parameters.AddWithValue("idempotency_mode", (string)m["idempotency_mode"]!);
        insertCmd.Parameters.AddWithValue("idempotency_scope", (string)m["idempotency_scope"]!);
        insertCmd.Parameters.AddWithValue("timeout_ms", (int)m["timeout_ms"]!);
        await insertCmd.ExecuteNonQueryAsync();

        await using var checkCmd = new NpgsqlCommand(
            "SELECT manifest_hash FROM catalog.actions WHERE module=@m AND action=@a AND version=@v", conn, tx);
        checkCmd.Parameters.AddWithValue("m", module);
        checkCmd.Parameters.AddWithValue("a", action);
        checkCmd.Parameters.AddWithValue("v", version);
        var existingHash = await checkCmd.ExecuteScalarAsync() as string;

        if (existingHash is null)
            throw new InvalidOperationException("published action row disappeared during publish");

        if (existingHash != hash)
        {
            await tx.RollbackAsync();
            WriteEnvelope(Error("manifest.conflict", "published action version is immutable"));
            return 1;
        }

        await tx.CommitAsync();
    }
    catch (PostgresException ex) when (ex.SqlState == "23505")
    {
        try { await tx.RollbackAsync(); } catch { }
        WriteEnvelope(Error("manifest.conflict", "another version is already the default for this action"));
        return 1;
    }
    catch
    {
        try { await tx.RollbackAsync(); } catch { /* best effort */ }
        throw;
    }

    WriteEnvelope(Ok(new JsonObject
    {
        ["resource"] = "action",
        ["operation"] = "published",
        ["key"] = $"{module}.{action}",
        ["version"] = version
    }));
    return 0;
}

// --- Action List ---

async Task<int> ActionList(string connStr)
{
    await using var conn = new NpgsqlConnection(connStr);
    await conn.OpenAsync();

    await using var cmd = new NpgsqlCommand(
        "SELECT module, action, version, enabled, is_default FROM catalog.actions ORDER BY module, action, version", conn);
    await using var reader = await cmd.ExecuteReaderAsync();

    var items = new JsonArray();
    while (await reader.ReadAsync())
    {
        items.Add(new JsonObject
        {
            ["module"] = reader.GetString(0),
            ["action"] = reader.GetString(1),
            ["version"] = reader.GetInt32(2),
            ["enabled"] = reader.GetBoolean(3),
            ["is_default"] = reader.GetBoolean(4)
        });
    }

    WriteEnvelope(Ok(new JsonObject { ["items"] = items }));
    return 0;
}

// --- Action Activate ---

async Task<int> ActionActivate(string connStr, string[] args)
{
    var (module, action) = ParseRouteKey(args[2]);
    var version = ParseNamedArg(args, "--version");
    if (module is null || action is null || version is null)
    {
        WriteEnvelope(Error("request.invalid", "usage: action activate <module.action> --version <v>"));
        return 1;
    }

    if (!TryParseVersion(version, out var ver))
    {
        WriteEnvelope(Error("request.invalid", "version must be a positive integer"));
        return 1;
    }
    await using var conn = new NpgsqlConnection(connStr);
    await conn.OpenAsync();
    await using var tx = await conn.BeginTransactionAsync();

    try
    {
        await using var setCmd = new NpgsqlCommand(
            "SELECT catalog.activate_action(@m, @a, @v)", conn, tx);
        setCmd.Parameters.AddWithValue("m", module);
        setCmd.Parameters.AddWithValue("a", action);
        setCmd.Parameters.AddWithValue("v", ver);
        await setCmd.ExecuteNonQueryAsync();
    }
    catch (PostgresException ex) when (ex.MessageText == "action.not_found")
    {
        await tx.RollbackAsync();
        WriteEnvelope(Error("action.not_found", $"action {module}.{action} v{ver} not found"));
        return 1;
    }

    await tx.CommitAsync();

    WriteEnvelope(Ok(new JsonObject
    {
        ["resource"] = "action",
        ["operation"] = "activated",
        ["key"] = $"{module}.{action}",
        ["version"] = ver
    }));
    return 0;
}

// --- Action Disable ---

async Task<int> ActionDisable(string connStr, string[] args)
{
    var (module, action) = ParseRouteKey(args[2]);
    var version = ParseNamedArg(args, "--version");
    var replacement = ParseNamedArg(args, "--replacement-version");

    if (module is null || action is null || version is null)
    {
        WriteEnvelope(Error("request.invalid", "usage: action disable <module.action> --version <v> [--replacement-version <v>]"));
        return 1;
    }

    if (!TryParseVersion(version, out var ver))
    {
        WriteEnvelope(Error("request.invalid", "version must be a positive integer"));
        return 1;
    }

    int? repVer = null;
    if (replacement is not null)
    {
        if (!TryParseVersion(replacement, out var parsedRepVer) || parsedRepVer == ver)
        {
            WriteEnvelope(Error("request.invalid", "replacement version must be a different positive integer"));
            return 1;
        }
        repVer = parsedRepVer;
    }

    await using var conn = new NpgsqlConnection(connStr);
    await conn.OpenAsync();
    await using var tx = await conn.BeginTransactionAsync();

    try
    {
        await using var disableCmd = new NpgsqlCommand(
            "SELECT catalog.disable_action(@m, @a, @v, @rep)", conn, tx);
        disableCmd.Parameters.AddWithValue("m", module);
        disableCmd.Parameters.AddWithValue("a", action);
        disableCmd.Parameters.AddWithValue("v", ver);
        disableCmd.Parameters.AddWithValue("rep", repVer.HasValue ? (object)repVer.Value : DBNull.Value);
        await disableCmd.ExecuteNonQueryAsync();
    }
    catch (PostgresException ex) when (ex.MessageText is "action.not_found" or "manifest.conflict" or "request.invalid")
    {
        await tx.RollbackAsync();
        var message = ex.MessageText switch
        {
            "action.not_found" => $"action {module}.{action} or its replacement not found",
            "manifest.conflict" => "disabling default version requires --replacement-version",
            _ => "invalid replacement configuration"
        };
        WriteEnvelope(Error(ex.MessageText, message));
        return 1;
    }

    await tx.CommitAsync();

    WriteEnvelope(Ok(new JsonObject
    {
        ["resource"] = "action",
        ["operation"] = "disabled",
        ["key"] = $"{module}.{action}",
        ["version"] = ver
    }));
    return 0;
}

// --- Helpers ---

(string? module, string? action) ParseRouteKey(string key)
{
    var p = key.Split('.', 2);
    return p.Length == 2 ? (p[0], p[1]) : (null, null);
}

string? ParseNamedArg(string[] args, string name)
{
    var idx = Array.IndexOf(args, name);
    return idx >= 0 && idx + 1 < args.Length ? args[idx + 1] : null;
}

bool TryParseVersion(string? value, out int version)
{
    version = 0;
    return value is not null
        && int.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out version)
        && version > 0;
}


// --- Envelope ---

void WriteEnvelope(JsonObject envelope) =>
    Console.WriteLine(envelope.ToJsonString(jsonOpts));

JsonObject Ok(JsonObject result) => new()
{
    ["status"] = "ok",
    ["result"] = result,
    ["meta"] = new JsonObject { ["contractVersion"] = "course-1" }
};

JsonObject Error(string code, string message) => new()
{
    ["status"] = "error",
    ["code"] = code,
    ["message"] = message,
    ["meta"] = new JsonObject { ["contractVersion"] = "course-1" }
};


