using Echo;
using Serilog;
using Serilog.Events;

// Serilog -> stdout, one contract-shaped JSON object per line (see docs/LOG_CONTRACT.md).
Log.Logger = new LoggerConfiguration()
    .MinimumLevel.Information()
    .MinimumLevel.Override("Microsoft", LogEventLevel.Warning)   // no framework per-request noise
    .MinimumLevel.Override("Microsoft.Hosting.Lifetime", LogEventLevel.Information)
    .Enrich.FromLogContext()
    .Enrich.With<ContractLogging.ExceptionEnricher>()
    .Enrich.With<ContractLogging.DropHostingNoiseEnricher>()
    .WriteTo.Console(ContractLogging.CreateFormatter())
    .CreateLogger();

var builder = WebApplication.CreateBuilder(args);
builder.Host.UseSerilog();

var app = builder.Build();

// NOTE: do NOT add app.UseSerilogRequestLogging() - the contract allows exactly one request line,
// and RequestLogMiddleware writes it.
app.UseMiddleware<RequestLogMiddleware>();

app.MapGet("/health", () => Results.Ok(new { status = "UP", service = ContractLogging.ServiceName }));

// Sleeps 50-300 ms and echoes the body back. Send {"fail": true} to trigger an unhandled exception
// (shows the ERROR line + exceptionClass/exceptionMessage on the request line).
app.MapPost("/api/v1/echo", async (EchoRequest? body, ILogger<Program> log) =>
{
    var delay = Random.Shared.Next(50, 301);
    await Task.Delay(delay);
    if (body?.Fail == true)
    {
        throw new InvalidOperationException("echo failed on purpose (fail=true)");
    }
    log.LogInformation("echo processed in {processingMs} ms", delay);
    return Results.Ok(new { echo = body?.Message ?? "", delayMs = delay });
});

try
{
    Log.Information("starting {service}", ContractLogging.ServiceName);
    app.Run();
}
finally
{
    Log.CloseAndFlush();
}

record EchoRequest(string? Message, bool? Fail);
