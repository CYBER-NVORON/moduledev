using System;
using System.Collections.Generic;
using System.IdentityModel.Tokens.Jwt;
using System.Security.Claims;
using System.Text;
using System.Text.Json;
using Api;
using Microsoft.IdentityModel.Tokens;
using Xunit;

namespace Tests;

public class JwtTests
{
    private const string TestKey = "this_is_a_very_long_test_signing_key_at_least_32_bytes";
    private readonly SymmetricSecurityKey _signingKey = new(Encoding.UTF8.GetBytes(TestKey));

    private TokenValidationParameters GetDefaultValidationParams(bool validateLifetime = true) => new()
    {
        ValidateIssuer = true,
        ValidIssuer = "test-issuer",
        ValidateAudience = true,
        ValidAudience = "test-audience",
        ValidateLifetime = validateLifetime,
        ValidateIssuerSigningKey = true,
        IssuerSigningKey = _signingKey,
        ClockSkew = TimeSpan.FromSeconds(5)
    };

    private string CreateTokenString(string sub, string consumer, string scope, int expireMinutes = 30, string issuer = "test-issuer", string audience = "test-audience", SymmetricSecurityKey? key = null)
    {
        var creds = new SigningCredentials(key ?? _signingKey, SecurityAlgorithms.HmacSha256);
        var claims = new List<Claim>
        {
            new("sub", sub),
            new("consumer", consumer),
            new("scope", scope)
        };

        var jwt = new JwtSecurityToken(
            issuer: issuer,
            audience: audience,
            claims: claims,
            expires: DateTime.UtcNow.AddMinutes(expireMinutes),
            signingCredentials: creds
        );
        jwt.Payload["iat"] = DateTimeOffset.UtcNow.ToUnixTimeSeconds();

        var handler = new JwtSecurityTokenHandler();
        return handler.WriteToken(jwt);
    }

    [Fact]
    public void ValidateJwt_ValidToken_ReturnsPrincipalAndScopes()
    {
        var tokenString = CreateTokenString("user123", "web-app", "payment:read payment:write");
        var handler = new JwtSecurityTokenHandler();

        var (principal, consumer, scopes, error) = ApiHelpers.ValidateJwt(tokenString, GetDefaultValidationParams(), handler);
        
        Assert.Null(error);
        Assert.Equal("user123", principal);
        Assert.Equal("web-app", consumer);
        Assert.NotNull(scopes);
        Assert.Contains("payment:read", scopes);
        Assert.Contains("payment:write", scopes);
    }

    [Fact]
    public void ValidateJwt_UnsignedToken_ReturnsError()
    {
        var header = Base64UrlEncoder.Encode("{\"alg\":\"none\",\"typ\":\"JWT\"}");
        var payload = Base64UrlEncoder.Encode(JsonSerializer.Serialize(new
        {
            iss = "test-issuer",
            aud = "test-audience",
            sub = "user123",
            consumer = "web-app",
            scope = "read",
            iat = DateTimeOffset.UtcNow.ToUnixTimeSeconds(),
            exp = DateTimeOffset.UtcNow.AddMinutes(10).ToUnixTimeSeconds()
        }));

        var unsignedToken = $"{header}.{payload}.";
        var handler = new JwtSecurityTokenHandler();

        var (principal, _, _, error) = ApiHelpers.ValidateJwt(unsignedToken, GetDefaultValidationParams(), handler);

        Assert.NotNull(error);
        Assert.Null(principal);
    }

    [Fact]
    public void ValidateJwt_InvalidSignature_ReturnsError()
    {
        var wrongKey = new SymmetricSecurityKey(Encoding.UTF8.GetBytes("different_key_that_is_also_32_bytes_long_12345"));
        var tokenString = CreateTokenString("user123", "web-app", "read", key: wrongKey);
        var handler = new JwtSecurityTokenHandler();

        var (principal, _, _, error) = ApiHelpers.ValidateJwt(tokenString, GetDefaultValidationParams(), handler);

        Assert.NotNull(error);
        Assert.Null(principal);
    }

    [Fact]
    public void ValidateJwt_NumericSubClaim_ReturnsError()
    {
        var header = Base64UrlEncoder.Encode("{\"alg\":\"HS256\",\"typ\":\"JWT\"}");
        var payload = Base64UrlEncoder.Encode("{\"iss\":\"test-issuer\",\"aud\":\"test-audience\",\"sub\":12345,\"consumer\":\"web-app\",\"scope\":\"read\",\"iat\":100000,\"exp\":9999999999}");
        var tokenWithoutSig = $"{header}.{payload}";
        
        using var hmac = new System.Security.Cryptography.HMACSHA256(Encoding.UTF8.GetBytes(TestKey));
        var sigBytes = hmac.ComputeHash(Encoding.UTF8.GetBytes(tokenWithoutSig));
        var signature = Base64UrlEncoder.Encode(sigBytes);
        var tokenString = $"{tokenWithoutSig}.{signature}";

        var handler = new JwtSecurityTokenHandler();
        var (principal, _, _, error) = ApiHelpers.ValidateJwt(tokenString, GetDefaultValidationParams(validateLifetime: false), handler);

        Assert.NotNull(error);
        Assert.Contains("sub claim must be a non-empty string", error);
        Assert.Null(principal);
    }

    [Fact]
    public void ValidateJwt_InvalidExpClaimType_ReturnsError()
    {
        var header = Base64UrlEncoder.Encode("{\"alg\":\"HS256\",\"typ\":\"JWT\"}");
        var payload = Base64UrlEncoder.Encode("{\"iss\":\"test-issuer\",\"aud\":\"test-audience\",\"sub\":\"user123\",\"consumer\":\"web-app\",\"scope\":\"read\",\"iat\":100000,\"exp\":\"never\"}");
        var tokenWithoutSig = $"{header}.{payload}";
        
        using var hmac = new System.Security.Cryptography.HMACSHA256(Encoding.UTF8.GetBytes(TestKey));
        var sigBytes = hmac.ComputeHash(Encoding.UTF8.GetBytes(tokenWithoutSig));
        var signature = Base64UrlEncoder.Encode(sigBytes);
        var tokenString = $"{tokenWithoutSig}.{signature}";

        var handler = new JwtSecurityTokenHandler();
        var (principal, _, _, error) = ApiHelpers.ValidateJwt(tokenString, GetDefaultValidationParams(validateLifetime: false), handler);

        Assert.NotNull(error);
        Assert.Null(principal);
    }

    [Fact]
    public void ValidateJwt_WrongIssuerOrAudience_ReturnsError()
    {
        var tokenString = CreateTokenString("user123", "web-app", "read", issuer: "wrong-issuer");
        var handler = new JwtSecurityTokenHandler();

        var (principal, _, _, error) = ApiHelpers.ValidateJwt(tokenString, GetDefaultValidationParams(), handler);

        Assert.NotNull(error);
        Assert.Null(principal);
    }

    [Fact]
    public void ValidateJwt_MissingConsumerClaim_ReturnsError()
    {
        var creds = new SigningCredentials(_signingKey, SecurityAlgorithms.HmacSha256);
        var claims = new List<Claim>
        {
            new("sub", "user123"),
            new("scope", "read")
        };

        var jwt = new JwtSecurityToken(
            issuer: "test-issuer",
            audience: "test-audience",
            claims: claims,
            expires: DateTime.UtcNow.AddMinutes(30),
            signingCredentials: creds
        );
        jwt.Payload["iat"] = DateTimeOffset.UtcNow.ToUnixTimeSeconds();

        var handler = new JwtSecurityTokenHandler();
        var tokenString = handler.WriteToken(jwt);

        var (principal, _, _, error) = ApiHelpers.ValidateJwt(tokenString, GetDefaultValidationParams(), handler);

        Assert.NotNull(error);
        Assert.Contains("consumer", error);
        Assert.Null(principal);
    }

    [Fact]
    public void ValidateJwt_ExpiredToken_ReturnsError()
    {
        var creds = new SigningCredentials(_signingKey, SecurityAlgorithms.HmacSha256);
        var claims = new List<Claim>
        {
            new("sub", "user123"),
            new("consumer", "web-app"),
            new("scope", "read")
        };

        var jwt = new JwtSecurityToken(
            issuer: "test-issuer",
            audience: "test-audience",
            claims: claims,
            expires: DateTime.UtcNow.AddMinutes(-10),
            signingCredentials: creds
        );
        jwt.Payload["iat"] = DateTimeOffset.UtcNow.AddMinutes(-20).ToUnixTimeSeconds();

        var handler = new JwtSecurityTokenHandler();
        var tokenString = handler.WriteToken(jwt);

        var (principal, _, _, error) = ApiHelpers.ValidateJwt(tokenString, GetDefaultValidationParams(validateLifetime: true), handler);

        Assert.NotNull(error);
        Assert.Contains("expired", error);
        Assert.Null(principal);
    }
}
