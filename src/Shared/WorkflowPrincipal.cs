using System.Collections.Frozen;

namespace Course;

internal static class WorkflowPrincipal
{
    // Shared by publication validation and execution; manifests cannot expand these scopes.
    internal static readonly FrozenSet<string> Scopes =
        new[] { "workflow:execute", "payment:internal" }.ToFrozenSet(StringComparer.Ordinal);
}
