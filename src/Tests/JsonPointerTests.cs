using System;
using System.Text.Json.Nodes;
using Worker;
using Xunit;

namespace Tests;

public class JsonPointerTests
{
    [Fact]
    public void ParseSegments_Empty_ReturnsEmptyArray()
    {
        Assert.Empty(JsonPointer.ParseSegments(""));
        Assert.Empty(JsonPointer.ParseSegments(null!));
    }

    [Fact]
    public void ParseSegments_Simple_ReturnsExpectedTokens()
    {
        var segments = JsonPointer.ParseSegments("/a/b/c");
        Assert.Equal(new[] { "a", "b", "c" }, segments);
    }

    [Fact]
    public void ParseSegments_EscapedCharacters_UnescapesCorrectly()
    {
        // RFC 6901: ~0 represents '~', ~1 represents '/'
        var segments = JsonPointer.ParseSegments("/a~1b/c~0d");
        Assert.Equal(new[] { "a/b", "c~d" }, segments);
    }

    [Fact]
    public void TryGet_SimpleProperty_ReturnsValue()
    {
        var root = new JsonObject { ["greeting"] = "hello" };
        var (found, val) = JsonPointer.TryGet(root, "/greeting");
        Assert.True(found);
        Assert.Equal("hello", val?.GetValue<string>());
    }

    [Fact]
    public void TryGet_NestedProperty_ReturnsValue()
    {
        var root = new JsonObject
        {
            ["user"] = new JsonObject
            {
                ["profile"] = new JsonObject
                {
                    ["email"] = "test@example.com"
                }
            }
        };
        var (found, val) = JsonPointer.TryGet(root, "/user/profile/email");
        Assert.True(found);
        Assert.Equal("test@example.com", val?.GetValue<string>());
    }

    [Fact]
    public void TryGet_ArrayIndex_ReturnsElement()
    {
        var root = new JsonObject
        {
            ["items"] = new JsonArray { "first", "second", "third" }
        };
        var (found, val) = JsonPointer.TryGet(root, "/items/1");
        Assert.True(found);
        Assert.Equal("second", val?.GetValue<string>());
    }

    [Fact]
    public void TryGet_MissingProperty_ReturnsNotFound()
    {
        var root = new JsonObject { ["a"] = 1 };
        var (found, val) = JsonPointer.TryGet(root, "/b");
        Assert.False(found);
        Assert.Null(val);
    }

    [Fact]
    public void TryGet_ArrayOutOfBounds_ReturnsNotFound()
    {
        var root = new JsonObject
        {
            ["items"] = new JsonArray { "first" }
        };
        var (found, val) = JsonPointer.TryGet(root, "/items/5");
        Assert.False(found);
        Assert.Null(val);
    }

    [Theory]
    [InlineData("{\"value\":null}", "/value")]
    [InlineData("{\"items\":[null]}", "/items/0")]
    public void Mapping_PreservesExistingNull(string source, string pointer)
    {
        var (found, value) = JsonPointer.TryGet(JsonNode.Parse(source), pointer);
        Assert.True(found);
        var payload = new JsonObject();
        JsonPointer.Set(payload, "/nested/value", value);
        Assert.Equal("{\"nested\":{\"value\":null}}", payload.ToJsonString());
    }

    [Fact]
    public void Set_SetsSimpleProperty()
    {
        var root = new JsonObject();
        JsonPointer.Set(root, "/message", "world");
        Assert.Equal("world", root["message"]?.GetValue<string>());
    }

    [Fact]
    public void Set_CreatesIntermediateObjects()
    {
        var root = new JsonObject();
        JsonPointer.Set(root, "/data/deep/key", 42);
        Assert.Equal(42, root["data"]?["deep"]?["key"]?.GetValue<int>());
    }

    [Fact]
    public void Set_OverwritesExistingValue()
    {
        var root = new JsonObject { ["status"] = "old" };
        JsonPointer.Set(root, "/status", "new");
        Assert.Equal("new", root["status"]?.GetValue<string>());
    }

    [Fact]
    public void Set_EmptyPointer_ThrowsArgumentException()
    {
        var root = new JsonObject();
        Assert.Throws<ArgumentException>(() => JsonPointer.Set(root, "", "test"));
    }
}
