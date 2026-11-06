using Serilog.Core;
using Serilog.Events;
using Serilog.Expressions;
using Serilog.Templates;

namespace Echo;

/// <summary>
/// Produces log lines in the shape required by docs/LOG_CONTRACT.md:
/// one JSON object per line, with Serilog's @t/@l/@m renamed to @timestamp/level/message,
/// traceId/spanId taken from the current Activity (W3C ids) and the service name on every line.
/// </summary>
public static class ContractLogging
{
    public const string ServiceName = "dotnet-echo-service";

    // Object-literal template: every key is written exactly as named here.
    //  - UtcDateTime(@t)  -> "@timestamp" in UTC ISO-8601
    //  - Level(@l)        -> INFO / WARN / ERROR (uppercase, see ContractFunctions)
    //  - @m               -> rendered message ("request completed")
    //  - @tr / @sp        -> Activity trace id (32 hex) / span id (16 hex), captured by Serilog
    //  - ..rest()         -> every other event property (endpoint, httpStatus, durationMs,
    //                        exceptionClass, exceptionMessage, customerId, ...) at top level
    //  - @x               -> exception ToString() as a single escaped string, only when present
    private const string Template =
        "{ {'@timestamp': UtcDateTime(@t), level: Level(@l), logger: SourceContext, message: @m, " +
        "traceId: @tr, spanId: @sp, service: '" + ServiceName + "', ..rest(), stackTrace: @x} }\n";

    public static ExpressionTemplate CreateFormatter() =>
        new(Template, nameResolver: new StaticMemberNameResolver(typeof(ContractFunctions)));

    /// <summary>Functions callable from the template.</summary>
    public static class ContractFunctions
    {
        public static LogEventPropertyValue? Level(LogEventPropertyValue? level)
        {
            if (level is ScalarValue { Value: LogEventLevel l })
            {
                return new ScalarValue(l switch
                {
                    LogEventLevel.Verbose => "TRACE",
                    LogEventLevel.Debug => "DEBUG",
                    LogEventLevel.Information => "INFO",
                    LogEventLevel.Warning => "WARN",
                    LogEventLevel.Error => "ERROR",
                    LogEventLevel.Fatal => "ERROR",
                    _ => l.ToString().ToUpperInvariant()
                });
            }
            return null;
        }
    }

    /// <summary>Drops ASP.NET Core hosting scope properties that are noise for the triage.</summary>
    public sealed class DropHostingNoiseEnricher : ILogEventEnricher
    {
        private static readonly string[] Noise = ["RequestId", "RequestPath", "ConnectionId", "EventId"];

        public void Enrich(LogEvent logEvent, ILogEventPropertyFactory propertyFactory)
        {
            foreach (var name in Noise) logEvent.RemovePropertyIfPresent(name);
        }
    }

    /// <summary>
    /// Adds exceptionClass / exceptionMessage to any event that carries an exception, so the
    /// ERROR line and the request line share the same clustering keys as the Java services.
    /// </summary>
    public sealed class ExceptionEnricher : ILogEventEnricher
    {
        public void Enrich(LogEvent logEvent, ILogEventPropertyFactory propertyFactory)
        {
            if (logEvent.Exception is null) return;
            logEvent.AddPropertyIfAbsent(propertyFactory.CreateProperty("exceptionClass", logEvent.Exception.GetType().FullName));
            logEvent.AddPropertyIfAbsent(propertyFactory.CreateProperty("exceptionMessage", logEvent.Exception.Message));
        }
    }
}
