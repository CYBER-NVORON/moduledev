using System.Globalization;
using System.Text;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Npgsql;

namespace Course;

public static class HealthEndpoints
{
    public static void Map(WebApplication app, string? connectionString, bool databaseMetrics = false)
    {
        app.MapGet("/health/live", () => Results.Json(new { status = "live" }));
        app.MapGet("/health/ready", async (HttpContext context) =>
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(context.RequestAborted);
            timeout.CancelAfter(TimeSpan.FromSeconds(2));
            try
            {
                await using var conn = new NpgsqlConnection(connectionString);
                await conn.OpenAsync(timeout.Token);
                await using var cmd = new NpgsqlCommand("SELECT to_regclass('autocheck.metrics') IS NOT NULL", conn);
                if ((bool)(await cmd.ExecuteScalarAsync(timeout.Token) ?? false))
                    return Results.Json(new { status = "ready" });
            }
            catch (Exception) { /* Health never exposes connection strings or SQL errors. */ }
            return Results.Json(new { status = "not_ready", code = "dependency.unavailable" }, statusCode: 503);
        });
        app.MapGet("/metrics", async (HttpContext context) =>
        {
            var text = new StringBuilder();
            if (databaseMetrics)
            {
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(context.RequestAborted);
                timeout.CancelAfter(TimeSpan.FromSeconds(2));
                try
                {
                    await using var conn = new NpgsqlConnection(connectionString);
                    await conn.OpenAsync(timeout.Token);
                    await using var cmd = new NpgsqlCommand("SELECT * FROM autocheck.metrics", conn);
                    await using var rows = await cmd.ExecuteReaderAsync(timeout.Token);
                    await rows.ReadAsync(timeout.Token);
                    for (var i = 0; i < rows.FieldCount; i++)
                    {
                        var name = rows.GetName(i);
                        var counter = name == "workflow_failures_total";
                        text.Append("# TYPE ").Append(counter ? "workflow_failures" : name)
                            .Append(counter ? " counter\n" : " gauge\n");
                        text.Append(name).Append(' ').Append(Convert.ToString(rows.GetValue(i), CultureInfo.InvariantCulture)).Append('\n');
                    }
                }
                catch (Exception)
                {
                    return Results.Json(new { status = "not_ready", code = "dependency.unavailable" }, statusCode: 503);
                }
            }
            else text.Append("# TYPE component_up gauge\ncomponent_up 1\n");
            text.Append("# EOF\n");
            return Results.Text(text.ToString(), "application/openmetrics-text; version=1.0.0; charset=utf-8");
        });
    }
}
