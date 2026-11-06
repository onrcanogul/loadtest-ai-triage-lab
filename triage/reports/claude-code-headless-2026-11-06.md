Tüm adımlar tamamlandı. Rapor aşağıda.

## Özet
Pencere 2026-11-06T13:15:00Z–13:35:00Z, servis `credit-service`; trafik yalnızca 13:25–13:29 arasında var (test 13:26:48–13:28:51). Toplam 4394 istek, 1350 adet 5xx (%30,7). Tüm 5xx'ler tek endpoint'te (`POST /api/v1/loans/shopping/apply`) ve iki farklı kök nedene ayrılıyor: yükten bağımsız bir NullPointerException (174 adet, HTTP 500) ve yükle birlikte büyüyen scoring bağlantı havuzu tükenmesi (1176 adet, HTTP 503). `GET /api/v1/loans/{applicationId}` (1510 istek) hiç hata vermedi.

## Kök neden(ler)

**1. `InstallmentCalculator.resolveRate` içinde null `campaign` (NPE)** — tür: **kod bug'ı (yükten bağımsız)**. `LoanApplicationService.apply` → `InstallmentCalculator.monthlyInstallment` → `resolveRate` zincirinde `campaign.getRate()` null referans üzerinde çağrılıyor; `GlobalExceptionHandler` bunu "unhandled exception" olarak 500'e çeviriyor. Scoring aşamasını geçen isteklerin yaklaşık %10'unda, trafik seviyesinden bağımsız olarak oluşuyor. İlk görülme: 13:25:27Z (test başlamadan önce, 2 istek/dk iken, customerId C2 — muhtemelen manuel/smoke isteği; kaynağı doğrulanmadı). Test içinde ilk görülme: 13:26:52Z.

**2. `ScoringClient` bağlantı havuzu tükenmesi (ScoringUnavailableException → 503)** — tür: **yük kaynaklı (kapasite sınırı)**. Havuz boyutu 10 (`poolSize=10`), bekleme süresi 2000 ms; eşzamanlı istek (`inflight`) 33'ü aşınca istekler 2 s bekleyip 503 ile düşüyor. `inflight` test boyunca 33'ten 80'e kadar tırmandı. Düşük trafikte hiç yok. İlk görülme: 13:27:42Z.

## Kanıt

### Dakikalık istek vs hata (yalnızca `POST /api/v1/loans/shopping/apply`)

| Dakika (UTC) | 201 | 500 NPE | 503 pool | Toplam | 503 oranı | NPE / tüm | NPE / scoring'i geçen (201+500) | p95 ms |
|---|---|---|---|---|---|---|---|---|
| 13:25–13:26 | 1 | 1 | 0 | 2 | %0 | — (2 örnek) | — | 260 |
| 13:26–13:27 | 71 | 14 | 0 | 85 | %0 | %16,5 | %16,5 | 237 |
| 13:27–13:28 | 1019 | 107 | 114 | 1240 | %9,2 | %8,6 | %9,5 | 2729 |
| 13:28–13:29 | 438 | 52 | 1062 | 1552 | %68,4 | %3,4 | %10,6 | 3211 |

15 saniyelik çözünürlükte (13:26:30–13:29:00) NPE'nin scoring'i geçen isteklere oranı %7,8–%13 bandında sabit kalırken, 503 sayısı 0 → 4 → 110 → 236 → 323 → 321 ile tırmandı ve `inflight` 33 → 80 arttı. 503'lü tüm isteklerin süresi 2001–2031 ms (= 2000 ms havuz bekleme süresi).

Adım 5 üçlüsü:
- **NPE:** ilk görüldüğü dakikada 2 istek/dk (test öncesi); en yüksek yükte (1552/dk) scoring'i geçenlerin %10,6'sı; en düşük yükte (85/dk) %16,5. Oran yükle büyümüyor → bug.
- **503:** ilk görüldüğü dakikada 1240 istek/dk; en yüksek yükte %68,4; en düşük yükte %0. Oran yükle büyüyor, gecikme 237 ms → 3211 ms → kapasite.

Not: scoring çağrısının taksit hesabından önce yapıldığı doğrudan loglardan doğrulanmadı; ancak 13:28:52'deki NPE isteklerinin 2000+ ms sürmesi (havuzda bekleyip sonra NPE'ye düşmeleri) bu sırayı destekliyor.

### Kullanılan LogQL sorguları

```logql
# dakikalık status dağılımı
sum by (httpStatus) (count_over_time({service="credit-service"} |= "request completed" | json [1m]))

# dakikalık 5xx
sum(count_over_time({service="credit-service"} |= "request completed" | json | httpStatus >= 500 [1m]))

# p95 gecikme, endpoint bazında
quantile_over_time(0.95, {service="credit-service"} |= "request completed" | json | unwrap durationMs [1m]) by (endpoint)

# hata sınıfı / dk
sum by (exceptionClass) (count_over_time({service="credit-service"} |= "request completed" | json | httpStatus >= 500 [1m]))

# endpoint x status (pencere toplamı, instant @13:35Z)
sum by (endpoint, httpStatus) (count_over_time({service="credit-service"} |= "request completed" | json | httpStatus >= 500 [20m]))
sum by (endpoint) (count_over_time({service="credit-service"} |= "request completed" | json [20m]))

# yalnızca apply endpoint'i, dakikalık ve 15 sn'lik
sum by (endpoint, httpStatus) (count_over_time({service="credit-service"} |= "request completed" | json | endpoint="POST /api/v1/loans/shopping/apply" [1m]))
sum by (httpStatus) (count_over_time({service="credit-service"} |= "request completed" | json | endpoint="POST /api/v1/loans/shopping/apply" [15s]))

# küme mesajları
sum by (exceptionClass, exceptionMessage) (count_over_time({service="credit-service"} |= "request completed" | json | httpStatus >= 500 [20m]))
sum by (logger, exceptionClass, message) (count_over_time({service="credit-service", level="ERROR"} | json [20m]))

# örnek satırlar / traceId
{service="credit-service"} |= "request completed" | json | httpStatus = 500 | line_format "{{.traceId}} {{.httpStatus}} {{.endpoint}} {{.durationMs}}ms {{.exceptionClass}} :: {{.exceptionMessage}}"
{service="credit-service"} |= "request completed" | json | httpStatus = 503 | line_format "{{.traceId}} {{.httpStatus}} {{.endpoint}} {{.durationMs}}ms {{.exceptionClass}} :: {{.exceptionMessage}}"
{service="credit-service", level="ERROR"} | json | line_format "{{.traceId}} {{.logger}} {{.message}} {{.exceptionClass}} :: {{.exceptionMessage}}"

# trace'in tüm satırları
{service="credit-service"} | traceId="6aedd59c75193087ac58adbd913b5bc3"
{service="credit-service"} | traceId="6aedd5cc24909f6069c45a32ac1499a9"
```

### Küme 1 — NPE örnek satırları (174 adet, ilk 13:25:27Z, son 13:28:52Z)

```
13:26:52.335Z traceId=6aedd59c75193087ac58adbd913b5bc3 500 POST /api/v1/loans/shopping/apply 210ms customerId=C929647
  java.lang.NullPointerException :: Cannot invoke "com.lab.credit.service.Campaign.getRate()" because "campaign" is null
13:25:27.934Z traceId=6aedd5478846f56d277a76c693d18fed 500 POST /api/v1/loans/shopping/apply 205ms customerId=C2 (test öncesi, 2 istek/dk)
13:28:52.866Z traceId=6aedd61273f2771d177ddb25e497848f 500 POST /api/v1/loans/shopping/apply 2599ms customerId=C471390

Stack trace (GlobalExceptionHandler, level=ERROR, "unhandled exception"):
  at c.l.c.s.InstallmentCalculator.resolveRate(InstallmentCalculator.java:39)
  at c.l.c.s.InstallmentCalculator.monthlyInstallment(InstallmentCalculator.java:32)
  at c.l.c.s.LoanApplicationService.apply(LoanApplicationService.java:38)
  at c.l.credit.web.LoanController.apply(LoanController.java:29)
```

Her NPE trace'i 2 satırdan oluşuyor: ERROR (stack trace) + request-log (500). Hangi girdinin `campaign`'i null bıraktığı loglarda yok (doğrulanmadı).

### Küme 2 — Scoring havuzu 503 örnek satırları (1176 adet, ilk 13:27:42Z, son 13:28:52Z)

```
13:27:42.102Z traceId=6aedd5cc24909f6069c45a32ac1499a9 ERROR com.lab.credit.service.ScoringClient
  "scoring pool exhausted, inflight=41, waited=2000ms, poolSize=10"
13:27:42.117Z traceId=6aedd5cc24909f6069c45a32ac1499a9 503 POST /api/v1/loans/shopping/apply 2017ms
  com.lab.credit.service.ScoringUnavailableException :: scoring service connection pool exhausted (inflight=41)
13:27:45.102Z traceId=6aedd5cfdf79a0f90b3a2fa44a9db626 503 2003ms (inflight=35)
13:28:52.380Z traceId=6aedd6126de4c9bdcfef171d1a5e001a 503 2001ms (inflight=80)
```

Her 503 trace'i 3 satır: ScoringClient ERROR → GlobalExceptionHandler WARN "scoring unavailable" → request-log 503. Mesajlardaki `inflight` değeri 33 ile 80 arasında; en yoğun değerler 60–66 (her biri 50+ adet).

## Etkilenen endpoint ve oran

| endpoint | status | adet | pencere içindeki oran |
|---|---|---|---|
| POST /api/v1/loans/shopping/apply | 503 (ScoringUnavailableException) | 1176 | endpoint'in %40,8'i, tüm isteklerin %26,8'i |
| POST /api/v1/loans/shopping/apply | 500 (NullPointerException) | 174 | endpoint'in %6,0'ı, tüm isteklerin %4,0'ı |
| POST /api/v1/loans/shopping/apply | 201 | 1529 | %53,1 |
| GET /api/v1/loans/{applicationId} | 200 | 1510 | 5xx yok |
| GET /api/v1/loans/nope | 404 | 1 | test dışı tekil istek |
| GET /actuator/health | 200 | 4 | — |

## Önerilen düzeltme

**NPE (önce bu):**
- `InstallmentCalculator.resolveRate` (InstallmentCalculator.java:39): `campaign` null olduğunda `getRate()` çağırmak yerine varsayılan/standart orana düş (`Optional.ofNullable(campaign).map(Campaign::getRate).orElse(defaultRate)`), ya da kampanya zorunluysa `LoanApplicationService.apply` (satır 38'den önce) içinde doğrulayıp anlamlı bir iş hatası (400/422, örn. `CampaignNotFoundException`) fırlat.
- `GlobalExceptionHandler`'da NPE'nin 500 "unhandled exception" olarak sızması yerine iş hataları için ayrı handler ekle; ayrıca kampanya çözümleme sonucunu (campaignId / null) servis loguna yaz ki hangi girdinin null ürettiği görülebilsin.

**Scoring havuzu 503:**
- `ScoringClient` havuz boyutunu 10'dan, hedef eşzamanlılığa göre artır (gözlenen `inflight` 80'e çıktı; Tomcat thread sayısıyla hizalı, örn. 50–100) ve/veya scoring çağrı süresini düşür.
- 2000 ms blocking bekleme, Tomcat thread'lerini kilitliyor ve tüm endpoint'in p95'ini 3,2 s'ye çıkarıyor. Bekleme süresini kısalt (örn. 200–500 ms) ve havuz doluyken hızlı 429/503 dön (bulkhead + circuit breaker, Resilience4j gibi); kuyruk uzunluğunu sınırla.
- Havuz kullanımı ve `inflight` için metrik/alarm ekle; şu an tek sinyal ERROR log satırı.

## Testi devam ettirmek için öneri
1. **Önce NPE'yi kapat.** Yükten bağımsız ~%10 (scoring'i geçen istekler bazında) hata oranı, 5xx eşiğini düşük VU'da bile deliyor ve 503 kapasite sınırının nerede olduğunu maskeliyor. NPE düzeltildikten sonra düşük yükte (≤ 85 istek/dk) 5xx = 0 olmalı; bu doğrulanmadan ramp'e geçme.
2. **Sonra havuz sınırını test et.** Düzeltmeden sonra ramp'i tekrarla; `ScoringClient` "scoring pool exhausted" satırlarının ilk göründüğü anı ve o andaki `inflight` değerini "diz noktası" olarak kaydet (bu koşuda ~33 eşzamanlı istek, 13:27:42Z). Havuz büyütüldükten sonra yeni diz noktasını aynı yöntemle bul.
3. **Gözlenecek eşikler:** `POST /api/v1/loans/shopping/apply` için 5xx oranı < %1 ve p95 < 500 ms (bu koşuda hatasız dakikada 237–260 ms idi). 503 oranı ve p95'in birlikte yükseldiği ilk dakika, kapasite sınırının aşıldığı noktadır. `GET /api/v1/loans/{applicationId}` bu koşuda temizdi; aynı eşikle kontrol grubu olarak izlenebilir.
