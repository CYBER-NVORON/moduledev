using System;
using System.Text.Json.Nodes;

namespace Worker;

public static class JsonPointer
{
    public static string[] ParseSegments(string pointer)
    {
        if (string.IsNullOrEmpty(pointer)) return [];
        if (pointer.StartsWith('/')) pointer = pointer[1..];
        var parts = pointer.Split('/');
        for (int i = 0; i < parts.Length; i++)
        {
            parts[i] = parts[i].Replace("~1", "/").Replace("~0", "~");
        }
        return parts;
    }

    public static (bool found, JsonNode? value) TryGet(JsonNode? root, string pointer)
    {
        if (root is null) return (false, null);
        var segments = ParseSegments(pointer);
        if (segments.Length == 0) return (true, root);

        JsonNode? current = root;
        foreach (var seg in segments)
        {
            if (current is JsonObject obj)
            {
                if (!obj.TryGetPropertyValue(seg, out var child))
                {
                    return (false, null);
                }
                current = child;
            }
            else if (current is JsonArray arr)
            {
                if (!int.TryParse(seg, out var idx) || idx < 0 || idx >= arr.Count)
                {
                    return (false, null);
                }
                current = arr[idx];
            }
            else
            {
                return (false, null);
            }
        }

        return (true, current);
    }

    public static void Set(JsonObject root, string pointer, JsonNode? value)
    {
        var segments = ParseSegments(pointer);
        if (segments.Length == 0)
        {
            throw new ArgumentException("Cannot set root pointer directly on JsonObject", nameof(pointer));
        }

        JsonObject current = root;
        for (int i = 0; i < segments.Length - 1; i++)
        {
            var seg = segments[i];
            if (!current.TryGetPropertyValue(seg, out var child) || child is not JsonObject childObj)
            {
                var newObj = new JsonObject();
                current[seg] = newObj;
                current = newObj;
            }
            else
            {
                current = childObj;
            }
        }

        current[segments[^1]] = value?.DeepClone();
    }
}
