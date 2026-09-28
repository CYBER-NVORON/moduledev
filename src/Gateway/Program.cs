var builder = WebApplication.CreateBuilder(args);

builder.Logging.ClearProviders().AddJsonConsole();

var apiBackend = Environment.GetEnvironmentVariable("API_BACKEND_URL") ?? "http://api:8080";

builder.Services.AddHttpClient("api", client =>
{
    client.BaseAddress = new Uri(apiBackend);
    client.Timeout = TimeSpan.FromSeconds(120);
});

var app = builder.Build();

// Liveness is local; readiness follows the API dependency.
app.MapGet("/health/live", () => Results.Ok(new { status = "ok" }));

app.MapGet("/health/ready", async (IHttpClientFactory httpFactory) =>
{
    try
    {
        var client = httpFactory.CreateClient("api");
        var response = await client.GetAsync("/health/ready");
        var body = await response.Content.ReadAsStringAsync();
        return Results.Content(body, "application/json", statusCode: (int)response.StatusCode);
    }
    catch
    {
        return Results.Json(new { status = "error", code = "dependency.unavailable", message = "api unreachable" },
            statusCode: 503);
    }
});

// Only these route families are forwarded to the internal API.
app.Map("/api/{**rest}", async (HttpContext ctx, IHttpClientFactory httpFactory) =>
    await ProxyRequest(ctx, httpFactory));

app.Map("/openapi/{**rest}", async (HttpContext ctx, IHttpClientFactory httpFactory) =>
    await ProxyRequest(ctx, httpFactory));

app.MapFallback(() => Results.NotFound(new { status = "error", code = "not_found", message = "route not found" }));

app.Run();

async Task ProxyRequest(HttpContext ctx, IHttpClientFactory httpFactory)
{
    var client = httpFactory.CreateClient("api");
    var path = ctx.Request.Path + ctx.Request.QueryString;

    try
    {
        using var request = new HttpRequestMessage
        {
            Method = new HttpMethod(ctx.Request.Method),
            RequestUri = new Uri(path, UriKind.Relative),
        };

        // Stream the original bytes so receipt signatures remain valid.
        if (ctx.Request.ContentLength > 0 || ctx.Request.ContentType is not null)
        {
            request.Content = new StreamContent(ctx.Request.Body);
            if (ctx.Request.ContentType is not null)
            {
                request.Content.Headers.TryAddWithoutValidation("Content-Type", ctx.Request.ContentType);
            }
        }

        // Forward contract headers (never log these values)
        ForwardHeader(ctx, request, "Authorization");
        ForwardHeader(ctx, request, "Idempotency-Key");
        ForwardHeader(ctx, request, "X-Action-Version");
        ForwardHeader(ctx, request, "X-Provider-Signature");

        using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ctx.RequestAborted);

        ctx.Response.StatusCode = (int)response.StatusCode;

        foreach (var (key, values) in response.Headers)
        {
            // Skip transfer-encoding to avoid conflicts with Kestrel's own chunked handling
            if (key.Equals("Transfer-Encoding", StringComparison.OrdinalIgnoreCase)) continue;
            ctx.Response.Headers[key] = values.ToArray();
        }
        foreach (var (key, values) in response.Content.Headers)
        {
            ctx.Response.Headers[key] = values.ToArray();
        }

        await response.Content.CopyToAsync(ctx.Response.Body, ctx.RequestAborted);
    }
    catch (HttpRequestException)
    {
        ctx.Response.StatusCode = 503;
        ctx.Response.ContentType = "application/json";
        await ctx.Response.WriteAsync(
            """{"status":"error","code":"dependency.unavailable","message":"api unreachable"}""");
    }
    catch (TaskCanceledException) when (ctx.RequestAborted.IsCancellationRequested)
    {
        // Client disconnected - no point writing a response
    }
    catch (TaskCanceledException)
    {
        ctx.Response.StatusCode = 504;
        ctx.Response.ContentType = "application/json";
        await ctx.Response.WriteAsync(
            """{"status":"error","code":"gateway.timeout","message":"upstream timeout"}""");
    }
}

void ForwardHeader(HttpContext ctx, HttpRequestMessage request, string name)
{
    if (ctx.Request.Headers.TryGetValue(name, out var values))
        request.Headers.TryAddWithoutValidation(name, values.ToArray());
}
