using System.Collections.Frozen;

namespace Course;

internal static class WorkflowPrincipal
{
    internal static readonly FrozenSet<string> Scopes =
        new[] { "workflow:execute", "payment:internal" }.ToFrozenSet(StringComparer.Ordinal);
}
