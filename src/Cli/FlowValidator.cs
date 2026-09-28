using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using Json.Schema;
using Npgsql;

namespace Cli;

public static class FlowValidator
{
    private static readonly Lazy<JsonSchema> s_flowSchema = new(() =>
    {
        using var stream = typeof(FlowValidator).Assembly.GetManifestResourceStream("workflow-map.schema.json")
            ?? throw new InvalidOperationException("Embedded schema workflow-map.schema.json not found");
        using var reader = new StreamReader(stream);
        return JsonSchema.FromText(reader.ReadToEnd());
    });

    public static JsonSchema FlowSchema => s_flowSchema.Value;

    public static (bool valid, string message) ValidateMapSchema(JsonNode mapNode)
    {
        var result = FlowSchema.Evaluate(mapNode, new EvaluationOptions
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
            var msg = errors.Count > 0 ? string.Join("; ", errors.Take(5)) : "workflow map does not match schema";
            return (false, msg);
        }

        return (true, "ok");
    }

    public static (bool valid, string message) ValidateMapGraph(JsonNode mapNode)
    {
        var startStep = mapNode["start_step"]?.GetValue<string>();
        var stepsArray = mapNode["steps"]?.AsArray();
        var transArray = mapNode["transitions"]?.AsArray();

        if (string.IsNullOrEmpty(startStep) || stepsArray is null || transArray is null)
        {
            return (false, "missing start_step, steps, or transitions");
        }

        var stepsByKey = new Dictionary<string, JsonNode>(StringComparer.Ordinal);
        foreach (var s in stepsArray)
        {
            if (s is null) continue;
            var key = s["key"]?.GetValue<string>();
            if (string.IsNullOrEmpty(key)) return (false, "step missing key");
            if (stepsByKey.ContainsKey(key))
            {
                return (false, $"duplicate step key: {key}");
            }
            stepsByKey[key] = s;
        }

        if (!stepsByKey.ContainsKey(startStep))
        {
            return (false, $"start_step '{startStep}' not found in steps");
        }

        // Validate individual step rules
        foreach (var (key, step) in stepsByKey)
        {
            var type = step["type"]?.GetValue<string>();
            if (type == "automatic")
            {
                var task = step["task"];
                if (task is null) return (false, $"step '{key}' missing task");

                var retry = task["retry"];
                if (retry is not null)
                {
                    var maxAttempts = AsInt(retry["max_attempts"]) ?? 1;
                    var delays = retry["delays_ms"]?.AsArray();
                    int delayCount = delays?.Count ?? 0;
                    if (delayCount != maxAttempts - 1)
                    {
                        return (false, $"step '{key}' invalid retry: max_attempts={maxAttempts} requires {maxAttempts - 1} delays, got {delayCount}");
                    }
                }

                // Overlapping targets make the payload depend on assignment order.
                var mapping = task["input_mapping"]?.AsObject();
                var constants = task["input_constants"]?.AsObject();

                var targetPointers = new List<string>();
                if (mapping is not null)
                {
                    foreach (var (targetPtr, _) in mapping)
                    {
                        if (!targetPtr.StartsWith('/'))
                            return (false, $"step '{key}' input_mapping key must start with '/': {targetPtr}");
                        targetPointers.Add(targetPtr);
                    }
                }

                // Overlap among mapping target pointers
                for (int i = 0; i < targetPointers.Count; i++)
                {
                    for (int j = i + 1; j < targetPointers.Count; j++)
                    {
                        if (PointersOverlap(targetPointers[i], targetPointers[j]))
                        {
                            return (false, $"step '{key}' overlapping mapping target pointers: {targetPointers[i]} and {targetPointers[j]}");
                        }
                    }
                }

                // Overlap between mapping targets and constants
                if (constants is not null)
                {
                    foreach (var (constKey, _) in constants)
                    {
                        var constPtr = "/" + constKey.Replace("~", "~0").Replace("/", "~1");
                        foreach (var targetPtr in targetPointers)
                        {
                            if (PointersOverlap(targetPtr, constPtr))
                            {
                                return (false, $"step '{key}' mapping target pointer {targetPtr} overlaps with constant {constKey}");
                            }
                        }
                    }
                }
            }
        }

        // Transitions validation
        var transitionsFrom = new Dictionary<string, List<(string outcome, string to)>>(StringComparer.Ordinal);
        var transitionsTo = new Dictionary<string, List<string>>(StringComparer.Ordinal);

        foreach (var key in stepsByKey.Keys)
        {
            transitionsFrom[key] = new();
            transitionsTo[key] = new();
        }

        var seenTransitions = new HashSet<(string from, string outcome)>();

        foreach (var t in transArray)
        {
            if (t is null) continue;
            var from = t["from"]?.GetValue<string>();
            var outcome = t["outcome"]?.GetValue<string>();
            var to = t["to"]?.GetValue<string>();

            if (string.IsNullOrEmpty(from) || string.IsNullOrEmpty(outcome) || string.IsNullOrEmpty(to))
                return (false, "transition missing from, outcome, or to");

            if (!stepsByKey.ContainsKey(from)) return (false, $"transition from unknown step: {from}");
            if (!stepsByKey.ContainsKey(to)) return (false, $"transition to unknown step: {to}");

            var fromStepType = stepsByKey[from]["type"]?.GetValue<string>();
            if (fromStepType == "end")
            {
                return (false, $"transition from end step '{from}' is not allowed");
            }

            if (!seenTransitions.Add((from, outcome)))
            {
                return (false, $"duplicate transition outcome '{outcome}' from step '{from}'");
            }

            transitionsFrom[from].Add((outcome, to));
            transitionsTo[to].Add(from);
        }

        // For wait_signal and manual steps, check transitions coverage
        foreach (var (key, step) in stepsByKey)
        {
            var type = step["type"]?.GetValue<string>();
            if (type == "wait_signal")
            {
                var expectedOutcome = step["outcome"]?.GetValue<string>();
                var trans = transitionsFrom[key];
                if (trans.Count != 1 || trans[0].outcome != expectedOutcome)
                {
                    return (false, $"wait_signal step '{key}' must have exactly one transition with outcome '{expectedOutcome}'");
                }
            }
            else if (type == "manual")
            {
                var allowedOutcomes = step["allowed_outcomes"]?.AsArray()?.Select(x => x?.GetValue<string>()).Where(x => x != null).ToHashSet() ?? [];
                var transOutcomes = transitionsFrom[key].Select(t => t.outcome).ToHashSet();
                if (!allowedOutcomes.SetEquals(transOutcomes) || transitionsFrom[key].Count != allowedOutcomes.Count)
                {
                    return (false, $"manual step '{key}' must have exactly one transition for each allowed_outcome");
                }
            }
            else if (type == "end")
            {
                if (transitionsFrom[key].Count > 0)
                {
                    return (false, $"end step '{key}' cannot have outgoing transitions");
                }
            }
        }

        // Graph Reachability: BFS from start_step
        var reachableFromStart = new HashSet<string>(StringComparer.Ordinal);
        var queue = new Queue<string>();
        queue.Enqueue(startStep);
        reachableFromStart.Add(startStep);

        while (queue.Count > 0)
        {
            var current = queue.Dequeue();
            foreach (var (_, to) in transitionsFrom[current])
            {
                if (reachableFromStart.Add(to))
                {
                    queue.Enqueue(to);
                }
            }
        }

        foreach (var key in stepsByKey.Keys)
        {
            if (!reachableFromStart.Contains(key))
            {
                return (false, $"step '{key}' is unreachable from start_step '{startStep}'");
            }
        }

        // Check reachability to an end step (backward BFS from end steps)
        var endSteps = stepsByKey.Where(kv => kv.Value["type"]?.GetValue<string>() == "end").Select(kv => kv.Key).ToList();
        if (endSteps.Count == 0)
        {
            return (false, "no end step defined in workflow map");
        }

        var canReachEnd = new HashSet<string>(StringComparer.Ordinal);
        var bQueue = new Queue<string>();
        foreach (var e in endSteps)
        {
            canReachEnd.Add(e);
            bQueue.Enqueue(e);
        }

        while (bQueue.Count > 0)
        {
            var current = bQueue.Dequeue();
            foreach (var from in transitionsTo[current])
            {
                if (canReachEnd.Add(from))
                {
                    bQueue.Enqueue(from);
                }
            }
        }

        foreach (var key in stepsByKey.Keys)
        {
            if (!canReachEnd.Contains(key))
            {
                return (false, $"step '{key}' has no path reaching an end step (dead end)");
            }
        }

        // Cycle detection: DFS with coloring (0=white, 1=grey, 2=black)
        var color = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var key in stepsByKey.Keys) color[key] = 0;

        bool HasCycle(string u)
        {
            color[u] = 1; // visiting
            foreach (var (_, v) in transitionsFrom[u])
            {
                if (color[v] == 1) return true; // cycle detected
                if (color[v] == 0 && HasCycle(v)) return true;
            }
            color[u] = 2; // visited
            return false;
        }

        foreach (var key in stepsByKey.Keys)
        {
            if (color[key] == 0)
            {
                if (HasCycle(key))
                {
                    return (false, "workflow map contains a cycle");
                }
            }
        }

        return (true, "ok");
    }

    public static async Task<(bool valid, string message)> ValidateActionsWithDb(
        JsonNode mapNode, NpgsqlConnection conn, NpgsqlTransaction tx)
    {
        var stepsArray = mapNode["steps"]?.AsArray();
        var transArray = mapNode["transitions"]?.AsArray();
        if (stepsArray is null) return (false, "steps array is null");

        // Map transitions by from step
        var transByFrom = new Dictionary<string, List<string>>(StringComparer.Ordinal);
        if (transArray is not null)
        {
            foreach (var t in transArray)
            {
                if (t is null) continue;
                var from = t["from"]?.GetValue<string>();
                var outcome = t["outcome"]?.GetValue<string>();
                if (from is not null && outcome is not null)
                {
                    if (!transByFrom.TryGetValue(from, out var list))
                    {
                        list = new();
                        transByFrom[from] = list;
                    }
                    list.Add(outcome);
                }
            }
        }

        foreach (var step in stepsArray)
        {
            if (step is null) continue;
            var type = step["type"]?.GetValue<string>();
            if (type != "automatic") continue;

            var key = step["key"]?.GetValue<string>()!;
            var task = step["task"];
            if (task is null) return (false, $"step '{key}' missing task");

            var module = task["module"]?.GetValue<string>();
            var action = task["action"]?.GetValue<string>();
            var version = AsInt(task["action_version"]);
            var requiredPolicy = task["required_policy"]?.AsArray()?.Select(x => x?.GetValue<string>()).Where(x => x != null).ToHashSet() ?? [];

            if (string.IsNullOrEmpty(module) || string.IsNullOrEmpty(action) || !version.HasValue)
            {
                return (false, $"step '{key}' missing module, action, or action_version");
            }

            await using var cmd = new NpgsqlCommand(
                "SELECT enabled, outcomes, required_policy FROM catalog.actions WHERE module=@m AND action=@a AND version=@v", conn, tx);
            cmd.Parameters.AddWithValue("m", module);
            cmd.Parameters.AddWithValue("a", action);
            cmd.Parameters.AddWithValue("v", version.Value);

            await using var reader = await cmd.ExecuteReaderAsync();
            if (!await reader.ReadAsync())
            {
                await reader.CloseAsync();
                await using var checkAnyCmd = new NpgsqlCommand(
                    "SELECT COUNT(*) FROM catalog.actions WHERE module=@m AND action=@a", conn, tx);
                checkAnyCmd.Parameters.AddWithValue("m", module);
                checkAnyCmd.Parameters.AddWithValue("a", action);
                var anyCount = (long)(await checkAnyCmd.ExecuteScalarAsync() ?? 0L);
                if (anyCount > 0)
                {
                    return (false, $"action {module}.{action} version {version.Value} not found");
                }
                return (false, $"action {module}.{action} not found");
            }

            var enabled = reader.GetBoolean(0);
            var outcomesJson = reader.GetString(1);
            var policyJson = reader.GetString(2);
            await reader.CloseAsync();

            if (!enabled)
            {
                return (false, $"action {module}.{action} v{version.Value} is disabled");
            }

            var actionOutcomes = JsonSerializer.Deserialize<List<string>>(outcomesJson) ?? [];
            var actionPolicy = (JsonSerializer.Deserialize<List<string>>(policyJson) ?? []).ToHashSet();

            // Policy check: exact set equality
            if (!requiredPolicy.SetEquals(actionPolicy))
            {
                return (false, $"step '{key}' required_policy [{string.Join(", ", requiredPolicy)}] does not match action required_policy [{string.Join(", ", actionPolicy)}]");
            }

            if (!actionPolicy.IsSubsetOf(Course.WorkflowPrincipal.Scopes))
            {
                return (false, $"step '{key}' requires scopes not granted to workflow-worker");
            }

            // Outcomes check: transitions from this step must cover all action outcomes exactly once
            transByFrom.TryGetValue(key, out var stepTransOutcomes);
            stepTransOutcomes ??= new();

            var stepTransSet = stepTransOutcomes.ToHashSet();
            var actionOutcomesSet = actionOutcomes.ToHashSet();

            if (!stepTransSet.SetEquals(actionOutcomesSet) || stepTransOutcomes.Count != actionOutcomes.Count)
            {
                return (false, $"step '{key}' transitions [{string.Join(", ", stepTransOutcomes)}] do not match action outcomes [{string.Join(", ", actionOutcomes)}]");
            }
        }

        return (true, "ok");
    }

    public static bool PointersOverlap(string p1, string p2)
    {
        var seg1 = ParsePointer(p1);
        var seg2 = ParsePointer(p2);
        
        if (seg1.Length == 0 || seg2.Length == 0) return true;
        
        int minLen = Math.Min(seg1.Length, seg2.Length);
        for (int i = 0; i < minLen; i++)
        {
            if (seg1[i] != seg2[i]) return false;
        }
        return true;
    }

    private static string[] ParsePointer(string p)
    {
        if (string.IsNullOrEmpty(p)) return [];
        if (p.StartsWith('/')) p = p[1..];
        var parts = p.Split('/');
        for (int i = 0; i < parts.Length; i++)
        {
            parts[i] = parts[i].Replace("~1", "/").Replace("~0", "~");
        }
        return parts;
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
}
