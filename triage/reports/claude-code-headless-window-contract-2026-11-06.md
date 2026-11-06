## Özet
Ortam **lab**; çalışan sürüm, lab tanımına göre bu klasördeki kod (`docker compose up --build`), commit doğrulanmadı. Pencere `2026-11-06T17:00:00+03:00` – `2026-11-06T17:15:00+03:00` (pencere script'i çalıştırılamadı, izin verilmedi; saat dilimli RFC3339 çifti talimattaki geri dönüş kuralıyla aynen kullanıldı). Trafik fiilen 17:05:00–17:07:14 arasında aktı: credit-service'te toplam 4365 istek, 1344 adet 5xx (%30,8). **İki farklı kök neden** var: `POST /api/v1/loans/shopping/apply` üzerinde yükten bağımsız bir NullPointerException (500) ve scoring-service'teki skor havuzu tükenmesi (503).

## Kök neden(ler)

1. **Campaign null → NullPointerException (500)** — tür: **kod bug'ı**, servis: **upstream / credit-service**. `InstallmentCalculator.resolveRate` içinde `campaign` nesnesi null kontrolü olmadan `getRate()` ile çağrılıyor; apply isteklerinin kabaca %8–12'si yükten bağımsız olarak düşüyor. İlk görülme 17:05:11 (test başladıktan 11 sn sonra, düşük trafikte).

2. **Scoring havuzu tükenmesi → 503** — tür: **yük kaynaklı (kapasite)**, servis: **downstream / scoring-service**. `ScoringService` sabit 10'luk havuzda 2000 ms bekleyip `ScoringPoolExhaustedException` ile 503 dönüyor (inflight 34–44, poolSize=10). credit-service bunu `ScoringUnavailableException` olarak 503'e yansıtıyor; credit'teki 503 bir **yansımadır**. İlk görülme 17:06:02, son görülme 17:07:13.

## Kanıt

### Küme 1 — NullPointerException (credit-service, 500)

Sorgular:
```logql
sum by (exceptionClass) (count_over_time({service="credit-service"} |= "request completed" | json httpStatus, exceptionClass | httpStatus >= 500 [1m]))
{service="credit-service"} |= "request completed" | json httpStatus, endpoint, exceptionClass, exceptionMessage, traceId, durationMs | httpStatus = 500 | line_format "{{.httpStatus}} {{.endpoint}} {{.durationMs}}ms {{.exceptionClass}} :: {{.exceptionMessage}} trace={{.traceId}}"
{service="credit-service", level="ERROR"} | json traceId, logger, message, exceptionClass, exceptionMessage, stackTrace | line_format "{{.traceId}} {{.logger}} {{.message}} {{.exceptionClass}} :: {{.exceptionMessage}} || {{.stackTrace}}"
{service=~"credit-service|scoring-service"} | traceId="6aedde9643fa1261fc074c37df94e687" | json endpoint, httpStatus, durationMs, message, exceptionClass | line_format "{{.service}} {{.level}} {{.endpoint}} {{.httpStatus}} {{.durationMs}}ms {{.message}} {{.exceptionClass}}"
```

Örnek satırlar (traceId `6aedde9643fa1261fc074c37df94e687`, zincir sırasıyla):
```
17:05:11.062 scoring-service INFO  POST /api/v1/scores                 -    -      score computed
17:05:11.065 scoring-service INFO  POST /api/v1/scores                 200  202ms  request completed
17:05:11.087 credit-service  ERROR POST /api/v1/loans/shopping/apply  -    -      unhandled exception java.lang.NullPointerException
                                   :: Cannot invoke "com.lab.credit.service.Campaign.getRate()" because "campaign" is null
                                   at c.l.c.s.InstallmentCalculator.resolveRate(InstallmentCalculator.java:39)
                                   at c.l.c.s.InstallmentCalculator.monthlyInstallment(InstallmentCalculator.java:32)
                                   at c.l.c.s.LoanApplicationService.apply(LoanApplicationService.java:38)
                                   at c.l.credit.web.LoanController.apply(LoanController.java:29)
17:05:11.092 credit-service  INFO  POST /api/v1/loans/shopping/apply  500  237ms  request completed java.lang.NullPointerException
```
Aynı desen `6aedde98ebd228f849b0a7dc42cda6b4` (500, 207 ms; scoring 200, 194 ms) ve `6aedde9a46ec7f25625809242b0195ff` (500, 227 ms; scoring 200, 211 ms) trace'lerinde de görüldü. Her üçünde de scoring-service **başarılı (200)** dönmüş; hata yalnızca credit-service'te ve stack trace `com.lab.credit...` içinde. Downstream temiz.

Yük ilişkisi (adım 6): iş mantığına ulaşan apply istekleri (201 + 500) içindeki NPE oranı:

| Dakika | 201 | 500 (NPE) | NPE oranı | NPE süresi |
|---|---|---|---|---|
| 17:05–17:06 | 816 | 106 | %11,5 | ~200–240 ms |
| 17:06–17:07 | 588 | 52 | %8,1 | ~200–240 ms |
| 17:07–17:08 | 122 | 15 | %10,9 | ~200–240 ms |

İlk görüldüğü dakikada istek/dk 1738; en yüksek yükte (2100/dk) oran %8,1, en düşük yükte (524/dk) oran %10,9. Oran yaklaşık sabit, gecikmeyle ilişkisi yok → **bug**.

### Küme 2 — Scoring havuzu tükenmesi (scoring-service, 503)

Sorgular:
```logql
sum by (httpStatus) (count_over_time({service="credit-service"} |= "request completed" | json httpStatus [1m]))
sum by (httpStatus) (count_over_time({service="scoring-service"} |= "request completed" | json httpStatus [1m]))
quantile_over_time(0.95, {service="credit-service"} |= "request completed" | json endpoint, durationMs | unwrap durationMs [1m]) by (endpoint)
{service="scoring-service", level="ERROR"} | json traceId, logger, message, exceptionClass, exceptionMessage | line_format "{{.traceId}} {{.logger}} {{.message}} {{.exceptionClass}} :: {{.exceptionMessage}}"
{service=~"credit-service|scoring-service"} | traceId="6aeddec851a9b6c2e4ef682cb8cb804e" | json endpoint, httpStatus, durationMs, message, exceptionClass | line_format "{{.service}} {{.level}} {{.endpoint}} {{.httpStatus}} {{.durationMs}}ms {{.message}} {{.exceptionClass}}"
sum by (service, httpStatus) (count_over_time({service=~"credit-service|scoring-service"} |= "request completed" | json httpStatus | httpStatus >= 500 [15m]))
sum by (service) (count_over_time({service=~"credit-service|scoring-service", level="ERROR"} [15m]))
```

Örnek satırlar (traceId `6aeddec851a9b6c2e4ef682cb8cb804e`, zincir sırasıyla):
```
17:06:02.766 scoring-service ERROR POST /api/v1/scores                 -    -       scoring pool exhausted, inflight=41, waited=2000ms, poolSize=10
17:06:02.788 scoring-service INFO  POST /api/v1/scores                 503  2022ms  request completed com.lab.scoring.service.ScoringPoolExhaustedException
17:06:02.795 credit-service  ERROR POST /api/v1/loans/shopping/apply  -    -       scoring-service unavailable HttpServerErrorException$ServiceUnavailable
17:06:02.797 credit-service  WARN  POST /api/v1/loans/shopping/apply  -    -       scoring unavailable ScoringUnavailableException
17:06:02.797 credit-service  INFO  POST /api/v1/loans/shopping/apply  503  2038ms  request completed com.lab.credit.service.ScoringUnavailableException
```
Aynı desen `6aeddeca3461cd3b82dd880640f50bf9` (scoring 503 2006 ms / credit 503 2016 ms, inflight=42) ve `6aeddecb303c237e09da68c69d8b22a7` (scoring 503 2002 ms / credit 503 2006 ms, inflight=34) trace'lerinde de görüldü.

Servisler arası sayım tutarlı: credit-service 503 = **1171**, scoring-service 503 = **1171**, scoring-service ERROR = **1171**. Fark sıfır → upstream timeout'u veya bağlantı hatası yok; her 503 downstream'de bir havuz tükenmesine karşılık geliyor. credit-service ERROR sayısı 1344 = 1171 (ServiceUnavailable) + 173 (NPE).

Dakikalık istek vs hata (credit-service, `[1m]` kovaları):

| Dakika | Toplam | 2xx | 500 | 503 | 5xx oranı | p95 apply (ms) |
|---|---|---|---|---|---|---|
| 17:04–17:05 | 2 | 2 | 0 | 0 | %0 | 384 |
| 17:05–17:06 | 1738 | 1632 | 106 | 0 | %6,1 | 1903 |
| 17:06–17:07 | 2100 | 1176 | 52 | 872 | %44,0 | 3142 |
| 17:07–17:08 | 524 | 210 | 15 | 299 | %59,9 | 3234 |

503 ilk görüldüğü dakikada istek/dk 2100 (tepe); 1738/dk'da hiç 503 yok; p95 yükle birlikte 384 → 3234 ms'ye çıkıyor; mesaj kaynak tükenmesi (`pool exhausted`, `waited=2000ms`) → **yük kaynaklı**. Not: trafik 17:07:14'te kesiliyor (k6 muhtemelen threshold ile durdu); 17:07–17:08 kovasındaki yüksek oran kuyruğun boşalma dakikasıdır.

## Etkilenen endpoint ve oran

| service | endpoint | status | adet | pencere içindeki oran |
|---|---|---|---|---|
| credit-service | POST /api/v1/loans/shopping/apply | 503 | 1171 | apply'ın %40,8'i, tüm isteklerin %26,8'i |
| credit-service | POST /api/v1/loans/shopping/apply | 500 | 173 | apply'ın %6,0'ı, tüm isteklerin %4,0'ı |
| credit-service | POST /api/v1/loans/shopping/apply | 201 | 1528 | apply'ın %53,2'si |
| credit-service | GET /api/v1/loans/{applicationId} | 200 | 1492 | %100 başarılı, 5xx yok |
| scoring-service | POST /api/v1/scores | 503 | 1171 | scores'un %40,8'i |
| scoring-service | POST /api/v1/scores | 200 | 1702 | scores'un %59,2'si |

Apply toplamı 2872; GET loans etkilenmemiş.

## Önerilen düzeltme

1. **credit-service, NPE** (lab sürümü satır numaraları): `InstallmentCalculator.resolveRate` (`InstallmentCalculator.java:39`) `campaign.getRate()` çağrısından önce null kontrolü yapmalı; `campaign` yoksa varsayılan oranı kullanmalı ya da anlamlı bir iş hatası fırlatmalı. Asıl kaynak muhtemelen `LoanApplicationService.apply` (`LoanApplicationService.java:38`) içinde kampanya aramasının bazı girdiler için null dönmesi; orada `Optional`/varsayılan kampanya ile ele alınmalı. `GlobalExceptionHandler` bu durumu 500 yerine 4xx/iş hatası olarak sınıflandırmalı. Hangi girdi koşulunun null ürettiği loglardan doğrulanmadı (istek gövdesi triage'a alınmaz).

2. **scoring-service, havuz** : `ScoringService` havuzu `poolSize=10`, bekleme 2000 ms. Tepe anında inflight 34–44'e çıkıyor; skor hesabı ~200 ms sürdüğünden teorik kapasite ~50 istek/sn. Havuz boyutunu hedef eşzamanlılığa göre büyüt (ör. 40–50) ya da havuzu CPU'ya bağlı değilse kaldır; bekleme süresini de credit-service'in read-timeout'uyla uyumlu tut. credit-service tarafında `ScoringUnavailableException` için bulkhead/circuit-breaker ve kısa süreli retry (jitter'lı) eklenebilir, ancak kök düzeltme downstream kapasitesidir.

## Testi devam ettirmek için öneri

- Önce **NPE'yi kapat**: yükten bağımsız olduğu için her aşamada ~%10 apply hatası üretiyor ve 5xx threshold'unu tek başına bozuyor. Düzeltme sonrası düşük yükte (≈1700 istek/dk) `httpStatus=500` sayısının sıfır olduğunu doğrula.
- Sonra **scoring havuzunu büyütüp** yükü kademeli artır. İzlenecek eşikler: credit-service `503/dk` (hedef 0), scoring-service `level=ERROR` içinde `pool exhausted` sayısı (hedef 0), apply p95 `durationMs` (düşük yükte ~400 ms; 2000 ms'ye yaklaşması havuz beklemesinin başladığını gösterir). 503 başlamadan önceki istek/dk değeri (bu koşuda ~1700–2100 arası) yeni havuz boyutuyla yükselmeli; yükselmiyorsa darboğaz havuz değil başka bir kaynaktır.
- Pencerede k6'ya ait `service` label'ları (`loadtest-ai-triage-lab-k6-run-*`) görüldü, talimat gereği kullanılmadı. MCP sunucusunda yalnızca okuma araçları mevcuttu; kurulum uygun.
