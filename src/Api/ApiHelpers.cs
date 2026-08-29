using System;
using System.IdentityModel.Tokens.Jwt;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.IdentityModel.Tokens;
using Npgsql;
using System.Collections.Generic;
using System.Linq;

namespace Api;

public static class ApiHelpers
{
    public static bool IsTransientDatabaseError(Exception ex) => ex switch
    {
        PostgresException => false,
        NpgsqlException npgsql => npgsql.InnerException is System.Net.Sockets.SocketException
            or System.IO.IOException or TimeoutException,
        System.Net.Sockets.SocketException or System.IO.IOException or TimeoutException => true,
        _ when ex.InnerException is not null => IsTransientDatabaseError(ex.InnerException),
        _ => false
    };

    public static (string? principal, string? consumer, List<string>? scopes, string? error) ValidateJwt(
        string token, TokenValidationParameters tokenValidationParams, JwtSecurityTokenHandler jwtHandler)
    {
        if (string.IsNullOrEmpty(token))
            return (null, null, null, "empty token");

        try
        {
            jwtHandler.ValidateToken(token, tokenValidationParams, out var validatedToken);

            if (validatedToken is not JwtSecurityToken jwt)
                return (null, null, null, "invalid token type");

            var issClaim = jwt.Payload["iss"];
            if (issClaim is not string)
                return (null, null, null, "iss claim must be a string");

            if (!jwt.Payload.TryGetValue("aud", out var audClaim) || audClaim is not string)
                return (null, null, null, "aud claim must be a string");
            if (!jwt.Payload.TryGetValue("iat", out var iatClaim) || iatClaim is not (long or int or double or JsonElement { ValueKind: JsonValueKind.Number }))
                return (null, null, null, "iat claim must be a number");
            if (!jwt.Payload.TryGetValue("exp", out var expClaim) || expClaim is not (long or int or double or JsonElement { ValueKind: JsonValueKind.Number }))
                return (null, null, null, "exp claim must be a number");

            var parts = token.Split('.');
            if (parts.Length != 3) return (null, null, null, "invalid token format");
            
            var payloadJson = Base64UrlEncoder.Decode(parts[1]);
            var rawNode = JsonNode.Parse(payloadJson);
            if (rawNode?["sub"] is not JsonValue subVal || !subVal.TryGetValue<string>(out _) || subVal.GetValue<JsonElement>().ValueKind != JsonValueKind.String)
                return (null, null, null, "sub claim must be a non-empty string");

            var sub = subVal.GetValue<string>();
            if (string.IsNullOrEmpty(sub))
                return (null, null, null, "sub claim is required");

            var consumerClaim = jwt.Payload.TryGetValue("consumer", out var consumerObj) ? consumerObj : null;
            if (consumerClaim is not string consumerStr || string.IsNullOrEmpty(consumerStr))
                return (null, null, null, "consumer claim must be a non-empty string");

            var scopeClaim = jwt.Payload.TryGetValue("scope", out var scopeObj) ? scopeObj : null;
            if (scopeClaim is not string scopeStr)
                return (null, null, null, "scope claim must be a string");

            var scopes = string.IsNullOrWhiteSpace(scopeStr)
                ? new List<string>()
                : scopeStr.Split(' ', StringSplitOptions.RemoveEmptyEntries).ToList();

            return (sub, consumerStr, scopes, null);
        }
        catch (SecurityTokenExpiredException)
        {
            return (null, null, null, "token expired");
        }
        catch (SecurityTokenInvalidSignatureException)
        {
            return (null, null, null, "invalid signature");
        }
        catch (Exception)
        {
            return (null, null, null, "invalid token");
        }
    }
}
