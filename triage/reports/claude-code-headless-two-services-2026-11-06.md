Veri yeterli; adım 6'yı mevcut dakikalık serilerden hesaplayıp raporu yazıyorum.

**Pencere seçimi (0b):** Son 1 saatte iki ayrı yük tepesi var: 13:25–13:30 UTC ve 14:05–14:08 UTC. Talimatınız gereği sonuncusunu aldım. İncelenen pencere **2026-11-06 14:03:00Z – 14:13:00Z** (yerel 17:03–17:13). Trafik fiilen 14:05:00–14:07:30 arasında aktı. İlk tepe (13:25–13:30) bu raporda incelenmedi.

## Özet
Pencerede credit-service 4.364 istek aldı; bunların 1.344'ü 5xx döndü (%30,8). Hataların tamamı `POST /api/v1/loans/shopping/apply` endpoint'inde. İki farklı kök neden var: scoring-service'te yük kaynaklı havuz tükenmesi (1.171 adet 503, credit-service'e yansıyor) ve credit-service'te yükten bağımsız bir NullPointerException (173 adet 500). Test yaklaşık 2,5 dakika sürdü; ilk dakikada sadece NPE görülürken 503'ler ikinci dakikada yükle birlikte başladı.

## Kök neden(ler)

**1. Scoring havuzu tükenmesi — yük kaynaklı — kök neden downstream (scoring-service)**
`com.lab.scoring.service.ScoringService` sabit 10'luk bir havuzla çalışıyor; eşzamanlı istek 34–46'ya çıkınca 2000 ms bekleyip `ScoringPoolExhaustedException` ile 503 dönüyor. credit-service bu 503'ü `ScoringUnavailableException` olarak aynen yansıtıyor. İlk görülme: 14:06:02Z. Son görülme: 14:07:13Z. credit-service'teki 1.171 adet 503, scoring-service'teki 1.171 adet 503 ve 1.171 adet ERROR ile birebir eşleşiyor; arada timeout veya bağlantı hatası yok.

**2. Kampanya null — kod bug'ı — kök neden upstream (credit-service)**
`InstallmentCalculator.resolveRate` içinde `campaign` nesnesi null iken `Campaign.getRate()` çağrılıyor. scoring-service aynı trace'te 200 dönmüş, yani downstream temiz. Hata, scoring'i başarıyla geçen başvuruların yaklaşık %8–12'sinde yükten bağımsız olarak tekrarlıyor. İlk görülme: 14:05:11Z, yani testin ilk saniyelerinde. Son görülme: 14:07:13Z.

## Kanıt

**Kullanılan LogQL sorguları** (pencere 2026-11-06T14:03:00Z–14:13:00Z, datasource uid `loki`):

```logql
# 0b: yoğun pencere
sum(count_over_time({service="credit-service"} |= "request completed" [5m]))
sum(count_over_time({service="credit-service"} |= "request completed" [1m]))

# 1: status / dk, p95, hata sınıfı / dk
sum by (httpStatus) (count_over_time({service="credit-service"} |= "request completed" | json httpStatus [1m]))
sum by (httpStatus) (count_over_time({service="scoring-service"} |= "request completed" | json httpStatus [1m]))
quantile_over_time(0.95, {service="credit-service"} |= "request completed" | json endpoint, durationMs | unwrap durationMs [1m]) by (endpoint)
quantile_over_time(0.95, {service="scoring-service"} |= "request completed" | json endpoint, durationMs | unwrap durationMs [1m]) by (endpoint)
sum by (exceptionClass) (count_over_time({service="credit-service"} |= "request completed" | json httpStatus, exceptionClass | httpStatus >= 500 [1m]))

# 2: endpoint x status (instant, end=14:13:00Z)
sum by (endpoint, httpStatus) (count_over_time({service="credit-service"} |= "request completed" | json endpoint, httpStatus [10m]))

# 3: kümeleme
{service="credit-service"} |= "request completed" | json httpStatus, endpoint, exceptionClass, exceptionMessage, traceId | httpStatus >= 500 | line_format "{{.httpStatus}} {{.endpoint}} {{.exceptionClass}} :: {{.exceptionMessage}} :: {{.traceId}}"
{service="credit-service", level="ERROR"} | json traceId, logger, message, exceptionClass | line_format "{{.traceId}} {{.logger}} {{.message}} {{.exceptionClass}}"
{service="scoring-service", level="ERROR"} | json traceId, logger, message, exceptionClass | line_format "{{.traceId}} {{.logger}} {{.message}} {{.exceptionClass}}"

# 4-5: trace korelasyonu (her traceId için)
{service=~"credit-service|scoring-service"} | traceId="<TRACE_ID>" | json level, endpoint, httpStatus, durationMs, exceptionClass, exceptionMessage, message | line_format "{{.level}} ep={{.endpoint}} st={{.httpStatus}} dur={{.durationMs}} msg={{.message}} exc={{.exceptionClass}} :: {{.exceptionMessage}}"

# 5: iki tarafın sayıları tutarlı mı
sum by (service, endpoint, httpStatus) (count_over_time({service=~"credit-service|scoring-service"} |= "request completed" | json endpoint, httpStatus | httpStatus >= 500 [10m]))
sum by (service, exceptionClass) (count_over_time({service=~"credit-service|scoring-service", level="ERROR"} | json exceptionClass [10m]))
```

**Kök neden 1 — örnek trace'ler** (her satır aynı traceId'nin iki servisteki görünümü):

| traceId | servis | level | endpoint | status | durationMs | mesaj / exception |
|---|---|---|---|---|---|---|
| 6aeddec851a9b6c2e4ef682cb8cb804e | scoring-service | ERROR | POST /api/v1/scores | | | scoring pool exhausted, inflight=41, waited=2000ms, poolSize=10 |
| 6aeddec851a9b6c2e4ef682cb8cb804e | scoring-service | INFO | POST /api/v1/scores | 503 | 2022 | ScoringPoolExhaustedException |
| 6aeddec851a9b6c2e4ef682cb8cb804e | credit-service | ERROR | POST /api/v1/loans/shopping/apply | | | scoring-service unavailable, HttpServerErrorException$ServiceUnavailable |
| 6aeddec851a9b6c2e4ef682cb8cb804e | credit-service | INFO | POST /api/v1/loans/shopping/apply | 503 | 2038 | ScoringUnavailableException |
| 6aeddeca3461cd3b82dd880640f50bf9 | scoring-service | INFO | POST /api/v1/scores | 503 | 2006 | pool exhausted, inflight=42 |
| 6aeddeca3461cd3b82dd880640f50bf9 | credit-service | INFO | POST /api/v1/loans/shopping/apply | 503 | 2016 | ScoringUnavailableException |
| 6aeddeca9b7d43bbdee215bf935aa66b | scoring-service | INFO | POST /api/v1/scores | 503 | 2004 | pool exhausted, inflight=43 |
| 6aeddeca9b7d43bbdee215bf935aa66b | credit-service | INFO | POST /api/v1/loans/shopping/apply | 503 | 2019 | ScoringUnavailableException |

Sayı tutarlılığı: credit-service 503 = 1.171, scoring-service 503 = 1.171, scoring-service ERROR "pool exhausted" = 1.171, credit-service ERROR ServiceUnavailable = 1.171. Fark sıfır, yani upstream timeout'u veya bağlantı hatası yok.

**Kök neden 2 — örnek trace'ler:**

| traceId | servis | level | endpoint | status | durationMs | mesaj / exception |
|---|---|---|---|---|---|---|
| 6aedde9643fa1261fc074c37df94e687 | scoring-service | INFO | POST /api/v1/scores | 200 | 202 | request completed |
| 6aedde9643fa1261fc074c37df94e687 | credit-service | ERROR | POST /api/v1/loans/shopping/apply | | | unhandled exception, NullPointerException: Cannot invoke "Campaign.getRate()" because "campaign" is null |
| 6aedde9643fa1261fc074c37df94e687 | credit-service | INFO | POST /api/v1/loans/shopping/apply | 500 | 237 | NullPointerException |
| 6aedde98ebd228f849b0a7dc42cda6b4 | scoring-service | INFO | POST /api/v1/scores | 200 | 194 | request completed |
| 6aedde98ebd228f849b0a7dc42cda6b4 | credit-service | INFO | POST /api/v1/loans/shopping/apply | 500 | 207 | NullPointerException |
| 6aedde99aaf71aed578f8a23678b4d2c | scoring-service | INFO | POST /api/v1/scores | 200 | 198 | request completed |
| 6aedde99aaf71aed578f8a23678b4d2c | credit-service | INFO | POST /api/v1/loans/shopping/apply | 500 | 213 | NullPointerException |

Stack trace'teki ilk uygulama satırları (trace 6aedde9643fa1261fc074c37df94e687):

```
at com.lab.credit.service.InstallmentCalculator.resolveRate(InstallmentCalculator.java:39)
at com.lab.credit.service.InstallmentCalculator.monthlyInstallment(InstallmentCalculator.java:32)
at com.lab.credit.service.LoanApplicationService.apply(LoanApplicationService.java:38)
at com.lab.credit.web.LoanController.apply(LoanController.java:29)
```

**Dakikalık istek vs hata (credit-service, tüm endpoint'ler):**

| Dakika (UTC) | istek/dk | 500 (NPE) | 503 (scoring) | 5xx oranı | apply içinde NPE oranı* | credit p95 apply ms | scoring p95 ms |
|---|---|---|---|---|---|---|---|
| 14:04–14:05 | 2 | 0 | 0 | %0 | – | 384 | 238 |
| 14:05–14:06 | 1.738 | 106 | 0 | %6,1 | %11,5 | 1.903 | 1.895 |
| 14:06–14:07 | 2.100 | 52 | 872 | %44,0 | %8,1 | 3.142 | 3.139 |
| 14:07–14:08 | 524 | 15 | 299 | %59,9 | %10,9 | 3.235 | 3.231 |

\* NPE oranı, scoring'i geçen apply istekleri (201 + 500) içinde hesaplandı, çünkü 503 alan istekler kampanya hesabına hiç ulaşmıyor.

Adım 6 yorumu: 503'ler en düşük yüklü dakikada (1.738 istek/dk) sıfır, en yüksek yüklü dakikada (2.100 istek/dk) %57,7 ve gecikme p95 yükle birlikte 238 ms'den 3.231 ms'ye çıkıyor; mesaj kaynak tükenmesi anlatıyor. Bu yük kaynaklı. NPE oranı ise üç dakikada %8–12 bandında, yükten ve gecikmeden bağımsız. Bu kod bug'ı.

## Etkilenen endpoint ve oran

| service | endpoint | status | adet | pencere içindeki oran |
|---|---|---|---|---|
| credit-service | POST /api/v1/loans/shopping/apply | 503 | 1.171 | endpoint'in %40,8'i, tüm isteklerin %26,8'i |
| credit-service | POST /api/v1/loans/shopping/apply | 500 | 173 | endpoint'in %6,0'ı, tüm isteklerin %4,0'ı |
| credit-service | POST /api/v1/loans/shopping/apply | 201 | 1.527 | endpoint'in %53,2'si |
| credit-service | GET /api/v1/loans/{applicationId} | 200 | 1.492 | %100 başarılı |
| scoring-service | POST /api/v1/scores | 503 | 1.171 | endpoint'in %40,8'i |
| scoring-service | POST /api/v1/scores | 200 | 1.701 | endpoint'in %59,2'si |

Endpoint toplamı apply için 2.871, scores için 2.872.

## Önerilen düzeltme

**scoring-service (kök neden 1):**
- `com.lab.scoring.service.ScoringService` içindeki `poolSize=10` değerini yük hedefine göre büyütün. Dakikada 2.100 istek ve ~200 ms işlem süresiyle sürekli en az 7 eşzamanlı, tepe anlarında 40+ eşzamanlı istek geliyor; havuzun inflight'ı karşılayacak şekilde 32–64 bandında konfigüre edilebilir olması gerekir.
- 2000 ms'lik bekleme süresi havuz dolunca her isteği 2 saniye bloklayıp sonra reddediyor; bu hem gecikmeyi hem inflight'ı şişiriyor. Bekleme süresini kısaltın veya hızlı red yapın ve bir kuyruk sınırı koyun.
- Havuz ve bekleme değerlerini kodda sabit değil, konfigürasyondan okuyun.

**credit-service (kök neden 1'in yansıması):**
- `LoanApplicationService.apply` içindeki scoring çağrısına bulkhead ve circuit breaker ekleyin; scoring 503 döndüğünde isteği 2 saniye bekletmek yerine hızlı ve anlamlı bir hata dönün.

**credit-service (kök neden 2):**
- `InstallmentCalculator.resolveRate` (satır 39) `campaign` null olabileceğini hesaba katmıyor. Null durumunda ya varsayılan oran kullanılmalı ya da `LoanApplicationService.apply` (satır 38) daha önce kampanyayı doğrulayıp 4xx sınıfı bir domain hatası dönmelidir. İsteklerin yaklaşık %10'unda kampanyanın neden bulunamadığı da (geçersiz kampanya kodu, süresi dolmuş kampanya vb.) ayrıca incelenmeli; bu kısım loglardan doğrulanamadı.

## Testi devam ettirmek için öneri
- Önce NPE'yi kapatın; yükten bağımsız olduğu için düşük VU'da bile `http_req_failed` eşiğini sürekli kirletiyor ve kapasite ölçümünü bozuyor. Düzeltme sonrası düşük yükte (yaklaşık 1.700 istek/dk) 500 sayısı sıfır olmalı.
- Sonra scoring havuzunu büyütüp 2.100 istek/dk ve üstünde 503 görülmeyene kadar kademeli artırın. İzlenecek sinyal, scoring-service'te `level="ERROR"` ve "pool exhausted" satır sayısının sıfır kalması ve `POST /api/v1/scores` p95'inin 500 ms'nin altında kalmasıdır.
- Testin yaklaşık 150 saniyede bitmesi k6 eşik abort'una benziyor ama bu loglardan doğrulanmadı; k6 çıktısını kontrol edin.
- İlk tepe (13:25–13:30 UTC) incelenmedi; aynı komutu o pencere için çalıştırarak iki koşuyu kıyaslayabilirsiniz.

Not: `query_loki_stats` bu pencere için sıfır döndü; satır sayıları metrik sorgularından alındı, stats çıktısı doğrulanmadı.
