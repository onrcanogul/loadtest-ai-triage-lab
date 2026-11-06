# Servisler arası trace doğrulaması — 2026-11-06 (scoring-service ayrıldıktan sonra)

Skorlama simülasyonu `credit-service` içinden çıkarılıp gerçek bir ikinci Spring Boot servisine
(`scoring-service`, port 8081) taşındı. Bu dosya, tek bir `traceId`'nin iki serviste de Loki'de
izlenebildiğinin ve havuz tükenmesi kök nedeninin artık downstream'de (`scoring-service`) yaşadığının kanıtıdır.

## 1. Tek istek, iki servis, aynı traceId

`POST /api/v1/loans/shopping/apply` (customerId C100001, POS2025, 6 taksit) → 201. Konteyner logları:

```
credit-service  traceId=6aedde81cdf6ed1cc767abc3916ac5ae spanId=c767abc3916ac5ae  loan application APPROVED score=726 ...
credit-service  traceId=6aedde81cdf6ed1cc767abc3916ac5ae spanId=c767abc3916ac5ae  request completed POST /api/v1/loans/shopping/apply 201 384ms
scoring-service traceId=6aedde81cdf6ed1cc767abc3916ac5ae spanId=133d5599d434df23 score computed score=726
scoring-service traceId=6aedde81cdf6ed1cc767abc3916ac5ae spanId=133d5599d434df23 request completed POST /api/v1/scores 200 238ms
```

Aynı `traceId`, farklı `spanId` (credit-service'in auto-configure `RestClient.Builder`'ı W3C `traceparent` gönderir,
scoring-service devam ettirir). Loki'de aynı trace:

```
{service=~"credit-service|scoring-service"} | traceId="6aedde81cdf6ed1cc767abc3916ac5ae"
```
```
2026-11-06T14:04:49.989Z scoring-service INFO score computed score=726
2026-11-06T14:04:49.994Z scoring-service INFO request completed 200 238
2026-11-06T14:04:50.006Z credit-service  INFO loan application APPROVED score=726 installments=6 campaign=POS2025
2026-11-06T14:04:50.013Z credit-service  INFO request completed 201 384
```

Loki `service` label değerleri: `alloy, credit-service, grafana, loki, scoring-service` (Alloy konfigine dokunulmadı).

## 2. k6 koşusu

Pencere: `2026-11-06T14:05:09Z` – `2026-11-06T14:07:12Z` (UTC). Çıktı: `k6-run-2026-11-06-two-services.txt`.

```
✗ 'p(95)<800'  p(95)=3.06s
✗ 'rate<0.05'  rate=30.31%   (1298 / 4282)
default ✗ [ 72% ] 60/80 VUs  2m02.0s/2m50.0s
thresholds on metrics 'http_req_duration, http_req_failed' were crossed; at least one has abortOnFail enabled, stopping test prematurely
```

## 3. Loki: havuz tükenmesi downstream'de, 503 upstream'de yansıma

```logql
{service="scoring-service", level="ERROR"}                                                   -> 1171 satır
{service="credit-service"} |= "request completed" | json | httpStatus = 503                  -> 1171 satır
sum by (service, httpStatus) (count_over_time({service=~"credit-service|scoring-service"} |= "request completed" | json | httpStatus >= 500 [10m]))
   credit-service  httpStatus=500 -> 173   (NPE, sadece upstream)
   credit-service  httpStatus=503 -> 1171
   scoring-service httpStatus=503 -> 1171
sum by (service) (count_over_time({service=~"credit-service|scoring-service", level="ERROR"} [10m]))
   credit-service  -> 1344  (= 1171 scoring-service unavailable + 173 unhandled NPE)
   scoring-service -> 1171  (hepsi "scoring pool exhausted")
```

Örnek `scoring-service` ERROR satırları:

```
2026-11-06T14:06:02.766Z scoring-service ERROR traceId=6aeddec851a9b6c2e4ef682cb8cb804e scoring pool exhausted, inflight=41, waited=2000ms, poolSize=10
2026-11-06T14:06:04.010Z scoring-service ERROR traceId=6aeddeca3461cd3b82dd880640f50bf9 scoring pool exhausted, inflight=42, waited=2000ms, poolSize=10
2026-11-06T14:06:04.761Z scoring-service ERROR traceId=6aeddeca9b7d43bbdee215bf935aa66b scoring pool exhausted, inflight=43, waited=2000ms, poolSize=10
```

Aynı traceId'lerin `credit-service` tarafı:

```
2026-11-06T14:06:02.797Z credit-service traceId=6aeddec851a9b6c2e4ef682cb8cb804e request completed POST /api/v1/loans/shopping/apply 503 2038ms ScoringUnavailableException :: scoring-service call failed: ServiceUnavailable: 503 Service Unavailable: "{"message":"scoring pool exhausted (inflight=41, poolSize=10)","error":"SCORING_POOL_EXHAUSTED"}"
2026-11-06T14:06:04.017Z credit-service traceId=6aeddeca3461cd3b82dd880640f50bf9 request completed ... 503 2016ms ScoringUnavailableException :: ... (inflight=42, poolSize=10) ...
2026-11-06T14:06:04.775Z credit-service traceId=6aeddeca9b7d43bbdee215bf935aa66b request completed ... 503 2019ms ScoringUnavailableException :: ... (inflight=43, poolSize=10) ...
```

## 4. Bir trace'in tamamı (iki taraf)

```logql
{service=~"credit-service|scoring-service"} | traceId="6aeddf0feaa2184b64ed932344f5c86e"
```
```
14:07:13.698 scoring-service ERROR spanId=420c5ecc60496f9b scoring pool exhausted, inflight=73, waited=2000ms, poolSize=10   endpoint=POST /api/v1/scores
14:07:13.699 scoring-service INFO  spanId=420c5ecc60496f9b request completed POST /api/v1/scores 503 2002ms  ScoringPoolExhaustedException
14:07:13.700 credit-service  ERROR spanId=64ed932344f5c86e scoring-service unavailable  exceptionClass=HttpServerErrorException$ServiceUnavailable  "503 Service Unavailable: {...SCORING_POOL_EXHAUSTED}"
14:07:13.700 credit-service  WARN  spanId=64ed932344f5c86e scoring unavailable  ScoringUnavailableException
14:07:13.700 credit-service  INFO  spanId=64ed932344f5c86e request completed POST /api/v1/loans/shopping/apply 503 2004ms  ScoringUnavailableException
```

Ham JSON (iki ERROR satırı):

```json
{"@timestamp":"2026-11-06T14:07:13.698795959Z","message":"scoring pool exhausted, inflight=73, waited=2000ms, poolSize=10","logger":"com.lab.scoring.service.ScoringService","thread":"http-nio-8081-exec-16","level":"ERROR","traceId":"6aeddf0feaa2184b64ed932344f5c86e","spanId":"420c5ecc60496f9b","customerId":"C136825","endpoint":"POST /api/v1/scores","service":"scoring-service"}
{"@timestamp":"2026-11-06T14:07:13.700084084Z","message":"scoring-service unavailable","logger":"com.lab.credit.service.ScoringClient","thread":"http-nio-8080-exec-1","level":"ERROR","traceId":"6aeddf0feaa2184b64ed932344f5c86e","spanId":"64ed932344f5c86e","customerId":"C136825","endpoint":"POST /api/v1/loans/shopping/apply","exceptionClass":"org.springframework.web.client.HttpServerErrorException$ServiceUnavailable","exceptionMessage":"503 Service Unavailable: \"{\"message\":\"scoring pool exhausted (inflight=73, poolSize=10)\",\"error\":\"SCORING_POOL_EXHAUSTED\"}\"","service":"credit-service"}
```

Okuma (triage adım 5): downstream'de ERROR + 503 var, upstream'deki ERROR sadece "çağrı 503 döndü" diyor →
kök neden `scoring-service`'te (havuz), `credit-service`'teki 503 yansımadır. NPE (500) trace'lerinin
`scoring-service` tarafı 200'dür → o kök neden upstream'de.
