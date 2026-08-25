using System.Security.Cryptography;
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Json.Schema;
using Npgsql;

var jsonOpts = new JsonSerializerOptions { WriteIndented = true, PropertyNamingPolicy = null };

var ManifestSchema = JsonSchema.FromText("""
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "urn:course:course-1:action-manifest",
  "title": "Course action manifest",
  "type": "object",
  "additionalProperties": false,
  "required": [
    "contract_version","module","action","version","http_method",
    "target_schema","target_function","request_schema","response_schema",
    "outcomes","required_policy","idempotency_mode","idempotency_scope",
    "timeout_ms","enabled","is_default"
  ],
  "properties": {
    "contract_version": {"const": "course-1"},
    "module": {"$ref": "#/$defs/sqlIdentifier"},
    "action": {"$ref": "#/$defs/sqlIdentifier"},
    "version": {"type": "integer", "minimum": 1},
    "http_method": {"const": "POST"},
    "target_schema": {"$ref": "#/$defs/sqlIdentifier"},
    "target_function": {"$ref": "#/$defs/sqlIdentifier"},
    "request_schema": {"$ref": "#/$defs/schemaDocument"},
    "response_schema": {"$ref": "#/$defs/schemaDocument"},
    "outcomes": {
      "type": "array","minItems": 1,"uniqueItems": true,
      "items": {"$ref": "#/$defs/outcome"}
    },
    "required_policy": {
      "type": "array","uniqueItems": true,
      "items": {"type": "string","pattern": "^[a-z][a-z0-9_-]*:[a-z][a-z0-9_-]*$"}
    },
    "idempotency_mode": {"enum": ["none","optional","required"]},
    "idempotency_scope": {"enum": ["none","principal_action","consumer_action","global_action"]},
    "timeout_ms": {"type": "integer","minimum": 1,"maximum": 30000},
    "enabled": {"type": "boolean"},
    "is_default": {"type": "boolean"}
  },
  "allOf": [
    {
      "if": {"properties": {"idempotency_mode": {"const": "none"}},"required": ["idempotency_mode"]},
      "then": {"properties": {"idempotency_scope": {"const": "none"}}},
      "else": {"properties": {"idempotency_scope": {"enum": ["principal_action","consumer_action","global_action"]}}}
    },
    {
      "if": {"properties": {"is_default": {"const": true}},"required": ["is_default"]},
      "then": {"properties": {"enabled": {"const": true}}}
    }
  ],
  "$defs": {
    "sqlIdentifier": {"type": "string","pattern": "^[a-z][a-z0-9_]{0,62}$"},
    "outcome": {"type": "string","pattern": "^[A-Z][A-Z0-9_]{0,62}$"},
    "schemaDocument": {
      "type": "object","required": ["$schema"],
      "properties": {"$schema": {"const": "https://json-schema.org/draft/2020-12/schema"}}
    }
  }
}
""");

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

    return (args[0], args.ElementAtOrDefault(1)) switch
    {
        ("migration", "apply") when args.Length >= 3 => await MigrationApply(GetConn(), args[2]),
        ("action", "validate") when args.Length >= 3 => ActionValidate(args[2]),
        ("action", "publish") when args.Length >= 3 => await ActionPublish(GetConn(), args[2]),
        ("action", "list") => await ActionList(GetConn()),
        ("action", "activate") when args.Length >= 4 => await ActionActivate(GetConn(), args),
        ("action", "disable") when args.Length >= 4 => await ActionDisable(GetConn(), args),
        _ => Fail("request.invalid", $"unknown command: {string.Join(' ', args)}")
    };
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
        var content = await File.ReadAllTextAsync(file);
        var normalized = content.Replace("\r\n", "\n");
        var hash = Sha256Hex(normalized);

        // Check if already applied
        await using var checkCmd = new NpgsqlCommand(
            "SELECT checksum_sha256 FROM catalog.migrations WHERE filename = @f", conn);
        checkCmd.Parameters.AddWithValue("f", filename);
        var existing = await checkCmd.ExecuteScalarAsync() as string;

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
            await using var execCmd = new NpgsqlCommand(content, conn, tx);
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

    var (valid, message, manifest) = ValidateManifest(manifestPath);
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

    var (valid, message, manifest) = ValidateManifest(manifestPath);
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
    var hash = Sha256Hex(manifestText);

    await using var conn = new NpgsqlConnection(connStr);
    await conn.OpenAsync();
    await using var tx = await conn.BeginTransactionAsync();

    try
    {
        // Insert-or-ignore plus a read in one transaction makes concurrent identical
        // publishes converge on the immutable catalog row.
        await using var insertCmd = new NpgsqlCommand(@"
            INSERT INTO catalog.actions
                (module, action, version, manifest_json, manifest_hash,
                 target_schema, target_function, http_method, outcomes,
                 required_policy, idempotency_mode, idempotency_scope,
                 timeout_ms, enabled, is_default)
            VALUES
                (@module, @action, @version, @manifest_json::jsonb, @manifest_hash,
                 @target_schema, @target_function, @http_method, @outcomes::jsonb,
                 @required_policy::jsonb, @idempotency_mode, @idempotency_scope,
                 @timeout_ms, @enabled, @is_default)
            ON CONFLICT (module, action, version) DO NOTHING", conn, tx);

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
        insertCmd.Parameters.AddWithValue("enabled", (bool)m["enabled"]!);
        insertCmd.Parameters.AddWithValue("is_default", (bool)m["is_default"]!);
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
    if (module is null || version is null)
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

    // Check version exists
    await using var checkCmd = new NpgsqlCommand(
        "SELECT 1 FROM catalog.actions WHERE module=@m AND action=@a AND version=@v", conn, tx);
    checkCmd.Parameters.AddWithValue("m", module);
    checkCmd.Parameters.AddWithValue("a", action);
    checkCmd.Parameters.AddWithValue("v", ver);
    if (await checkCmd.ExecuteScalarAsync() is null)
    {
        await tx.RollbackAsync();
        WriteEnvelope(Error("action.not_found", $"action {module}.{action} v{ver} not found"));
        return 1;
    }

    // Clear is_default for all versions of this route
    await using var clearCmd = new NpgsqlCommand(
        "UPDATE catalog.actions SET is_default = false WHERE module=@m AND action=@a", conn, tx);
    clearCmd.Parameters.AddWithValue("m", module);
    clearCmd.Parameters.AddWithValue("a", action);
    await clearCmd.ExecuteNonQueryAsync();

    // Set target version as enabled + default
    await using var setCmd = new NpgsqlCommand(
        "UPDATE catalog.actions SET enabled = true, is_default = true WHERE module=@m AND action=@a AND version=@v", conn, tx);
    setCmd.Parameters.AddWithValue("m", module);
    setCmd.Parameters.AddWithValue("a", action);
    setCmd.Parameters.AddWithValue("v", ver);
    await setCmd.ExecuteNonQueryAsync();

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

    if (module is null || version is null)
    {
        WriteEnvelope(Error("request.invalid", "usage: action disable <module.action> --version <v> [--replacement-version <v>]"));
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

    // Check if this version exists and is the default.
    await using var checkCmd = new NpgsqlCommand(
        "SELECT enabled, is_default FROM catalog.actions WHERE module=@m AND action=@a AND version=@v", conn, tx);
    checkCmd.Parameters.AddWithValue("m", module);
    checkCmd.Parameters.AddWithValue("a", action);
    checkCmd.Parameters.AddWithValue("v", ver);
    await using var checkReader = await checkCmd.ExecuteReaderAsync();

    if (!await checkReader.ReadAsync())
    {
        await checkReader.DisposeAsync();
        await tx.RollbackAsync();
        WriteEnvelope(Error("action.not_found", $"action {module}.{action} v{ver} not found"));
        return 1;
    }

    var wasEnabled = checkReader.GetBoolean(0);
    var wasDefault = checkReader.GetBoolean(1);
    await checkReader.DisposeAsync();

    if (wasDefault && replacement is null)
    {
        await tx.RollbackAsync();
        WriteEnvelope(Error("manifest.conflict",
            "disabling default version requires --replacement-version"));
        return 1;
    }

    if (replacement is not null)
    {
        if (!wasDefault)
        {
            await tx.RollbackAsync();
            WriteEnvelope(Error("request.invalid", "replacement version is only valid when disabling the default version"));
            return 1;
        }

        if (!TryParseVersion(replacement, out var repVer) || repVer == ver)
        {
            await tx.RollbackAsync();
            WriteEnvelope(Error("request.invalid", "replacement version must be a different positive integer"));
            return 1;
        }

        await using var repCheckCmd = new NpgsqlCommand(
            "SELECT enabled FROM catalog.actions WHERE module=@m AND action=@a AND version=@v", conn, tx);
        repCheckCmd.Parameters.AddWithValue("m", module);
        repCheckCmd.Parameters.AddWithValue("a", action);
        repCheckCmd.Parameters.AddWithValue("v", repVer);
        var replacementEnabled = await repCheckCmd.ExecuteScalarAsync();
        if (replacementEnabled is null)
        {
            await tx.RollbackAsync();
            WriteEnvelope(Error("action.not_found",
                $"replacement version {module}.{action} v{repVer} not found"));
            return 1;
        }

        if (!(bool)replacementEnabled)
        {
            await tx.RollbackAsync();
            WriteEnvelope(Error("request.invalid",
                $"replacement version {module}.{action} v{repVer} is disabled"));
            return 1;
        }
    }

    // A disabled version is already in the requested state; keep the command idempotent.
    if (!wasEnabled)
    {
        await tx.RollbackAsync();
        WriteEnvelope(Ok(new JsonObject
        {
            ["resource"] = "action",
            ["operation"] = "disabled",
            ["key"] = $"{module}.{action}",
            ["version"] = ver
        }));
        return 0;
    }

    // Disable the target version
    await using var disableCmd = new NpgsqlCommand(
        "UPDATE catalog.actions SET enabled = false, is_default = false WHERE module=@m AND action=@a AND version=@v", conn, tx);
    disableCmd.Parameters.AddWithValue("m", module);
    disableCmd.Parameters.AddWithValue("a", action);
    disableCmd.Parameters.AddWithValue("v", ver);
    await disableCmd.ExecuteNonQueryAsync();

    // If replacement specified, activate it.
    if (replacement is not null)
    {
        TryParseVersion(replacement, out var repVer);

        // Clear all defaults, then set replacement as enabled + default
        await using var clearCmd = new NpgsqlCommand(
            "UPDATE catalog.actions SET is_default = false WHERE module=@m AND action=@a", conn, tx);
        clearCmd.Parameters.AddWithValue("m", module);
        clearCmd.Parameters.AddWithValue("a", action);
        await clearCmd.ExecuteNonQueryAsync();

        await using var repCmd = new NpgsqlCommand(
            "UPDATE catalog.actions SET enabled = true, is_default = true WHERE module=@m AND action=@a AND version=@v", conn, tx);
        repCmd.Parameters.AddWithValue("m", module);
        repCmd.Parameters.AddWithValue("a", action);
        repCmd.Parameters.AddWithValue("v", repVer);
        await repCmd.ExecuteNonQueryAsync();
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
    var dot = key.IndexOf('.');
    return dot > 0 ? (key[..dot], key[(dot + 1)..]) : (null, null);
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

(bool valid, string message, JsonNode? manifest) ValidateManifest(string path)
{
    string text;
    try { text = File.ReadAllText(path); }
    catch (Exception ex) { return (false, ex.Message, null); }

    JsonNode? node;
    try { node = JsonNode.Parse(text); }
    catch (JsonException ex) { return (false, $"invalid JSON: {ex.Message}", null); }

    if (node is null) return (false, "empty JSON document", null);

    var result = ManifestSchema.Evaluate(node, new EvaluationOptions
    {
        OutputFormat = OutputFormat.List
    });

    if (!result.IsValid)
    {
        var errors = result.Details?
            .Where(d => d.Errors is not null)
            .SelectMany(d => d.Errors!)
            .Select(e => $"{e.Key}: {e.Value}")
            .ToList() ?? [];
        return (false, string.Join("; ", errors.Take(5)), null);
    }

    return (true, "valid", node);
}

string Sha256Hex(string content)
{
    var bytes = SHA256.HashData(Encoding.UTF8.GetBytes(content));
    return Convert.ToHexString(bytes).ToLowerInvariant();
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

int Fail(string code, string msg)
{
    WriteEnvelope(Error(code, msg));
    return 1;
}
