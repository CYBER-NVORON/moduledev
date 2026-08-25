var builder = WebApplication.CreateBuilder(args);

builder.Logging.ClearProviders().AddJsonConsole();

var apiBackend = Environment.GetEnvironmentVariable("API_BACKEND_URL") ?? "http://api:8080";

builder.Services.AddHttpClient("api", client =>
{
    client.BaseAddress = new Uri(apiBackend);
    client.Timeout = TimeSpan.FromSeconds(120);
});

var app = builder.Build();

// --- Health: live is local, ready proxies to api ---
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

// --- Whitelisted proxy routes ---
app.Map("/api/{**rest}", async (HttpContext ctx, IHttpClientFactory httpFactory) =>
    await ProxyRequest(ctx, httpFactory));

app.Map("/openapi/{**rest}", async (HttpContext ctx, IHttpClientFactory httpFactory) =>
    await ProxyRequest(ctx, httpFactory));

// --- Fallback: 404 for everything else ---
app.MapFallback(() => Results.NotFound(new { status = "error", code = "not_found", message = "route not found" }));

app.Run();

// --- Proxy Implementation ---
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

        // Forward body for POST/PUT/PATCH
        if (ctx.Request.ContentLength > 0 || ctx.Request.ContentType is not null)
        {
            request.Content = new StreamContent(ctx.Request.Body);
            if (ctx.Request.ContentType is not null)
            {
                if (System.Net.Http.Headers.MediaTypeHeaderValue.TryParse(ctx.Request.ContentType, out var mediaType))
                    request.Content.Headers.ContentType = mediaType;
                else
                {
                    ctx.Response.StatusCode = 400;
                    ctx.Response.ContentType = "application/json";
                    await ctx.Response.WriteAsync(
                        """{"status":"error","code":"request.invalid","message":"invalid Content-Type header"}""");
                    return;
                }
            }
        }

        // Forward contract headers (never log these values)
        ForwardHeader(ctx, request, "Authorization");
        ForwardHeader(ctx, request, "Idempotency-Key");
        ForwardHeader(ctx, request, "X-Action-Version");

        using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ctx.RequestAborted);

        ctx.Response.StatusCode = (int)response.StatusCode;

        // Copy response headers
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
