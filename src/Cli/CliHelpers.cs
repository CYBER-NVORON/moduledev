using System;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Json.Schema;

namespace Cli;

public static class CliHelpers
{
    private static readonly Lazy<JsonSchema> s_manifestSchema = new(() =>
    {
        using var stream = typeof(CliHelpers).Assembly.GetManifestResourceStream("action-manifest.schema.json")
            ?? throw new InvalidOperationException("Embedded schema action-manifest.schema.json not found");
        using var reader = new StreamReader(stream);
        return JsonSchema.FromText(reader.ReadToEnd());
    });

    public static JsonSchema ManifestSchema => s_manifestSchema.Value;

    public static string Sha256Hex(string content)
    {
        var bytes = SHA256.HashData(Encoding.UTF8.GetBytes(content));
        return Convert.ToHexStringLower(bytes);
    }

    public static (bool valid, string message, JsonNode? manifest) ValidateManifest(string path)
    {
        string text;
        try
        {
            text = File.ReadAllText(path);
        }
        catch (Exception ex)
        {
            return (false, "failed to read file: " + ex.Message, null);
        }

        return ValidateManifestContent(text);
    }

    public static (bool valid, string message, JsonNode? manifest) ValidateManifestContent(string jsonText)
    {
        JsonNode? node;
        try
        {
            node = JsonNode.Parse(jsonText);
        }
        catch (JsonException ex)
        {
            return (false, "invalid json: " + ex.Message, null);
        }

        if (node is null) return (false, "empty json", null);

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
            var msg = errors.Count > 0 ? string.Join("; ", errors.Take(5)) : "manifest does not match schema";
            return (false, msg, node);
        }

        // Parse both nested schemas before accepting the manifest.
        try
        {
            if (node["request_schema"] is JsonNode reqNode)
            {
                var reqSchema = JsonSchema.FromText(reqNode.ToJsonString());
                if (reqSchema == null) return (false, "invalid request_schema", node);
            }
            if (node["response_schema"] is JsonNode resNode)
            {
                var resSchema = JsonSchema.FromText(resNode.ToJsonString());
                if (resSchema == null) return (false, "invalid response_schema", node);
            }
        }
        catch (Exception ex)
        {
            return (false, "invalid nested schema: " + ex.Message, node);
        }

        return (true, "ok", node);
    }
}
