using System.Text.Json.Nodes;
using Cli;
using Xunit;

namespace Tests;

public class FlowValidatorTests
{
    [Theory]
    [InlineData("/a", "/a", true)]
    [InlineData("/a", "/a/b", true)]
    [InlineData("/a/b", "/a", true)]
    [InlineData("/a", "/b", false)]
    [InlineData("/a", "/ab", false)]
    [InlineData("/ab", "/a", false)]
    [InlineData("/user/address/city", "/user/address", true)]
    [InlineData("/user/address", "/user/name", false)]
    public void PointersOverlap_ReturnsExpectedResult(string p1, string p2, bool expected)
    {
        Assert.Equal(expected, FlowValidator.PointersOverlap(p1, p2));
    }

    [Fact]
    public void ValidateMapGraph_ValidGraph_ReturnsTrue()
    {
        var json = """
        {
          "flow_name": "test-flow",
          "flow_version": 1,
          "start_step": "step1",
          "steps": [
            {
              "key": "step1",
              "type": "automatic",
              "task": {
                "service": "postgres",
                "module": "payment",
                "action": "request",
                "action_version": 1,
                "required_policy": ["payment:write"],
                "timeout_ms": 2000,
                "retry": {
                  "max_attempts": 3,
                  "delays_ms": [100, 200]
                },
                "input_constants": {},
                "input_mapping": {}
              }
            },
            {
              "key": "step2",
              "type": "end",
              "end": {
                "outcome": "SUCCESS"
              }
            }
          ],
          "transitions": [
            {
              "from": "step1",
              "outcome": "CREATED",
              "to": "step2"
            }
          ]
        }
        """;

        var node = JsonNode.Parse(json)!;
        var (valid, msg) = FlowValidator.ValidateMapGraph(node);
        Assert.True(valid, $"Validation failed unexpectedly: {msg}");
        Assert.Equal("ok", msg);
    }

    [Fact]
    public void ValidateMapGraph_CycleDetected_ReturnsFalse()
    {
        var json = """
        {
          "flow_name": "test-flow",
          "flow_version": 1,
          "start_step": "step1",
          "steps": [
            {
              "key": "step1",
              "type": "automatic",
              "task": {
                "service": "postgres",
                "module": "test",
                "action": "action1",
                "action_version": 1,
                "required_policy": [],
                "timeout_ms": 1000,
                "retry": { "max_attempts": 1, "delays_ms": [] },
                "input_constants": {},
                "input_mapping": {}
              }
            },
            {
              "key": "step2",
              "type": "automatic",
              "task": {
                "service": "postgres",
                "module": "test",
                "action": "action2",
                "action_version": 1,
                "required_policy": [],
                "timeout_ms": 1000,
                "retry": { "max_attempts": 1, "delays_ms": [] },
                "input_constants": {},
                "input_mapping": {}
              }
            },
            {
              "key": "endStep",
              "type": "end",
              "end": { "outcome": "DONE" }
            }
          ],
          "transitions": [
            { "from": "step1", "outcome": "NEXT", "to": "step2" },
            { "from": "step2", "outcome": "LOOP", "to": "step1" },
            { "from": "step2", "outcome": "DONE", "to": "endStep" }
          ]
        }
        """;

        var node = JsonNode.Parse(json)!;
        var (valid, msg) = FlowValidator.ValidateMapGraph(node);
        Assert.False(valid);
        Assert.Contains("cycle", msg.ToLowerInvariant());
    }

    [Fact]
    public void ValidateMapGraph_MissingEndStep_ReturnsFalse()
    {
        var json = """
        {
          "flow_name": "test-flow",
          "flow_version": 1,
          "start_step": "step1",
          "steps": [
            {
              "key": "step1",
              "type": "automatic",
              "task": {
                "service": "postgres",
                "module": "test",
                "action": "action1",
                "action_version": 1,
                "required_policy": [],
                "timeout_ms": 1000,
                "retry": { "max_attempts": 1, "delays_ms": [] },
                "input_constants": {},
                "input_mapping": {}
              }
            }
          ],
          "transitions": []
        }
        """;

        var node = JsonNode.Parse(json)!;
        var (valid, msg) = FlowValidator.ValidateMapGraph(node);
        Assert.False(valid);
        Assert.Contains("end", msg.ToLowerInvariant());
    }

    [Fact]
    public void ValidateMapGraph_TransitionFromEnd_ReturnsFalse()
    {
        var json = """
        {
          "flow_name": "test-flow",
          "flow_version": 1,
          "start_step": "step1",
          "steps": [
            {
              "key": "step1",
              "type": "end",
              "end": { "outcome": "DONE" }
            },
            {
              "key": "step2",
              "type": "end",
              "end": { "outcome": "DONE" }
            }
          ],
          "transitions": [
            { "from": "step1", "outcome": "ANY", "to": "step2" }
          ]
        }
        """;

        var node = JsonNode.Parse(json)!;
        var (valid, msg) = FlowValidator.ValidateMapGraph(node);
        Assert.False(valid);
        Assert.Contains("transition from end", msg.ToLowerInvariant());
    }

    [Fact]
    public void ValidateMapGraph_UnreachableStep_ReturnsFalse()
    {
        var json = """
        {
          "flow_name": "test-flow",
          "flow_version": 1,
          "start_step": "step1",
          "steps": [
            {
              "key": "step1",
              "type": "end",
              "end": { "outcome": "DONE" }
            },
            {
              "key": "orphan",
              "type": "end",
              "end": { "outcome": "DONE" }
            }
          ],
          "transitions": []
        }
        """;

        var node = JsonNode.Parse(json)!;
        var (valid, msg) = FlowValidator.ValidateMapGraph(node);
        Assert.False(valid);
        Assert.Contains("unreachable", msg.ToLowerInvariant());
    }

    [Fact]
    public void ValidateMapGraph_DuplicateStepKey_ReturnsFalse()
    {
        var json = """
        {
          "flow_name": "test-flow",
          "flow_version": 1,
          "start_step": "dup",
          "steps": [
            {
              "key": "dup",
              "type": "end",
              "end": { "outcome": "DONE" }
            },
            {
              "key": "dup",
              "type": "end",
              "end": { "outcome": "DONE2" }
            }
          ],
          "transitions": []
        }
        """;

        var node = JsonNode.Parse(json)!;
        var (valid, msg) = FlowValidator.ValidateMapGraph(node);
        Assert.False(valid);
        Assert.Contains("duplicate", msg.ToLowerInvariant());
    }
}