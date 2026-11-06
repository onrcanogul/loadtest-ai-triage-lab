using System.Diagnostics;
using Microsoft.AspNetCore.Routing;

namespace Echo;

/// <summary>
/// Writes exactly one "request completed" line per HTTP request with endpoint (method + route
/// pattern), httpStatus and durationMs, plus exceptionClass/exceptionMessage when the request
/// failed with an unhandled exception. Mirrors credit-service's RequestLogFilter.
/// Register it first in the pipeline so every request (including 404s) is covered.
/// </summary>
public sealed class RequestLogMiddleware(RequestDelegate next, ILogger<RequestLogMiddleware> logger)
{
    public async Task InvokeAsync(HttpContext context)
    {
        var start = Stopwatch.GetTimestamp();
        Exception? error = null;
        try
        {
            await next(context);
        }
        catch (Exception ex)
        {
            error = ex;
            // ERROR line with stack trace (same traceId as the request line)
            logger.LogError(ex, "unhandled exception");
            if (!context.Response.HasStarted)
            {
                context.Response.Clear();
                context.Response.StatusCode = StatusCodes.Status500InternalServerError;
                await context.Response.WriteAsJsonAsync(new { error = "INTERNAL_ERROR", message = "unexpected error" });
            }
        }
        finally
        {
            var durationMs = (long)Stopwatch.GetElapsedTime(start).TotalMilliseconds;
            var endpoint = context.Request.Method + " " + RoutePattern(context);
            var status = context.Response.StatusCode;
            // Fields go through a logging scope so the message stays exactly "request completed"
            // (the contract's filter key) while endpoint/httpStatus/durationMs become JSON fields.
            var fields = new Dictionary<string, object?>
            {
                ["endpoint"] = endpoint,
                ["httpStatus"] = status,
                ["durationMs"] = durationMs,
            };
            if (error is not null)
            {
                fields["exceptionClass"] = error.GetType().FullName;
                fields["exceptionMessage"] = error.Message;
            }
            using (logger.BeginScope(fields))
            {
                logger.LogInformation("request completed");
            }
        }
    }

    /// <summary>"/api/v1/echo/{id}" instead of the concrete URL when routing matched an endpoint.</summary>
    private static string RoutePattern(HttpContext context) =>
        (context.GetEndpoint() as RouteEndpoint)?.RoutePattern.RawText is { Length: > 0 } pattern
            ? (pattern.StartsWith('/') ? pattern : "/" + pattern)
            : context.Request.Path.Value ?? "/";
}
