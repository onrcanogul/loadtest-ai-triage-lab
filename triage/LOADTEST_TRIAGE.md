# Yük Testi Triage Talimatı (Loki üzerinden kök neden analizi)

Bu dosya, herhangi bir AI istemcisinin (Claude Code, GitHub Copilot, Cursor, ...) **Grafana MCP**
sunucusu üzerinden Loki'yi sorgulayıp yük testi sırasında patlayan endpoint'lerin kök nedenini
bulması için tek kaynaktır. İstemci konfigleri sadece bu dosyayı referanslar; mantık burada yaşar.

Tek veri kaynağı Loki'dir (Tempo/Prometheus yok). Trace korelasyonu log satırlarındaki `traceId`
alanı ile yapılır; aynı `traceId` birden fazla serviste (örn. `credit-service` → `scoring-service`)
görünür, çünkü servisler arası HTTP çağrıları W3C `traceparent` başlığını taşır. Triage, yük testi
aracından (k6 vb.) tamamen bağımsızdır: hiçbir run id, test header'ı ya da k6 metriği kullanılmaz;
tek girdi zaman penceresidir.

## Alan eşleme (şablonları bu tabloyla oku)

Aşağıdaki adımlardaki LogQL şablonları laboratuvarın label/alan adlarıyla yazılmıştır. Kurumsal bir log
hattında (Alloy/Promtail/Fluent Bit konfigini biz yönetmiyoruz) adlar farklı olabilir. Triage'a başlamadan önce
"Kurumsal değer" sütununu doldur (kullanıcıya sor ya da `list_loki_label_names` / `list_loki_label_values` ve
küçük `limit`'li bir `| json` örneğiyle keşfet) ve **her sorguda lab değerini bu sütundaki karşılığıyla
değiştir**. Eşlemesi olmayan bir alan için o adımı "veri yok" diye raporla; tahmin etme.

| Şablonlardaki ad | Tür | Lab varsayılanı | Kurumsal değer | Sık karşılaşılan karşılıklar / not |
|---|---|---|---|---|
| `service` | Loki **label** | `service` (`credit-service`, `scoring-service`) | | `app`, `application`, `container`, `k8s_app`, `job` |
| `level` | Loki **label** | `level` (`INFO`/`ERROR`) | | Label değilse `\| json \| level="ERROR"` (daha pahalı) |
| `traceId` | structured metadata **ve** JSON alanı | `traceId` | | `trace_id`, `traceID`, `X-B3-TraceId`; metadata değilse `\| json \| traceId="..."` |
| `endpoint` | JSON alanı | `endpoint` (route pattern) | | `uri`, `path`, `route`, `http.route` |
| `httpStatus` | JSON alanı (sayı) | `httpStatus` | | `status`, `status_code`, `http.status_code` |
| `durationMs` | JSON alanı (sayı, ms) | `durationMs` | | `duration`, `elapsed`, `took` — birimi (ms/ns/s) doğrula |
| `exceptionClass` | JSON alanı | `exceptionClass` | | `exception`, `error.type`, stack trace'in ilk satırı |
| `exceptionMessage` | JSON alanı | `exceptionMessage` | | `error.message`, `exception_message` |
| istek-log işareti | satır içi metin (`\|=`) | `request completed` | | Her isteğe bir satır yazan access-log'un sabit metni; yoksa `endpoint` alanı dolu satırlar |
| zaman alanı | JSON alanı | `@timestamp` | | Sadece satır sıralaması için; Loki'nin kendi zaman damgası esastır |

Lab'da `customerId` ve `applicationId` alanları da vardır; triage'da **girdi olarak kullanılmaz** (bkz. Veri koruma).

## Veri koruma (zorunlu kurallar)

- Müşteri tanımlayıcıları (`customerId`, TCKN, IBAN, telefon, e-posta, ad-soyad) ve istek/yanıt gövdeleri
  **rapora, sorguya ve ara özetlere asla girmez**. Lab hattında `customerId` Loki'ye ulaşmadan maskelenir
  (`C7***`); maskeli değeri bile rapora yazma — kanıt satırlarını yalnızca `traceId` ile referansla.
- Log satırını rapora alırken şu alanlarla sınırlı kal: zaman, `service`, `level`, `endpoint`, `httpStatus`,
  `durationMs`, `exceptionClass`, `exceptionMessage`, `message`, `traceId`. `line_format` ile sadece bu
  alanları seç; ham satırı olduğu gibi yapıştırma.
- `exceptionMessage` / `message` / `stackTrace` içinde kişisel veri olabilir (örn. "customer C123456 not
  found"); böyle bir değer görürsen rapora `<maskeli>` yaz.
- Sorguları kişisel veri üzerinden filtreleme (`| customerId="..."` gibi); kümeleme ve örnekleme yalnızca
  `traceId`, `endpoint`, `httpStatus`, `exceptionClass` üzerinden yapılır.
- Sadece okuma: MCP sunucusu yalnızca datasource + Loki okuma araçlarını sunar. Dashboard, alert, annotation
  vb. oluşturma/değiştirme girişiminde bulunma; böyle bir araç görünüyorsa kurulum hatalıdır, raporda belirt.

## 0a. Ortam (önce bunu belirle)

Triage'ın verisi, istemcinin açık olduğu makinedeki kod veya local ortam **değildir**; seçilen ortamın
Grafana'sından (HTTP API) gelir. Her ortamın kendi MCP sunucusu ve env dosyası vardır:

| Ortam | Tetikleme | MCP sunucusu | Tanım dosyası | Not |
|---|---|---|---|---|
| `lab` | `ide` | `grafana-lab` | `triage/environments/lab.md` | Yerel docker compose; kod = bu klasör; sohbetten çağrılabilir |
| `dev` | `script` | `grafana-dev` | `triage/environments/dev.md` | Kurumsal DEV; yalnızca `scripts/triage.sh dev …` |
| `uat` | `script` | `grafana-uat` | `triage/environments/uat.md` | Kurumsal UAT; koda ve ortama doğrudan erişim yok, yalnızca Grafana API; yalnızca `scripts/triage.sh uat …` |

Tetikleme tipi (tanım dosyasının ilk satırındaki `<!-- triage-env type=… -->`): `ide` tipli ortamın MCP
sunucusu IDE'lerde kayıtlıdır ve sohbetten çağrılır; `script` tipli ortam hiçbir IDE'de kayıtlı değildir,
sunucusu yalnızca `scripts/triage.sh` koşarken onun çocuk süreci olarak vardır. Sohbette `script` tipli bir
ortam için triage istenirse yapma; kullanıcıyı `scripts/triage.sh <ortam> …` komutuna yönlendir.

Kurallar:
- Ortam kullanıcı tarafından açıkça verilir; verilmediyse **sor, varsayma**.
- Tanım dosyasını oku; `<doldur>` kalan alan varsa sor. Datasource uid, servis label'ları ve alan eşlemesi
  oradan gelir.
- Yalnızca o ortamın MCP sunucusunun araçlarını kullan. Başka bir Grafana sunucusu görünse bile çağırma;
  iki ortamın verisini tek raporda karıştırma.
- **Çalışan sürüm ≠ IDE'deki kod.** Tanım dosyasındaki yöntemle ortamda koşan sürümü/commit'i bul ve
  Özet'e yaz (bulunamazsa "sürüm doğrulanmadı"). Stack trace satır numaraları o sürüme aittir; "Önerilen
  düzeltme"de sınıf/metod adıyla konuş, satır numarasını ortam sürümüne göre işaretle. Triage sırasında
  kod düzenleme yapma.

## 0. Girdiler

Kullanıcıdan şunları al (vermediyse sor, varsayılanı belirt):

| Girdi        | Açıklama                                                                | Varsayılan        |
|--------------|-------------------------------------------------------------------------|-------------------|
| `env`        | Ortam adı (`lab`, `uat`, ...) — bkz. 0a                                 | yok, sorulur      |
| `from`/`to`  | Yük testinin koştuğu pencere, **yalnızca** RFC3339 + saat dilimi (`2026-11-06T14:00:00+03:00`) — bkz. "Zaman penceresi sözleşmesi" | yok, sorulur |
| `service`    | Loki `service` label değeri (giriş noktası / upstream servis)           | `credit-service`  |

### Zaman penceresi sözleşmesi (tarih aritmetiği modelde değil, script'te)

Pencereyi **asla kendin hesaplama veya yorumlama**. Girdiyi `scripts/triage-window.py`'ye ver, çıktısındaki
`from`/`to` değerlerini (UTC, `Z` ekli) her Loki sorgusunda **aynen** kullan ve raporun Özet'ine yaz:

| Kullanıcı ne verdi | Çalıştırılacak komut |
|---|---|
| İki ISO zaman (`2026-11-06T14:00:00+03:00 2026-11-06T14:35:00+03:00`) | `scripts/triage-window.py <from> <to>` |
| Tarih + saat aralığı ("6 Kasım 14:00–14:35, İstanbul") | `scripts/triage-window.py --date 2026-11-06 --from 14:00 --to 14:35 --tz +03:00` |
| "son 15 dk" / "son 2 saat" | `scripts/triage-window.py --last 15m` / `--last 2h` |
| Hiçbir şey / "bul" | 0b adımı; bulduğun pencereyi ISO olarak yaz, **onay al**, sonra `scripts/triage-window.py <from> <to>` ile sabitle |

Script saat dilimi olmayan, sırası ters, 12 saatten uzun veya gelecekteki pencereleri **reddeder**; reddederse
kullanıcıya hata mesajını ilet ve düzeltilmiş girdi iste, tahminle devam etme. Script'i çalıştıramıyorsan
(istemci komut çalıştıramıyor) yalnızca saat dilimi ekli RFC3339 çifti kabul et; başka biçimde verildiyse
bu biçimde yeniden iste.

Laboratuvarda iki servis vardır: `credit-service` (giriş noktası, k6'nın vurduğu API) ve onun çağırdığı
`scoring-service` (downstream). Adım 1-4 `service` girdisiyle, adım 5 iki servisle birlikte çalışır.
Mevcut servisleri `list_loki_label_values` (`service`) ile doğrula.

Sorguları **sadece bu pencere** için çalıştır; pencereyi genişletme.
Loki datasource uid'si ortam tanım dosyasından gelir (lab: `loki`); emin değilsen `list_datasources` ile doğrula.

MCP araçları: `query_loki_logs` (log ve metrik LogQL), `query_loki_stats`, `list_loki_label_names`,
`list_loki_label_values`. Metrik sorgularında `[1m]` aralık kullan; log sorgularında `limit` ver (≤ 200).

### 0b. Pencere bilinmiyorsa (yoğun pencereyi bul ve onaylat)

Kullanıcı yük testinin tam saatini bilmiyorsa (sadece "bugün öğleden sonra" gibi), son N saat için
5 dakikalık hacim serisini çek ve trafiğin sıçradığı aralığı bul:

```logql
# son N saat, 5 dk'lık kovalarda toplam satır sayısı (ucuz: json parse yok)
sum(count_over_time({service="credit-service"} [5m]))

# daha seçici: sadece istek-log satırları
sum(count_over_time({service="credit-service"} |= "request completed" [5m]))
```

(`query_loki_logs` metrik sorgusu; `start`/`end` = son N saat, N varsayılan 6; `step` = 5m.)
Tabandan belirgin biçimde yüksek olan ardışık kovaları birleştir; başlangıca 2 dk, bitişe 5 dk pay ekle.
Bulduğun pencereyi **kullanıcıya göster ve onaylat** ("yoğun pencere 13:42–13:48 görünüyor, bunu mu
inceleyeyim?"); onay gelmeden adım 1'e geçme. Birden fazla tepe varsa hepsini listele, kullanıcı seçsin.
`query_loki_stats` pencerenin büyüklüğünü (satır/byte) görmek için kullanılabilir.

### 0c. Sorgu limitleri (kurumsal Loki)

Kurumsal Loki'de limitler (`max_query_series`, `max_entries_limit_per_query`, `max_query_length`,
`query_timeout`) lab'dan sıkı olabilir ve her sorgu paylaşılan bir sistemi yorar:

- Zaman aralığını **gereken kadar** tut: önce pencereyi (0b) daralt, hiçbir sorguyu pencereden geniş
  çalıştırma; trace sorgularında bile `start`/`end` ver.
- `| json` yerine **seçici parse** kullan: `| json httpStatus, endpoint, durationMs` (sadece gereken
  alanlar; daha az CPU, daha az seri). Metrik sorgularında `by (...)` alanlarını az tut.
- Log sorgularında `limit` küçük olsun (varsayılan 50, en fazla 200); örnek satır için 10 yeter.
  `line_format` ile sadece gereken alanları döndür.
- Önce `|=` / `!=` satır filtresi, sonra `| json`: satır filtresi index'ten sonra en ucuz süzgeçtir.
- Metrik aralığı `[1m]`; pencere 1 saatten uzunsa `[5m]`. `quantile_over_time` + `unwrap` pahalıdır,
  endpoint başına bir kez çalıştır.
- "too many series" / "maximum of series reached" / "query timed out" alırsan: aralığı küçült, `by`
  alanlarını azalt, pencereyi böl. Hatayı ve uyguladığın daraltmayı raporda belirt.

## 1. Hacim ve hata oranının zaman içindeki şekli

Önce trafiğin ve hataların dakika bazında nasıl değiştiğine bak. Bu, "yük kaynaklı mı, koddan mı"
ayrımının temelidir.

```logql
# toplam istek / dk (status bazında)
sum by (httpStatus) (count_over_time({service="credit-service"} |= "request completed" | json [1m]))

# sadece 5xx / dk
sum(count_over_time({service="credit-service"} |= "request completed" | json | httpStatus >= 500 [1m]))

# p95 gecikme (ms), endpoint bazında
quantile_over_time(0.95, {service="credit-service"} |= "request completed" | json | unwrap durationMs [1m]) by (endpoint)

# hata sınıfı / dk  (hangi hata ne zaman başlıyor?)
sum by (exceptionClass) (count_over_time({service="credit-service"} |= "request completed" | json | httpStatus >= 500 [1m]))
```

Her dakika için **hata oranı = 5xx / toplam** hesapla ve bunu hata sınıfı bazında ayır.

## 2. 5xx istek loglarını say, endpoint + status bazında grupla

```logql
sum by (endpoint, httpStatus) (count_over_time({service="credit-service"} |= "request completed" | json | httpStatus >= 500 [15m]))
```
(`[15m]` yerine pencere uzunluğunu koy; ya da `[1m]` ile çalıştırıp topla.)

Çıktı: endpoint × status tablosu, toplam istek sayısıyla birlikte oran.

## 3. Hata mesajlarını ve exception sınıflarını kümele

```logql
# request-log satırlarındaki exception sınıfı + mesaj
{service="credit-service"} |= "request completed" | json | httpStatus >= 500 | line_format "{{.httpStatus}} {{.endpoint}} {{.exceptionClass}} :: {{.exceptionMessage}}"

# level=ERROR satırları (stack trace ve "pool exhausted" gibi anlamlı mesajlar burada)
{service="credit-service", level="ERROR"} | json | line_format "{{.traceId}} {{.logger}} {{.message}} {{.exceptionClass}}"
```

Aynı `exceptionClass` + benzer `exceptionMessage` + aynı `endpoint` = bir küme. Her küme için:
sayı, ilk görülme zamanı, son görülme zamanı, etkilenen endpoint(ler).

## 4. Her küme için 3 traceId seç, o trace'in tüm satırlarını çek

`traceId` hem satır içinde (JSON) hem de structured metadata olarak vardır; label DEĞİLDİR.

```logql
# kümeden örnek traceId'ler
{service="credit-service"} |= "request completed" | json | httpStatus = 503 | line_format "{{.traceId}}"

# bir trace'in tüm satırları (structured metadata üzerinden, json parse gerekmez)
{service="credit-service"} | traceId="<TRACE_ID>"
```

Trace satırlarından akışı oku: request-log satırı (endpoint, status, durationMs), servis logu
(applicationId; `customerId` maskelidir ve rapora alınmaz), hata satırı (exceptionClass, exceptionMessage, stackTrace). Stack trace'teki
ilk uygulama sınıfı/satırı (`com.lab...`) kök nedenin kod konumudur.

Seçtiğin trace'in satırları yalnızca `service` girdisindeki servisten geliyorsa ve hata mesajı başka bir
servise yapılan çağrıdan söz ediyorsa (örn. `exceptionClass=ScoringUnavailableException`,
`"scoring-service call failed: HttpServerErrorException$ServiceUnavailable ..."`), kök neden bu serviste
**değildir**; adım 5'e geç.

## 5. Servisler arası korelasyon (kök neden downstream'de mi, upstream'de mi?)

Aynı `traceId` çağrı zincirindeki her serviste loglanır. Adım 4'te seçtiğin her traceId için sorguyu
tek servisle sınırlamadan, zincirdeki tüm servisleri kapsayacak şekilde tekrar çalıştır:

```logql
# bir trace'in TÜM servislerdeki satırları (structured metadata üzerinden)
{service=~"credit-service|scoring-service"} | traceId="<TRACE_ID>"

# daha genel: hangi servisler bu traceId'yi loglamış?
sum by (service) (count_over_time({service=~".+"} | traceId="<TRACE_ID>" [15m]))
```

Satırları `@timestamp` sırasına koy ve `service` alanına göre oku. Sorular:

| Gözlem | Sonuç |
|---|---|
| Downstream serviste (`scoring-service`) `level=ERROR` bir satır var (örn. `scoring pool exhausted, inflight=N, waited=2000ms, poolSize=10`) ve onun `request completed` satırı `httpStatus=503`; upstream'de (`credit-service`) sadece "çağrı başarısız / 503 döndü" türü bir ERROR + 503 var | Kök neden **downstream** servistedir. Upstream'deki 503 bir **yansımadır**; düzeltme downstream'de (havuz boyutu, kapasite, timeout). Kümeyi downstream servisin adıyla raporla. |
| Downstream serviste trace'e ait satır **yok** ya da tüm satırları başarılı (`httpStatus=200`, ERROR yok); hata sadece upstream'de (`NullPointerException`, stack trace `com.lab.credit...`) | Kök neden **upstream** servistedir (kod bug'ı ya da upstream'in kendi kaynağı). Downstream temize çıkar. |
| Downstream'de hiç satır yok ve upstream'deki hata bir bağlantı/timeout hatası (`ResourceAccessException`, `HttpTimeoutException`, `ConnectException`) | Downstream'e **ulaşılamıyor** (ayakta değil, ağ, upstream'in timeout'u downstream'in gerçek süresinden kısa). Her iki serviste de kapasite/timeout ayarlarına bak; `scoring-service`'in kendi `request completed` satırlarının `durationMs` değerini upstream'in `read-timeout`'u ile kıyasla. |

Her küme için şunu yaz: *kök nedenin yaşadığı servis*, *zincirdeki diğer servislerin bu trace'te ne
gördüğü* (status + mesaj) ve iki tarafın log satırlarından birer örnek (aynı traceId ile).

Ayrıca kümeyi downstream tarafından da say, böylece upstream'deki 503 sayısı ile downstream'deki 503 /
ERROR sayısı tutarlı mı görürsün (eşit değilse aradaki fark upstream timeout'u ya da bağlantı hatasıdır):

```logql
sum by (service, httpStatus) (count_over_time({service=~"credit-service|scoring-service"} |= "request completed" | json | httpStatus >= 500 [15m]))
sum by (service) (count_over_time({service=~"credit-service|scoring-service", level="ERROR"} [15m]))
```

## 6. Yük kaynaklı mı, koddan mı? (hata oranının şekline bak)

Adım 1'deki dakikalık serileri kullan. İstek sayısı (yük) zamanla artarken:

| Gözlem                                                                 | Sonuç                        |
|------------------------------------------------------------------------|------------------------------|
| Hata sayısı/oranı istek sayısıyla **birlikte artıyor**, düşük trafikte yok veya çok az; p95 gecikme de yükle birlikte artıyor; mesajlar kaynak tükenmesi (pool, timeout, 503) anlatıyor | **Yük kaynaklı** (kapasite / kaynak sınırı) |
| Hata oranı istek sayısından **bağımsız, yaklaşık sabit** (örn. her dakikada isteklerin ~%5'i), düşük trafikte de var; gecikmeyle ilişkisi yok; mesaj bir programlama hatası (NPE, IllegalArgument, ClassCast...) | **Koddan kaynaklı bug** (yükten bağımsız) |

Her küme için şu üçlüyü yaz: *hatanın ilk görüldüğü dakikadaki istek/dk*, *en yüksek istek/dk'daki
hata oranı*, *en düşük istek/dk'daki hata oranı*. Oran sabitse bug, yükle büyüyorsa kapasite.

## 7. Rapor formatı (Türkçe)

```
## Özet
2-4 cümle: ortam ve çalışan sürüm, pencere, toplam istek, toplam 5xx, kaç farklı kök neden.

## Kök neden(ler)
Her biri için: ad, tür (yük kaynaklı / kod bug'ı), **kök nedenin yaşadığı servis** (downstream / upstream),
kısa açıklama, ilk görülme zamanı.

## Kanıt
Her kök neden için: kullanılan LogQL sorguları (kopyalanabilir), 2-3 örnek log satırı
(traceId ile; zincirde birden fazla servis varsa aynı traceId'nin her servisteki satırı; müşteri
tanımlayıcısı ve istek gövdesi olmadan — bkz. Veri koruma),
dakikalık istek vs hata tablosu ya da özeti.

## Etkilenen endpoint ve oran
service | endpoint | status | adet | pencere içindeki oran

## Önerilen düzeltme
Kod/konfig düzeyinde somut öneri (sınıf/metod adı ile).

## Testi devam ettirmek için öneri
Hangi hata modu kapatılırsa/düzeltilirse testin bir sonraki aşamaya geçebileceği, hangi
threshold'un nasıl gözlemlenmesi gerektiği.
```

Varsayım yapma: bir kümeyi kanıt (örnek satır + sorgu) olmadan rapora koyma. Emin olmadığın
noktaları "doğrulanmadı" diye işaretle.
