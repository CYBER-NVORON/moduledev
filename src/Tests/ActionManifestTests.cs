using Xunit;
using System.Collections.Generic;

namespace Tests;

public class ActionManifestTests
{
    [Fact]
    public void Record_CanBeConstructed()
    {
        var manifest = new ActionManifest(
            Version: 1,
            TargetSchema: "payment",
            TargetFunction: "request_v1",
            Outcomes: new List<string> { "CREATED" },
            RequiredPolicy: new List<string> { "payment:write" },
            IdempotencyMode: "required",
            IdempotencyScope: "principal_action",
            TimeoutMs: 5000,
            RequestSchema: null,
            ResponseSchema: null
        );

        Assert.Equal(1, manifest.Version);
        Assert.Equal("payment", manifest.TargetSchema);
        Assert.Equal("request_v1", manifest.TargetFunction);
        Assert.Equal(5000, manifest.TimeoutMs);
        Assert.Contains("CREATED", manifest.Outcomes);
        Assert.Contains("payment:write", manifest.RequiredPolicy);
        Assert.Equal("required", manifest.IdempotencyMode);
        Assert.Equal("principal_action", manifest.IdempotencyScope);
    }

    [Fact]
    public void ActionInfo_CanBeConstructed()
    {
        var info = new ActionInfo("payment", "request", 1, "{}", true, true);
        Assert.Equal("payment", info.Module);
        Assert.Equal("request", info.Action);
        Assert.Equal(1, info.Version);
        Assert.True(info.Enabled);
        Assert.True(info.IsDefault);
    }
}
