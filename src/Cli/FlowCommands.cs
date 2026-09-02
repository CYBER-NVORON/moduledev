using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using System.Globalization;
using Npgsql;
using YamlDotNet.Core;
using YamlDotNet.RepresentationModel;

namespace Cli;

public static class FlowCommands
{
    private static readonly JsonSerializerOptions s_jsonOpts = new() { WriteIndented = true, PropertyNamingPolicy = null };

    public static JsonNode? ParseJsonOrYaml(string text)
    {
        var trimmed = text.Trim();
        if (trimmed.StartsWith('{') || trimmed.StartsWith('['))
        {
            return JsonNode.Parse(text);
        }
        try
        {
            using var reader = new StringReader(text);
            var yaml = new YamlStream();
            yaml.Load(reader);
            if (yaml.Documents.Count == 0 || yaml.Documents[0].RootNode is null)
                return null;
            return ConvertYamlToJsonNode(yaml.Documents[0].RootNode);
        }
        catch
        {
            return JsonNode.Parse(text);
        }
    }

    private static JsonNode? ConvertYamlToJsonNode(YamlNode yamlNode)
    {
        if (yamlNode is YamlScalarNode scalar)
        {
            var val = scalar.Value;
            if (val is null) return null;
            if (scalar.Style == ScalarStyle.Plain)
            {
                if (val == "true") return JsonValue.Create(true);
                if (val == "false") return JsonValue.Create(false);
                if (val == "null" || val == "~") return null;
                if (int.TryParse(val, NumberStyles.Integer, CultureInfo.InvariantCulture, out var intVal)) return JsonValue.Create(intVal);
                if (long.TryParse(val, NumberStyles.Integer, CultureInfo.InvariantCulture, out var longVal)) return JsonValue.Create(longVal);
                if (double.TryParse(val, NumberStyles.Float, CultureInfo.InvariantCulture, out var doubleVal)) return JsonValue.Create(doubleVal);
            }
            return JsonValue.Create(val);
        }
        if (yamlNode is YamlMappingNode mapping)
        {
            var obj = new JsonObject();
            foreach (var entry in mapping.Children)
            {
                var key = (entry.Key as YamlScalarNode)?.Value ?? entry.Key.ToString();
                obj[key] = ConvertYamlToJsonNode(entry.Value);
            }
            return obj;
        }
        if (yamlNode is YamlSequenceNode sequence)
        {
            var arr = new JsonArray();
            foreach (var item in sequence.Children)
            {
                arr.Add(ConvertYamlToJsonNode(item));
            }
            return arr;
        }
        return null;
    }

    public static async Task<int> FlowValidate(string connStr, string mapPath)
    {
        string mapText;
        if (mapPath == "/dev/stdin" || mapPath == "-")
        {
            mapText = await Console.In.ReadToEndAsync();
        }
        else
        {
            if (!File.Exists(mapPath))
            {
                WriteEnvelope(Error("request.invalid", $"file not found: {mapPath}"));
                return 1;
            }
            mapText = await File.ReadAllTextAsync(mapPath);
        }

        JsonNode? mapNode;
        try
        {
            mapNode = ParseJsonOrYaml(mapText);
        }
        catch (Exception ex)
        {
            WriteEnvelope(Error("map.invalid", "invalid JSON/YAML: " + ex.Message));
            return 1;
        }

        if (mapNode is null)
        {
            WriteEnvelope(Error("map.invalid", "empty workflow map"));
            return 1;
        }

        var (schemaOk, schemaErr) = FlowValidator.ValidateMapSchema(mapNode);
        if (!schemaOk)
        {
            WriteEnvelope(Error("map.invalid", schemaErr));
            return 1;
        }

        var (graphOk, graphErr) = FlowValidator.ValidateMapGraph(mapNode);
        if (!graphOk)
        {
            WriteEnvelope(Error("map.invalid", graphErr));
            return 1;
        }

        try
        {
            await using var conn = new NpgsqlConnection(connStr);
            await conn.OpenAsync();
            var (actionsOk, actionsErr) = await FlowValidator.ValidateActionsWithDb(mapNode, conn, null!);
            if (!actionsOk)
            {
                WriteEnvelope(Error("map.invalid", actionsErr));
                return 1;
            }
        }
        catch (Exception ex)
        {
            WriteEnvelope(Error("internal.error", "database error during validation: " + ex.Message));
            return 1;
        }

        var flowName = mapNode["flow_name"]?.GetValue<string>() ?? "";
        var flowVersion = AsInt(mapNode["version"]) ?? 1;

        WriteEnvelope(Ok(new JsonObject
        {
            ["resource"] = "flow",
            ["operation"] = "validated",
            ["flowName"] = flowName,
            ["flowVersion"] = flowVersion
        }));
        return 0;
    }

    public static JsonNode Canonicalize(JsonNode node)
    {
        if (node is JsonObject obj)
        {
            var sorted = new JsonObject();
            foreach (var prop in obj.OrderBy(p => p.Key, StringComparer.Ordinal))
            {
                sorted[prop.Key] = prop.Value is null ? null : Canonicalize(prop.Value);
            }
            return sorted;
        }
        if (node is JsonArray arr)
        {
            var result = new JsonArray();
            foreach (var item in arr)
            {
                result.Add(item is null ? null : Canonicalize(item));
            }
            return result;
        }
        return node.DeepClone();
    }

    public static async Task<int> FlowPublish(string connStr, string mapPath)
    {
        string mapText;
        if (mapPath == "/dev/stdin" || mapPath == "-")
        {
            mapText = await Console.In.ReadToEndAsync();
        }
        else
        {
            if (!File.Exists(mapPath))
            {
                WriteEnvelope(Error("request.invalid", $"file not found: {mapPath}"));
                return 1;
            }
            mapText = await File.ReadAllTextAsync(mapPath);
        }

        JsonNode? mapNode;
        try
        {
            mapNode = ParseJsonOrYaml(mapText);
        }
        catch (Exception ex)
        {
            WriteEnvelope(Error("map.invalid", "invalid JSON/YAML: " + ex.Message));
            return 1;
        }

        if (mapNode is null)
        {
            WriteEnvelope(Error("map.invalid", "empty workflow map"));
            return 1;
        }

        var (schemaOk, schemaErr) = FlowValidator.ValidateMapSchema(mapNode);
        if (!schemaOk)
        {
            WriteEnvelope(Error("map.invalid", schemaErr));
            return 1;
        }

        var (graphOk, graphErr) = FlowValidator.ValidateMapGraph(mapNode);
        if (!graphOk)
        {
            WriteEnvelope(Error("map.invalid", graphErr));
            return 1;
        }

        var flowName = mapNode["flow_name"]!.GetValue<string>();
        var flowVersion = AsInt(mapNode["version"]) ?? 1;
        var canonicalNode = Canonicalize(mapNode);
        var canonicalJson = canonicalNode.ToJsonString();
        var mapHash = CliHelpers.Sha256Hex(canonicalJson);

        await using var conn = new NpgsqlConnection(connStr);
        await conn.OpenAsync();
        await using var tx = await conn.BeginTransactionAsync();

        try
        {
            // Validate actions in DB
            var (actionsOk, actionsErr) = await FlowValidator.ValidateActionsWithDb(mapNode, conn, tx);
            if (!actionsOk)
            {
                await tx.RollbackAsync();
                WriteEnvelope(Error("map.invalid", actionsErr));
                return 1;
            }

            // Check if flow definition exists, insert if not
            await using var defCmd = new NpgsqlCommand(
                "INSERT INTO workflow.flow_definitions (flow_name) VALUES (@n) ON CONFLICT (flow_name) DO NOTHING", conn, tx);
            defCmd.Parameters.AddWithValue("n", flowName);
            await defCmd.ExecuteNonQueryAsync();

            // Check if this version already exists
            await using var checkCmd = new NpgsqlCommand(
                "SELECT map_hash FROM workflow.flow_versions WHERE flow_name = @n AND flow_version = @v", conn, tx);
            checkCmd.Parameters.AddWithValue("n", flowName);
            checkCmd.Parameters.AddWithValue("v", flowVersion);
            var existingHash = await checkCmd.ExecuteScalarAsync() as string;

            if (existingHash is not null)
            {
                if (existingHash == mapHash)
                {
                    // Idempotent publish
                    await tx.CommitAsync();
                    WriteEnvelope(Ok(new JsonObject
                    {
                        ["resource"] = "flow",
                        ["operation"] = "published",
                        ["flowName"] = flowName,
                        ["flowVersion"] = flowVersion
                    }));
                    return 0;
                }
                else
                {
                    await tx.RollbackAsync();
                    WriteEnvelope(Error("flow.conflict", $"flow {flowName} v{flowVersion} already published with different content"));
                    return 1;
                }
            }

            // Insert new version
            await using var insertCmd = new NpgsqlCommand(
                "INSERT INTO workflow.flow_versions (flow_name, flow_version, map_json, map_hash, status, is_active) " +
                "VALUES (@n, @v, @json::jsonb, @hash, 'PUBLISHED', false)", conn, tx);
            insertCmd.Parameters.AddWithValue("n", flowName);
            insertCmd.Parameters.AddWithValue("v", flowVersion);
            insertCmd.Parameters.AddWithValue("json", canonicalJson);
            insertCmd.Parameters.AddWithValue("hash", mapHash);
            await insertCmd.ExecuteNonQueryAsync();

            await tx.CommitAsync();

            WriteEnvelope(Ok(new JsonObject
            {
                ["resource"] = "flow",
                ["operation"] = "published",
                ["flowName"] = flowName,
                ["flowVersion"] = flowVersion
            }));
            return 0;
        }
        catch (Exception ex)
        {
            try { await tx.RollbackAsync(); } catch { }
            Console.Error.WriteLine($"FlowPublish error: {ex.Message}");
            throw;
        }
    }

    public static async Task<int> FlowList(string connStr)
    {
        await using var conn = new NpgsqlConnection(connStr);
        await conn.OpenAsync();

        await using var cmd = new NpgsqlCommand(
            "SELECT flow_name, flow_version, status, is_active, published_at FROM workflow.flow_versions ORDER BY flow_name, flow_version", conn);
        await using var reader = await cmd.ExecuteReaderAsync();

        var items = new JsonArray();
        while (await reader.ReadAsync())
        {
            items.Add(new JsonObject
            {
                ["flowName"] = reader.GetString(0),
                ["flowVersion"] = reader.GetInt32(1),
                ["status"] = reader.GetString(2),
                ["isActive"] = reader.GetBoolean(3),
                ["publishedAt"] = reader.GetDateTime(4).ToString("o")
            });
        }

        WriteEnvelope(Ok(new JsonObject { ["items"] = items }));
        return 0;
    }

    public static async Task<int> FlowActivate(string connStr, string[] args)
    {
        var flowName = args[2];
        var versionStr = ParseNamedArg(args, "--version");

        if (string.IsNullOrEmpty(flowName) || string.IsNullOrEmpty(versionStr) || !int.TryParse(versionStr, out var version) || version < 1)
        {
            WriteEnvelope(Error("request.invalid", "usage: flow activate <flow> --version <v>"));
            return 1;
        }

        await using var conn = new NpgsqlConnection(connStr);
        await conn.OpenAsync();
        await using var tx = await conn.BeginTransactionAsync();

        try
        {
            // Verify version exists
            await using var checkCmd = new NpgsqlCommand(
                "SELECT 1 FROM workflow.flow_versions WHERE flow_name = @n AND flow_version = @v", conn, tx);
            checkCmd.Parameters.AddWithValue("n", flowName);
            checkCmd.Parameters.AddWithValue("v", version);
            var exists = await checkCmd.ExecuteScalarAsync();

            if (exists is null)
            {
                await tx.RollbackAsync();
                WriteEnvelope(Error("flow.not_found", $"flow {flowName} v{version} not found"));
                return 1;
            }

            // Deactivate existing active version
            await using var deactCmd = new NpgsqlCommand(
                "UPDATE workflow.flow_versions SET is_active = false WHERE flow_name = @n AND is_active = true", conn, tx);
            deactCmd.Parameters.AddWithValue("n", flowName);
            await deactCmd.ExecuteNonQueryAsync();

            // Activate target version
            await using var actCmd = new NpgsqlCommand(
                "UPDATE workflow.flow_versions SET is_active = true WHERE flow_name = @n AND flow_version = @v", conn, tx);
            actCmd.Parameters.AddWithValue("n", flowName);
            actCmd.Parameters.AddWithValue("v", version);
            await actCmd.ExecuteNonQueryAsync();

            await tx.CommitAsync();

            WriteEnvelope(Ok(new JsonObject
            {
                ["resource"] = "flow",
                ["operation"] = "activated",
                ["flowName"] = flowName,
                ["flowVersion"] = version
            }));
            return 0;
        }
        catch
        {
            try { await tx.RollbackAsync(); } catch { }
            throw;
        }
    }

    public static async Task<int> FlowStart(string connStr, string[] args)
    {
        var flowName = args[2];
        var businessKey = ParseNamedArg(args, "--business-key");
        var dataPath = ParseNamedArg(args, "--data");

        if (string.IsNullOrEmpty(flowName) || string.IsNullOrEmpty(businessKey))
        {
            WriteEnvelope(Error("request.invalid", "usage: flow start <flow> --business-key <key> [--data <file>]"));
            return 1;
        }

        string dataJson = "{}";
        if (!string.IsNullOrEmpty(dataPath))
        {
            if (dataPath == "/dev/stdin" || dataPath == "-")
            {
                dataJson = await Console.In.ReadToEndAsync();
            }
            else
            {
                if (!File.Exists(dataPath))
                {
                    WriteEnvelope(Error("request.invalid", $"data file not found: {dataPath}"));
                    return 1;
                }
                dataJson = await File.ReadAllTextAsync(dataPath);
            }
        }

        await using var conn = new NpgsqlConnection(connStr);
        await conn.OpenAsync();

        await using var cmd = new NpgsqlCommand(
            "SELECT workflow.start_process(@n, @k, @d::jsonb)", conn);
        cmd.Parameters.AddWithValue("n", flowName);
        cmd.Parameters.AddWithValue("k", businessKey);
        cmd.Parameters.AddWithValue("d", dataJson);

        var resultJson = await cmd.ExecuteScalarAsync() as string;
        if (resultJson is null)
        {
            WriteEnvelope(Error("internal.error", "workflow.start_process returned null"));
            return 1;
        }

        var node = JsonNode.Parse(resultJson)?.AsObject();
        if (node is null)
        {
            WriteEnvelope(Error("internal.error", "invalid result from workflow.start_process"));
            return 1;
        }

        var status = node["status"]?.GetValue<string>();
        if (status == "error")
        {
            var code = node["code"]?.GetValue<string>() ?? "internal.error";
            var msg = node["message"]?.GetValue<string>() ?? "error";
            WriteEnvelope(Error(code, msg));
            return 1;
        }

        WriteEnvelope(Ok(new JsonObject
        {
            ["resource"] = "process",
            ["operation"] = "started",
            ["processId"] = node["processId"]?.GetValue<string>(),
            ["flowName"] = node["flowName"]?.GetValue<string>(),
            ["flowVersion"] = node["flowVersion"]?.GetValue<int>(),
            ["state"] = node["state"]?.GetValue<string>()
        }));
        return 0;
    }

    public static async Task<int> FlowGet(string connStr, string processIdText)
    {
        if (!Guid.TryParse(processIdText, out var processId))
        {
            WriteEnvelope(Error("request.invalid", "processId must be a valid UUID"));
            return 1;
        }

        await using var conn = new NpgsqlConnection(connStr);
        await conn.OpenAsync();

        await using var cmd = new NpgsqlCommand(
            "SELECT process_id, flow_name, flow_version, state, current_step_key FROM workflow.process_instances WHERE process_id = @id", conn);
        cmd.Parameters.AddWithValue("id", processId);

        await using var reader = await cmd.ExecuteReaderAsync();
        if (!await reader.ReadAsync())
        {
            WriteEnvelope(Error("process.not_found", $"process {processIdText} not found"));
            return 1;
        }

        var id = reader.GetGuid(0).ToString();
        var flowName = reader.GetString(1);
        var flowVersion = reader.GetInt32(2);
        var state = reader.GetString(3);
        var currentStepKey = reader.IsDBNull(4) ? null : reader.GetString(4);

        WriteEnvelope(Ok(new JsonObject
        {
            ["resource"] = "process",
            ["processId"] = id,
            ["flowName"] = flowName,
            ["flowVersion"] = flowVersion,
            ["state"] = state,
            ["currentStepKey"] = currentStepKey
        }));
        return 0;
    }

    public static async Task<int> FlowSignal(string connStr, string[] args)
    {
        var processIdText = args[2];
        var signalType = ParseNamedArg(args, "--type");
        var messageId = ParseNamedArg(args, "--message-id");
        var payloadPath = ParseNamedArg(args, "--payload");

        if (!Guid.TryParse(processIdText, out var processId) || string.IsNullOrEmpty(signalType) || string.IsNullOrEmpty(messageId) || string.IsNullOrEmpty(payloadPath))
        {
            WriteEnvelope(Error("request.invalid", "usage: flow signal <process-id> --type <type> --message-id <id> --payload <file>"));
            return 1;
        }

        string payloadText;
        if (payloadPath == "/dev/stdin" || payloadPath == "-")
        {
            payloadText = await Console.In.ReadToEndAsync();
        }
        else
        {
            if (!File.Exists(payloadPath))
            {
                WriteEnvelope(Error("request.invalid", $"payload file not found: {payloadPath}"));
                return 1;
            }
            payloadText = await File.ReadAllTextAsync(payloadPath);
        }
        var bodyHash = CliHelpers.Sha256Hex(payloadText);

        await using var conn = new NpgsqlConnection(connStr);
        await conn.OpenAsync();

        await using var cmd = new NpgsqlCommand(
            "SELECT workflow.accept_signal(@pid, @type, @mid, @body::jsonb, @hash)", conn);
        cmd.Parameters.AddWithValue("pid", processId);
        cmd.Parameters.AddWithValue("type", signalType);
        cmd.Parameters.AddWithValue("mid", messageId);
        cmd.Parameters.AddWithValue("body", payloadText);
        cmd.Parameters.AddWithValue("hash", bodyHash);

        var resultJson = await cmd.ExecuteScalarAsync() as string;
        if (resultJson is null)
        {
            WriteEnvelope(Error("internal.error", "workflow.accept_signal returned null"));
            return 1;
        }

        var node = JsonNode.Parse(resultJson)?.AsObject();
        if (node is null)
        {
            WriteEnvelope(Error("internal.error", "invalid result from workflow.accept_signal"));
            return 1;
        }

        var status = node["status"]?.GetValue<string>();
        if (status == "error")
        {
            var code = node["code"]?.GetValue<string>() ?? "internal.error";
            var msg = node["message"]?.GetValue<string>() ?? "error";
            WriteEnvelope(Error(code, msg));
            return 1;
        }

        WriteEnvelope(Ok(new JsonObject
        {
            ["resource"] = "signal",
            ["processId"] = node["processId"]?.GetValue<string>(),
            ["messageId"] = node["messageId"]?.GetValue<string>(),
            ["signalType"] = node["signalType"]?.GetValue<string>(),
            ["status"] = node["signalStatus"]?.GetValue<string>() ?? node["status"]?.GetValue<string>()
        }));
        return 0;
    }

    public static async Task<int> FlowTestFinish(string connStr, string[] args)
    {
        var testProfile = Environment.GetEnvironmentVariable("COURSE_TEST_PROFILE") == "1";
        if (!testProfile)
        {
            WriteEnvelope(Error("access.denied", "test-finish command is only available when COURSE_TEST_PROFILE=1"));
            return 1;
        }

        var jobIdText = args[2];
        var owner = ParseNamedArg(args, "--owner");
        var leaseVersionStr = ParseNamedArg(args, "--lease-version");
        var outcome = ParseNamedArg(args, "--outcome");
        var resultPath = ParseNamedArg(args, "--result");

        if (!Guid.TryParse(jobIdText, out var jobId) || string.IsNullOrEmpty(owner) || string.IsNullOrEmpty(leaseVersionStr) || !long.TryParse(leaseVersionStr, out var leaseVersion) || string.IsNullOrEmpty(outcome) || string.IsNullOrEmpty(resultPath))
        {
            WriteEnvelope(Error("request.invalid", "usage: flow test-finish <job-id> --owner <owner> --lease-version <v> --outcome <outcome> --result <file>"));
            return 1;
        }

        string resultText;
        if (resultPath == "/dev/stdin" || resultPath == "-")
        {
            resultText = await Console.In.ReadToEndAsync();
        }
        else
        {
            if (!File.Exists(resultPath))
            {
                WriteEnvelope(Error("request.invalid", $"result file not found: {resultPath}"));
                return 1;
            }
            resultText = await File.ReadAllTextAsync(resultPath);
        }

        await using var conn = new NpgsqlConnection(connStr);
        await conn.OpenAsync();
        await using var tx = await conn.BeginTransactionAsync();

        try
        {
            await using var cmd = new NpgsqlCommand(
                "SELECT workflow.finish_job(@jid, @owner, @lv, @outcome, @res::jsonb)", conn, tx);
            cmd.Parameters.AddWithValue("jid", jobId);
            cmd.Parameters.AddWithValue("owner", owner);
            cmd.Parameters.AddWithValue("lv", leaseVersion);
            cmd.Parameters.AddWithValue("outcome", outcome);
            cmd.Parameters.AddWithValue("res", resultText);

            var finishResult = await cmd.ExecuteScalarAsync() as string;
            await tx.CommitAsync();

            WriteEnvelope(Ok(new JsonObject
            {
                ["resource"] = "job",
                ["operation"] = "finished",
                ["jobId"] = jobIdText
            }));
            return 0;
        }
        catch (PostgresException ex) when (ex.MessageText == "workflow.lease_stale")
        {
            try { await tx.RollbackAsync(); } catch { }
            WriteEnvelope(Error("workflow.lease_stale", "lease is stale or invalid"));
            return 1;
        }
        catch (Exception ex)
        {
            try { await tx.RollbackAsync(); } catch { }
            WriteEnvelope(Error("internal.error", ex.Message));
            return 1;
        }
    }

    public static int? AsInt(JsonNode? node)
    {
        if (node is null) return null;
        if (node is JsonValue val)
        {
            if (val.TryGetValue<int>(out var i)) return i;
            if (val.TryGetValue<long>(out var l)) return (int)l;
        }
        if (int.TryParse(node.ToString(), System.Globalization.NumberStyles.Integer, System.Globalization.CultureInfo.InvariantCulture, out var parsed)) return parsed;
        return null;
    }

    private static string? ParseNamedArg(string[] args, string name)
    {
        var idx = Array.IndexOf(args, name);
        return idx >= 0 && idx + 1 < args.Length ? args[idx + 1] : null;
    }

    private static void WriteEnvelope(JsonObject envelope) =>
        Console.WriteLine(envelope.ToJsonString(s_jsonOpts));

    private static JsonObject Ok(JsonObject result) => new()
    {
        ["status"] = "ok",
        ["result"] = result,
        ["meta"] = new JsonObject { ["contractVersion"] = "course-1" }
    };

    private static JsonObject Error(string code, string message) => new()
    {
        ["status"] = "error",
        ["code"] = code,
        ["message"] = message,
        ["meta"] = new JsonObject { ["contractVersion"] = "course-1" }
    };
}
