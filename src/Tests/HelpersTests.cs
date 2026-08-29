using System;
using System.IO;
using System.Net.Sockets;
using System.Text.Json.Nodes;
using Api;
using Cli;
using Npgsql;
using Xunit;

namespace Tests;

public class HelpersTests
{
    [Fact]
    public void Sha256Hex_ReturnsCorrectCanonicalHash()
    {
        var json = "{\"a\": 1}";
        var hash = CliHelpers.Sha256Hex(json);
        Assert.NotNull(hash);
        Assert.Equal(64, hash.Length);
        Assert.Matches("^[0-9a-f]{64}$", hash);
    }

    [Fact]
    public void ValidateManifest_ValidManifest_ReturnsTrue()
    {
        var json = """
        {
          "contract_version": "course-1",
          "module": "payment",
          "action": "request",
          "version": 1,
          "http_method": "POST",
          "target_schema": "payment",
          "target_function": "request_v1",
          "request_schema": {
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "type": "object"
          },
          "response_schema": {
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "type": "object"
          },
          "outcomes": ["CREATED"],
          "required_policy": ["payment:write"],
          "idempotency_mode": "required",
          "idempotency_scope": "principal_action",
          "timeout_ms": 2000,
          "enabled": true,
          "is_default": true
        }
        """;

        var (valid, message, manifest) = CliHelpers.ValidateManifestContent(json);
        Assert.True(valid, $"Validation failed: {message}");
        Assert.Equal("ok", message);
        Assert.NotNull(manifest);
    }

    [Fact]
    public void ValidateManifest_InvalidContractVersion_ReturnsFalse()
    {
        var json = """
        {
          "contract_version": "invalid-version",
          "module": "payment",
          "action": "request",
          "version": 1,
          "http_method": "POST",
          "target_schema": "payment",
          "target_function": "request_v1",
          "request_schema": {
            "$schema": "https://json-schema.org/draft/2020-12/schema"
          },
          "response_schema": {
            "$schema": "https://json-schema.org/draft/2020-12/schema"
          },
          "outcomes": ["CREATED"],
          "required_policy": ["payment:write"],
          "idempotency_mode": "none",
          "idempotency_scope": "none",
          "timeout_ms": 1000,
          "enabled": true,
          "is_default": false
        }
        """;

        var (valid, message, _) = CliHelpers.ValidateManifestContent(json);
        Assert.False(valid);
        Assert.NotEmpty(message);
    }

    [Fact]
    public void ValidateManifest_MissingRequiredProperties_ReturnsFalse()
    {
        var json = """
        {
          "contract_version": "course-1",
          "action": "request"
        }
        """;

        var (valid, message, _) = CliHelpers.ValidateManifestContent(json);
        Assert.False(valid);
        Assert.NotEmpty(message);
    }

    [Fact]
    public void ValidateManifest_InvalidTypes_ReturnsFalse()
    {
        var json = """
        {
          "contract_version": "course-1",
          "module": "payment",
          "action": "request",
          "version": "not-a-number",
          "http_method": "POST",
          "target_schema": "payment",
          "target_function": "request_v1",
          "request_schema": {
            "$schema": "https://json-schema.org/draft/2020-12/schema"
          },
          "response_schema": {
            "$schema": "https://json-schema.org/draft/2020-12/schema"
          },
          "outcomes": ["CREATED"],
          "required_policy": ["payment:write"],
          "idempotency_mode": "none",
          "idempotency_scope": "none",
          "timeout_ms": "fast",
          "enabled": true,
          "is_default": false
        }
        """;

        var (valid, message, _) = CliHelpers.ValidateManifestContent(json);
        Assert.False(valid);
        Assert.NotEmpty(message);
    }

    [Fact]
    public void ValidateManifest_InvalidEnum_ReturnsFalse()
    {
        var json = """
        {
          "contract_version": "course-1",
          "module": "payment",
          "action": "request",
          "version": 1,
          "http_method": "POST",
          "target_schema": "payment",
          "target_function": "request_v1",
          "request_schema": {
            "$schema": "https://json-schema.org/draft/2020-12/schema"
          },
          "response_schema": {
            "$schema": "https://json-schema.org/draft/2020-12/schema"
          },
          "outcomes": ["CREATED"],
          "required_policy": ["payment:write"],
          "idempotency_mode": "unsupported_mode",
          "idempotency_scope": "none",
          "timeout_ms": 1000,
          "enabled": true,
          "is_default": false
        }
        """;

        var (valid, message, _) = CliHelpers.ValidateManifestContent(json);
        Assert.False(valid);
        Assert.NotEmpty(message);
    }

    [Fact]
    public void IsTransientDatabaseError_CorrectlyMapsExceptions()
    {
        var timeoutEx = new TimeoutException();
        Assert.True(ApiHelpers.IsTransientDatabaseError(timeoutEx));

        var socketEx = new SocketException();
        Assert.True(ApiHelpers.IsTransientDatabaseError(socketEx));

        var ioEx = new IOException();
        Assert.True(ApiHelpers.IsTransientDatabaseError(ioEx));

        var npgsqlTransient = new NpgsqlException("wrapper", timeoutEx);
        Assert.True(ApiHelpers.IsTransientDatabaseError(npgsqlTransient));

        var postgresEx = new PostgresException("42501", "error", "detail", "sqlState");
        Assert.False(ApiHelpers.IsTransientDatabaseError(postgresEx));
        
        var randomEx = new InvalidOperationException("random");
        Assert.False(ApiHelpers.IsTransientDatabaseError(randomEx));
    }
}
