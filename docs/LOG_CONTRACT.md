# Log sözleşmesi (stack'ten bağımsız)

Bu belge, `triage/LOADTEST_TRIAGE.md`'deki AI triage'ın çalışması için bir servisin **log satırlarında
bulunması gereken alanları** tanımlar. Triage yalnızca Loki ve LogQL kullanır; hangi dilde ya da
framework'te yazıldığınızın önemi yoktur. Sözleşmeye uyan her servis (Java, .NET, Node, Go, ...)
`alloy/config.alloy` ve triage şablonlarında **hiçbir değişiklik yapılmadan** analiz edilir.

Kanıt: `samples/dotnet-echo-service/` (ASP.NET Core + Serilog) bu sözleşmeyi uygular ve triage'ın
p95 / hata sorguları değiştirilmeden onun üzerinde çalışır (README → "Log sözleşmesi ve başka stack'ler").

## 1. Temel kurallar

1. **Satır başına bir JSON nesnesi.** Her log kaydı stdout'a tek satır, geçerli JSON olarak yazılır.
   Çok satırlı çıktı (pretty-print, ham stack trace) yasaktır; stack trace tek bir string alanın içinde
   `\n` ile kaçışlanmış olarak taşınır.
2. **Her HTTP isteği için tam olarak bir `request completed` satırı.** Bu satır isteğin *sonunda*,
   yanıt durumu belli olduktan sonra, başarılı/başarısız fark etmeksizin (exception fırlasa bile) yazılır.
   Framework'ün kendi istek loglaması (Spring `CommonsRequestLoggingFilter`, Serilog
   `UseSerilogRequestLogging`, pino-http'nin varsayılan `request completed` satırı) **kapatılır** ya da bu
   sözleşmeye uyacak şekilde yeniden adlandırılır; aksi halde istekler iki kez sayılır.
3. **Alan adları ve tipler birebir aynı.** Triage, LogQL'de `| json` ile alanları ayrıştırıp
   `httpStatus >= 500`, `unwrap durationMs` gibi ifadeler kullanır. Ad farklı (`status_code`,
   `elapsed`) ya da tip farklı (`"200"` string) ise sorgular sessizce boş döner.
4. **Mesaj metinleri sabittir.** `request completed` metni filtre anahtarıdır (`|= "request completed"`);
   yerelleştirilmez, değiştirilmez.

## 2. Ortak alanlar (her satırda)

| Alan         | Tip    | Zorunlu | Açıklama |
|--------------|--------|---------|----------|
| `@timestamp` | string | evet    | ISO-8601 / RFC 3339, UTC, milisaniye veya daha ince (`2026-11-06T14:05:53.459Z`). Triage trace satırlarını buna göre sıralar. |
| `level`      | string | evet    | **Büyük harf**: `TRACE`, `DEBUG`, `INFO`, `WARN`, `ERROR`. Alloy bunu Loki **label**'ı yapar; triage `{level="ERROR"}` ile filtreler. `Information`, `info`, `30` gibi değerler kabul edilmez. |
| `message`    | string | evet    | İnsan tarafından okunur mesaj. `request completed`, `unhandled exception` gibi sabit anahtarlar burada. |
| `logger`     | string | hayır   | Kaynak sınıf/kategori (`com.lab.credit.web.RequestLogFilter`, `Echo.RequestLogMiddleware`). Hata kümelerinde kod konumunu bulmaya yardım eder. |
| `service`    | string | evet    | Servis adı (`credit-service`, `dotnet-echo-service`). Loki label'ı olan `service` Docker ortamında container adından türetilir; satırdaki alan bunun yedeğidir (Docker dışı toplayıcılar ve dosya logları için). İkisi **aynı değer** olmalıdır. |
| `traceId`    | string | evet*   | W3C trace id: **32 küçük harf hex** karakter (`6aeddebfc6143be67ca0f4330b5a27db`). Servisler arası HTTP çağrılarında `traceparent` başlığı ile taşınır; aynı değer zincirdeki her serviste loglanır. Alloy bunu **structured metadata** olarak saklar (`| traceId="..."` ile json parse etmeden sorgulanır). |
| `spanId`     | string | hayır   | W3C span id, 16 hex. Raporlarda gösterilir, sorgularda kullanılmaz. |

\* `traceId` bir HTTP isteği bağlamında yazılan her satırda zorunludur. Uygulama başlangıcı gibi istek
dışı satırlarda boş olabilir; **asla** `"traceId": null` ya da `"traceId": ""` yazmak yerine alanı tamamen
atlayın, aksi halde Alloy boş structured metadata üretir.

### İş bağlamı (isteğe bağlı, önerilir)

| Alan            | Tip    | Açıklama |
|-----------------|--------|----------|
| `customerId`    | string | Müşteri / kullanıcı kimliği. Trace okurken "kim etkilendi" sorusunu cevaplar. |
| `applicationId` | string | İşlem/başvuru kimliği. |

Bunlar MDC / LogContext üzerinden satıra eklenir, label olmaz. Kendi alan adlarınızı (örn. `tenantId`,
`orderId`) aynı şekilde ekleyebilirsiniz; triage bunları trace okurken olduğu gibi gösterir.

## 3. `request completed` satırı (istek başına bir tane)

`message = "request completed"`, `level = "INFO"` (hata olsa bile INFO; hata ayrıca `httpStatus` ve
exception alanlarında görünür). Ortak alanlara ek olarak:

| Alan               | Tip    | Zorunlu            | Açıklama |
|--------------------|--------|--------------------|----------|
| `endpoint`         | string | evet               | `METHOD + boşluk + route şablonu`: `POST /api/v1/loans/shopping/apply`, `GET /api/v1/loans/{applicationId}`. **Somut URL değil şablon** (`/loans/0523f765-...` değil `/loans/{applicationId}`), aksi halde endpoint bazlı gruplama kardinalite patlar. Route eşleşmediyse (404) ham path kullanılabilir. |
| `httpStatus`       | number | evet               | HTTP yanıt kodu, **sayı** (`503`, `"503"` değil). `httpStatus >= 500` ile filtrelenir. |
| `durationMs`       | number | evet               | İsteğin toplam süresi, milisaniye, **tam sayı**. `unwrap durationMs` ile p95 hesaplanır. |
| `exceptionClass`   | string | hata varsa         | Fırlatılan exception'ın tam adı (`java.lang.NullPointerException`, `System.InvalidOperationException`). Kümeleme anahtarıdır. |
| `exceptionMessage` | string | hata varsa         | Exception mesajı. `exceptionClass` ile birlikte küme oluşturur. |

Başarılı istekte `exceptionClass`/`exceptionMessage` **yazılmaz** (null olarak da yazılmaz).

Örnek (credit-service, Java):

```json
{"@timestamp":"2026-11-06T14:05:53.459Z","level":"INFO","logger":"com.lab.credit.web.RequestLogFilter","message":"request completed","traceId":"6aeddebfc6143be67ca0f4330b5a27db","spanId":"7ca0f4330b5a27db","customerId":"C985821","applicationId":"0523f765-3a7b-4d57-8190-f3a1688c8437","endpoint":"POST /api/v1/loans/shopping/apply","httpStatus":201,"durationMs":1948,"service":"credit-service"}
```

Örnek (dotnet-echo-service, .NET):

```json
{"@timestamp":"2026-11-06T15:12:01.117Z","level":"INFO","logger":"Echo.RequestLogMiddleware","message":"request completed","traceId":"0af7651916cd43dd8448eb211c80319c","spanId":"b7ad6b7169203331","endpoint":"POST /api/v1/echo","httpStatus":200,"durationMs":173,"service":"dotnet-echo-service"}
```

## 4. Hata satırları

Yakalanmamış bir exception olduğunda, `request completed` satırına ek olarak **bir** `level = "ERROR"`
satırı yazılır (aynı `traceId` ile):

| Alan               | Tip    | Zorunlu | Açıklama |
|--------------------|--------|---------|----------|
| `message`          | string | evet    | Kısa, sabit metin: `unhandled exception` ya da anlamlı bir açıklama (`scoring pool exhausted, inflight=12, waited=2000ms, poolSize=10`). |
| `exceptionClass`   | string | evet    | Tam exception adı. |
| `exceptionMessage` | string | evet    | Exception mesajı. |
| `stackTrace`       | string | evet    | Tek string, satırlar `\n` ile. İlk **uygulama** karesi (`com.lab...`, `Echo...`, `MyCompany...`) kök nedenin kod konumudur; framework kareleri kısaltılabilir. |

Beklenen iş hataları (404, validasyon) için ERROR satırı yazılmaz; `request completed` satırındaki
`httpStatus` yeterlidir. Bir hata **downstream**'e yapılan çağrıdan kaynaklanıyorsa mesajda hedef servis
adı ve alınan durum geçmelidir (`scoring-service call failed: 503 ...`); triage adım 5 bu metne bakarak
zincirin diğer ucuna geçer.

## 5. Loki'de neyin label OLMADIĞI

Alloy sadece iki label üretir: `service` (container adı) ve `level` (satırdaki alan). Geri kalan her şey
satırın içinde kalır; `traceId` ek olarak structured metadata'dır.

**Label yapılmaması gerekenler** (yüksek kardinalite, Loki'yi öldürür):

- `traceId`, `spanId`
- `customerId`, `applicationId`, kullanıcı/işlem kimlikleri
- `endpoint` (şablon olsa bile), `httpStatus`, `durationMs`
- `exceptionClass`, `exceptionMessage`, `logger`, `thread`

Bunlara sorgu anında `| json` ile erişilir (`| json | httpStatus >= 500`). Triage şablonları bu varsayımla
yazılmıştır; bir alanı label yaparsanız sorgular yine çalışır ama Loki tarafında stream patlaması olur.

## 6. Hangi alan nerede kullanılıyor (triage ↔ sözleşme)

| Triage adımı | Kullandığı alan / label |
|--------------|-------------------------|
| 1. Hacim, hata oranı, p95 | `service` (label), `message="request completed"`, `httpStatus`, `durationMs`, `endpoint`, `exceptionClass` |
| 2. 5xx × endpoint | `endpoint`, `httpStatus` |
| 3. Hata kümeleri | `httpStatus`, `endpoint`, `exceptionClass`, `exceptionMessage`; `level="ERROR"` (label), `traceId`, `logger`, `message` |
| 4. Trace okuma | `traceId` (structured metadata), `@timestamp`, `customerId`, `applicationId`, `stackTrace` |
| 5. Servisler arası korelasyon | `traceId` (tüm servislerde aynı), `service`, `httpStatus`, `level` |
| 6. Yük mü bug mı | adım 1 serileri |

Sözleşmede olmayan hiçbir alan triage tarafından kullanılmaz.

## 7. Stack'e göre üretim rehberi

| Sözleşme alanı     | Java — logback + logstash-logback-encoder | .NET — Serilog | Node — pino |
|--------------------|--------------------------------------------|----------------|-------------|
| Tek satır JSON     | `LogstashEncoder` (ConsoleAppender) | `ExpressionTemplate` (Serilog.Expressions) ile Console sink, ya da `CompactJsonFormatter` + yeniden adlandırma | pino varsayılan çıktı zaten NDJSON |
| `@timestamp`       | `<fieldNames><timestamp>@timestamp</timestamp>` (varsayılan zaten bu) | şablonda `'@timestamp': UtcDateTime(@t)` | `timestamp: () => ',"@timestamp":"' + new Date().toISOString() + '"'` |
| `level` (büyük harf) | `<level>level</level>`; logback zaten `INFO`/`WARN`/`ERROR` üretir | `@l` → `Information`→`INFO`, `Warning`→`WARN`, `Error`/`Fatal`→`ERROR` eşlemesi (örnek: `Level(@l)` fonksiyonu, `samples/dotnet-echo-service/Program.cs`) | `formatters.level: (label) => ({ level: label.toUpperCase() })` (varsayılan sayısal `30` kabul edilmez) |
| `message`          | `<message>message</message>` | şablonda `message: @m` (render edilmiş mesaj; `@mt` şablon metni değil) | `messageKey: 'message'` |
| `logger`           | `<logger>logger</logger>` | `logger: SourceContext` (`ILogger<T>` kategorisi) | `name` alanı; `formatters.bindings` ile `logger` olarak yeniden adlandırın |
| `service`          | `<customFields>{"service":"credit-service"}</customFields>` | `.Enrich.WithProperty("service", "dotnet-echo-service")` | `base: { service: 'my-service' }` |
| `traceId` / `spanId` | Micrometer Tracing MDC'ye `traceId`/`spanId` koyar; encoder MDC'yi otomatik ekler | Serilog ≥ 3.1 `Activity.Current`'tan `LogEvent.TraceId`/`SpanId` alır; şablonda `traceId: @tr, spanId: @sp`. ASP.NET Core gelen `traceparent`'ı otomatik devralır | `@opentelemetry/api` ile `trace.getActiveSpan().spanContext().traceId`; `mixin: () => ({ traceId, spanId })` |
| `customerId` vb.   | `MDC.put("customerId", ...)` | `LogContext.PushProperty("customerId", ...)` | `logger.child({ customerId })` ya da AsyncLocalStorage mixin |
| `request completed` satırı | `OncePerRequestFilter` (`RequestLogFilter.java`); route şablonu `HandlerMapping.BEST_MATCHING_PATTERN_ATTRIBUTE` | Middleware (`RequestLogMiddleware.cs`); route şablonu `(ctx.GetEndpoint() as RouteEndpoint)?.RoutePattern.RawText`; ABP'de aynı middleware `OnApplicationInitialization`'da `app.UseMiddleware<...>()` ile en başa eklenir | Express/Fastify `onResponse` hook'u; route şablonu `req.route.path` (Express) / `request.routeOptions.url` (Fastify) |
| `httpStatus`, `durationMs` (sayı) | `kv("httpStatus", status)` (`StructuredArguments`) | `logger.LogInformation("request completed {httpStatus} {durationMs}", status, ms)` → Serilog sayıyı sayı olarak yazar | `logger.info({ httpStatus, durationMs }, 'request completed')` |
| `exceptionClass`, `exceptionMessage`, `stackTrace` | `GlobalExceptionHandler` + `ShortenedThrowableConverter` (`<stackTrace>stackTrace</stackTrace>`) | Enricher: `@x` varsa `exceptionClass = ex.GetType().FullName`, `exceptionMessage = ex.Message`; şablonda `stackTrace: @x` | `serializers.err`'i özelleştirip `exceptionClass: err.name`, `exceptionMessage: err.message`, `stackTrace: err.stack` yazın |
| Framework'ün kendi istek logunu kapat | Spring'de varsayılan yok | `UseSerilogRequestLogging()` **ekleme**; `Microsoft.AspNetCore` kategorisini `Warning`'e çek | `pino-http` kullanıyorsanız `customSuccessMessage`/`customReceivedMessage` ile sözleşmeye uydurun ya da kendi hook'unuzu yazın |

### Hızlı kendi kendine test

Servisinizi tek başına çalıştırıp bir istek atın ve stdout'taki satırı şu şekilde kontrol edin:

```bash
docker logs <container> 2>&1 | grep '"request completed"' | tail -1 | jq '{ts: ."@timestamp", level, service, traceId, endpoint, httpStatus, durationMs}'
```

- `level` büyük harf mi? `httpStatus` ve `durationMs` tırnaksız sayı mı? `traceId` 32 hex mi?
- Ardından Loki'de: `{service="<ad>"} |= "request completed" | json | httpStatus >= 500` ve
  `quantile_over_time(0.95, {service="<ad>"} |= "request completed" | json | unwrap durationMs [1m]) by (endpoint)`
  boş dönmüyorsa sözleşmeye uyuyorsunuz; triage'ı `service=<ad>` girdisiyle çalıştırabilirsiniz.
