# dotnet-echo-service — log sözleşmesi örneği (.NET)

`docs/LOG_CONTRACT.md`'deki sözleşmenin ASP.NET Core (minimal API, .NET 8) + Serilog ile nasıl
uygulandığını gösteren en küçük örnek. Amaç: triage şablonları ve `alloy/config.alloy` değişmeden
bir .NET servisinin loglarının analiz edilebildiğini kanıtlamak.

| Dosya | Ne yapar |
|-------|----------|
| `ContractLogging.cs` | Serilog `ExpressionTemplate`: `@t/@l/@m` → `@timestamp/level/message`, `@tr/@sp` → `traceId/spanId`, `service` sabiti, `level` büyük harf eşlemesi, `exceptionClass`/`exceptionMessage` enricher'ı, hosting gürültüsünü (`RequestId`, `ConnectionId`) atan enricher. |
| `RequestLogMiddleware.cs` | İstek başına tam bir `request completed` satırı: `endpoint` (method + route şablonu), `httpStatus`, `durationMs`; yakalanmamış exception'da ERROR satırı + aynı istek satırında `exceptionClass`/`exceptionMessage`. |
| `Program.cs` | Serilog kurulumu, middleware kaydı, `GET /health`, `POST /api/v1/echo` (50-300 ms uyur, 200 döner; `{"fail": true}` gönderilirse exception fırlatır). |
| `Dockerfile` | `sdk:8.0` → `aspnet:8.0` çok aşamalı imaj, port 8090. |

## Çalıştırma (compose `samples` profili)

```bash
docker compose --profile samples up -d --build dotnet-echo-service
```

```bash
curl -s -X POST localhost:8090/api/v1/echo -H 'content-type: application/json' -d '{"message":"hi"}'
```

```bash
curl -s -X POST localhost:8090/api/v1/echo -H 'content-type: application/json' -d '{"fail":true}'
```

Alloy, Docker container listesini ~60 sn'de bir yeniler; `service="dotnet-echo-service"` label'ı ilk kalkıştan
sonra bir dakika içinde görünür. Loki'de (triage şablonu, servis adı dışında değişmeden):

```logql
quantile_over_time(0.95, {service="dotnet-echo-service"} |= "request completed" | json | unwrap durationMs [1m]) by (endpoint)
```

Durdurmak için:

```bash
docker compose --profile samples stop dotnet-echo-service
```

## Kendi ABP / ASP.NET Core servisinize taşırken

1. `Serilog.AspNetCore` + `Serilog.Expressions` paketlerini ekleyin, `ContractLogging.cs`'i kopyalayın,
   `ServiceName`'i değiştirin ve `Log.Logger`'ı buradaki gibi kurun (`WriteTo.Console(ContractLogging.CreateFormatter())`).
2. `RequestLogMiddleware.cs`'i kopyalayın; ABP'de `OnApplicationInitialization` içinde
   `app.UseMiddleware<RequestLogMiddleware>()` çağrısını pipeline'ın **en başına** koyun.
3. `app.UseSerilogRequestLogging()` kullanmayın (ikinci bir istek satırı üretir).
   `Microsoft` kategorisini `Warning`'e çekin.
4. Downstream HTTP çağrılarında `HttpClient` zaten `traceparent` başlığını otomatik ekler
   (`Activity.Current` varken); böylece aynı `traceId` zincirdeki her serviste loglanır.
5. İş bağlamı (`customerId`, `tenantId`, ...) için `LogContext.PushProperty(...)` ya da
   `ILogger.BeginScope(...)` kullanın; alan satıra eklenir, label olmaz.
