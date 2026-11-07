# loadtest-ai-triage-lab

> English version: [README.en.md](README.en.md)

Yük testi sırasında patlayan endpoint'leri **AI ile triage etmek** için local laboratuvar.
İki Spring Boot servisi (`credit-service` → `scoring-service`) yük altında bilerek patlar, logları Loki'ye
akar, Grafana'da görünür ve herhangi bir AI istemcisi (Claude Code, GitHub Copilot, Cursor) **Grafana MCP**
üzerinden Loki'yi sorgulayıp kök neden raporu üretir.

- Tek veri kaynağı **Loki** (Tempo/Prometheus yok). Trace korelasyonu loglardaki `traceId` ile; aynı `traceId`
  iki serviste de loglanır (W3C `traceparent`), böylece kök nedenin hangi serviste olduğu loglardan okunur.
- Triage mantığı **tek dosyada**: [`triage/LOADTEST_TRIAGE.md`](triage/LOADTEST_TRIAGE.md). İstemci konfigleri sadece onu referanslar.
- Triage **yük testinden bağımsız**: tek girdi zaman penceresi (+ opsiyonel servis adı). Servis ve triage k6'dan habersizdir.

## Mimari

```
k6 (profile: loadtest) ──HTTP──> credit-service:8080 ──HTTP + traceparent──> scoring-service:8081
                                 (Spring Boot, JSON log → stdout)           (Spring Boot, JSON log → stdout)
                                        │ docker log                               │ docker log
                                        └──────────────────┬───────────────────────┘
                                                           ▼
                                  alloy (discovery.docker + loki.source.docker)
                                        │ labels: service, level  |  structured metadata: traceId
                                        ▼
                                      loki:3100  <── grafana:3000 (dashboard + datasource uid=loki)
                                                          ▲
                              AI istemcisi ──stdio──> mcp-grafana (binary; docker sadece lab) ── service account token
```

Aynı istek iki serviste de **aynı `traceId`** ile loglanır: `credit-service`'in auto-configure edilmiş
`RestClient.Builder`'ı (Micrometer Observation) giden çağrıya W3C `traceparent` başlığını ekler, `scoring-service`
bu başlığı devam ettirir. Alloy her iki konteyneri de konteyner adından `service` label'ı ile toplar; ek konfig yok.

### credit-service (Spring Boot 3.4, Java 21)
Alışveriş kredisi API'si, paket `com.lab.credit`:

| Endpoint | Açıklama |
|---|---|
| `POST /api/v1/loans/shopping/apply` | body `{customerId, amount, installmentCount, campaignCode?}` → `201 {applicationId, status, monthlyInstallment}` |
| `GET /api/v1/loans/{applicationId}` | `200` veya `404` |
| `GET /actuator/health` | sağlık |

Akış: `LoanController → LoanApplicationService → ScoringClient (HTTP → scoring-service) → InstallmentCalculator → LoanApplicationRepository (ConcurrentHashMap)`.

`ScoringClient`, `scoring.base-url` (env `SCORING_BASE_URL`, varsayılan `http://scoring-service:8081`) adresine
`POST /api/v1/scores` atar; connect timeout 1s, read timeout 5s (scoring-service'in 2s havuz beklemesi + en kötü
gecikmeden uzun, ki sinyal bizim timeout'umuz değil onun 503'ü olsun). scoring-service'ten gelen 5xx ya da bağlantı /
timeout hataları `ScoringUnavailableException` → **503**'e çevrilir ve credit-service'te ERROR seviyesinde
`exceptionClass` / `exceptionMessage` ile loglanır (`scoring-service unavailable`).

### scoring-service (Spring Boot 3.4, Java 21)
Kredi skoru servisi (KKB yerine geçer), paket `com.lab.scoring`, port 8081:

| Endpoint | Açıklama |
|---|---|
| `POST /api/v1/scores` | body `{customerId}` → `200 {customerId, score}`; havuz doluysa **503** `{error: SCORING_POOL_EXHAUSTED}` |
| `GET /actuator/health` | sağlık |

Akış: `ScoreController → ScoringService` (Semaphore havuzu + deterministik skor).

**Kasıtlı hata modları** (ikisi de varsayılan açık, env ile kapatılır; her biri kendi servisinde yaşar):

| Env | Servis / sınıf | Davranış |
|---|---|---|
| `FAILURE_POOL_EXHAUSTION=true` | `scoring-service` / `ScoringService` | `Semaphore(10)` "bağlantı havuzu". Gecikme = 150ms + 15ms × inflight + jitter; eşzamanlılık arttıkça gecikme büyür, `tryAcquire(2s)` başarısız olunca `ScoringPoolExhaustedException` → **503**. ERROR log: `scoring pool exhausted, inflight=N, waited=2000ms, poolSize=10`. `credit-service` bu 503'ü `ScoringUnavailableException` → **503** olarak yansıtır. **Yük kaynaklı, kök neden downstream'de.** |
| `FAILURE_NPE_BUG=true` | `credit-service` / `InstallmentCalculator` | `campaignCode` null ve `installmentCount >= 9` ise `campaign.getRate()` üzerinde **NullPointerException** → `@RestControllerAdvice` ile **500**, stack trace loglanır. **Yükten bağımsız kod bug'ı, kök neden upstream'de.** |

**Loglama (iki serviste aynı):** `logstash-logback-encoder` ile stdout'a tek satır JSON; `micrometer-tracing-bridge-brave`
ile MDC'de `traceId`/`spanId` (exporter yok, sampling 1.0, W3C propagation). Her satırda `@timestamp, level, logger, message,
traceId, spanId, service=<credit-service|scoring-service>` ve varsa `customerId, applicationId, endpoint`. `RequestLogFilter`
her istek için bir `request completed` satırı yazar: `endpoint` (route pattern), `httpStatus`, `durationMs`,
hata varsa `exceptionClass`/`exceptionMessage`.

## Çalıştırma

```bash
docker compose up -d --build
```

```bash
curl -s localhost:8080/actuator/health && curl -s localhost:8081/actuator/health
```

Tek bir isteğin iki serviste aynı `traceId` ile loglandığını görmek için:

```bash
curl -s -X POST localhost:8080/api/v1/loans/shopping/apply -H 'Content-Type: application/json' -d '{"customerId":"C100001","amount":12000,"installmentCount":6,"campaignCode":"POS2025"}' && docker logs credit-service 2>&1 | tail -3 | jq -c '{service,traceId,message}' && docker logs scoring-service 2>&1 | tail -3 | jq -c '{service,traceId,message}'
```

Yük testi (k6 sadece hata üretmek için var; `loadtest` profili altında):

```bash
docker compose --profile loadtest run --rm k6
```

Senaryo (`k6/shopping-loan-load.js`): 0→20 VU 30s, 20→80 VU 60s, 80 VU 60s, →0 20s. İsteklerin %90'ı geçerli
`campaignCode` ile, %10'u `campaignCode` olmadan ve `installmentCount` 9/12 (NPE'yi tetikler).
Threshold'lar: `http_req_failed rate<0.05` (**abortOnFail**) ve `http_req_duration p(95)<800ms`.

> **Karar (netleşmeyen nokta):** `delayAbortEval` spesifikasyondaki 30s yerine **120s**. 30s olsaydı
> yalnızca arka plandaki ~%5 NPE hatası, daha 20 VU'dayken testi abort ederdi ve yük kaynaklı havuz tükenmesi
> hiç ortaya çıkmazdı. 120s ile rampa 80 VU'ya ulaşır, 503'ler başlar, sonra test "patlayıp" abort olur.
> Loki'de iki kök nedenin de görünmesi için bu gerekli.

## Grafana'da nereye bakılır

http://localhost:3000 (admin / admin) → Dashboards → **Credit Service - Load Test**:

- **Error rate (5xx / dk)** ve **toplam istek / dk** — yükle birlikte büyüyen hata, yük kaynaklı demektir.
- **Status code dağılımı** — 201/200 yanında 500 (NPE) ve 503 (havuz) nasıl değişiyor.
- **p95 durationMs** (Loki `unwrap`) — 800ms eşiği kırmızı.
- **Hata sınıfları / dk** — `NullPointerException` sabit, `ScoringUnavailableException` yükle artar.
- **Son hata logları** — `{service="$service", level="ERROR"}`.

`service` değişkeni `credit-service` / `scoring-service` arasında geçiş yapar: credit-service'te 503'ler
`ScoringUnavailableException` olarak, scoring-service'te `scoring pool exhausted` ERROR satırları ve
`POST /api/v1/scores` 503'leri olarak görünür.

Explore'da işe yarayan sorgular:

```logql
sum by (httpStatus) (count_over_time({service="credit-service"} |= "request completed" | json [1m]))
quantile_over_time(0.95, {service="credit-service"} |= "request completed" | json | unwrap durationMs [1m]) by (endpoint)
{service=~"credit-service|scoring-service"} | traceId="<TRACE_ID>"
sum by (service, httpStatus) (count_over_time({service=~"credit-service|scoring-service"} |= "request completed" | json | httpStatus >= 500 [1m]))
```

Label'lar sadece `service` ve `level`; `traceId` structured metadata'dadır (yüksek kardinalite label olmaz).

## AI triage: Grafana MCP

### 1. Service account token

```bash
scripts/create-grafana-sa-token.sh
```

Grafana API ile (admin/admin) `ai-triage` adlı **Viewer** service account ve bir token oluşturur, `.env.mcp.lab`
dosyasına `GRAFANA_URL` + `GRAFANA_SERVICE_ACCOUNT_TOKEN` yazar (`.gitignore`'da). Kurumsal bir ortam için
(ör. `uat`) token'ı Grafana yöneticilerinden alıp `.env.mcp.uat.example`'ı `.env.mcp.uat` olarak doldurursunuz.
(Spesifikasyondaki `copilot-triage` adı, istemciden bağımsız olmak için `ai-triage` yapıldı.)

### 2. MCP sunucusu (tüm istemciler için tek nokta, ortam başına bir sunucu)

**Ortam ayrımı.** Triage'ın verisi, IDE'deki kod veya local ortam değildir; seçilen ortamın Grafana'sından API ile
gelir. Bu yüzden her ortamın kendi MCP sunucusu (`grafana-<ortam>`), kendi env dosyası (`.env.mcp.<ortam>`) ve kendi
tanım dosyası (`triage/environments/<ortam>.md`: datasource uid, servis label'ları, alan eşlemesi, çalışan sürümün
nereden okunacağı) vardır. UAT'ye, test script'lerine veya UAT'deki koda erişim gerekmez; geliştirici makinesinden
Grafana URL'sine ağ erişimi (VPN/proxy) yeter.

**Ortam tipi: `ide` ya da `script`.** Tanım dosyasının ilk satırı `<!-- triage-env type=ide|script -->` ortamın nasıl
tetiklenebileceğini belirler ve bu, "istemediğimiz hiçbir akış UAT'ye uğramasın" gereksiniminin teknik karşılığıdır:

| Tip | Ortamlar | IDE'de kayıtlı mı | Tetikleme | Sunucunun ömrü |
|---|---|---|---|---|
| `ide` | yalnızca `lab` | evet (`.mcp.json`, `.vscode/mcp.json`, `.cursor/mcp.json`) | sohbetten (`/loadtest-triage lab …`, `/lab-loadtest-triage`) ve `scripts/triage.sh lab …` | IDE yönetir |
| `script` | `dev`, `uat` (kurumsal) | **hayır, hiçbir yerde** | **yalnızca** `scripts/triage.sh <ortam> <from> <to>` | o komutun çocuk süreci; komut bitince ölür |

`script` tipli bir ortam için `scripts/grafana-mcp.sh` ancak `triage.sh`'in verdiği canlı bir kilit dosyasıyla
(`LOADTEST_TRIAGE_LOCK`, içinde çalışan `triage.sh`'in pid'i) başlar; kilit yoksa ya da pid ölmüşse başlamaz. Yani bir
IDE sohbeti, bir prompt dosyası ya da loglardan gelen bir "talimat" UAT'ye ulaşamaz, çünkü ulaşacağı bir sunucu yoktur.
Copilot'un sohbet tarafında bunu sağlayan bir mekanizma yoktur (MCP sunucusu workspace'e kayıtlıysa her sohbet görür,
prompt dosyasındaki `tools` yalnızca o prompt'u daraltır); kilit bu yüzden istemcide değil sunucudadır. Tanım dosyası
ya da işaret yoksa ortam `script` sayılır (kapalı varsayılan). Yeni bir ortam eklemek = env dosyası + tanım dosyası;
`ide` tipliyse ayrıca istemci konfiglerine bir satır. `scripts/gen-prompts.sh --check`, `script` tipli bir ortamın
IDE konfiglerine ya da prompt dosyalarına sızmasını CI'da yakalar.

`scripts/grafana-mcp.sh <ortam>` → `.env.mcp.<ortam>`'ı okur ve `mcp/grafana` sunucusunu **sadece okuma, sadece Loki** modunda
(`-t stdio --enabled-tools datasource,loki --disable-write`) başlatır. **Varsayılan mod native binary'dir**: PATH'teki ya da
`MCP_GRAFANA_BIN`'deki `mcp-grafana` çalıştırılır, Docker gerekmez. Docker'a (`docker run mcp/grafana`) yalnızca **lab**
ortamı, binary yoksa, kendiliğinden düşer; `uat` gibi diğer ortamlar asla düşmez (bkz. "Kurumsal ortam notları").
Sunduğu araç listesi `scripts/mcp-tools-list.sh <ortam>` ile görülür (9 araç).

Her istemci sadece bu script'i çalıştıran ince bir konfig taşır; **yeni bir istemci eklemek = bir konfig dosyası**:

| İstemci | MCP konfigi (yalnızca `ide` tipli `lab`) | Sohbetten triage (lab) | Kilitli ortam (dev, uat) |
|---|---|---|---|
| Claude Code | [`.mcp.json`](.mcp.json) (`grafana-lab`) | [`.claude/skills/loadtest-triage/SKILL.md`](.claude/skills/loadtest-triage/SKILL.md) → `/loadtest-triage lab --last 15m` | `scripts/triage.sh uat … --agent claude` |
| GitHub Copilot (VS Code) | [`.vscode/mcp.json`](.vscode/mcp.json) (`grafana-lab`) | [`.github/prompts/lab-loadtest-triage.prompt.md`](.github/prompts/lab-loadtest-triage.prompt.md) → Chat'te `/lab-loadtest-triage` | `scripts/triage.sh uat … --agent copilot` (Copilot CLI) |
| Cursor | [`.cursor/mcp.json`](.cursor/mcp.json) (`grafana-lab`) | Chat'e "`triage/LOADTEST_TRIAGE.md`'yi lab ortamı, son 15 dk için uygula" | `scripts/triage.sh` (claude ya da copilot CLI) |

Hepsi aynı script'e, aynı env değişkenlerine bağlanır; içerik [`triage/LOADTEST_TRIAGE.md`](triage/LOADTEST_TRIAGE.md)'de tek kopyadır.

**Gündelik akıştan izolasyon (lab).** Lab'de bile triage normal kodlama skill/prompt'larından ayrı tutulur: Copilot
prompt dosyası yalnızca `/lab-loadtest-triage` açık çağrısıyla çalışır ve `tools` alanıyla sadece `grafana-lab`
araçlarına izinlidir. Bu dosya elle yazılmaz: `scripts/gen-prompts.sh`, `ide` tipli her ortam için tek şablondan
(`triage/templates/loadtest-triage.prompt.md.tmpl`) üretir, `script` tipli ortamların prompt dosyasını siler;
`scripts/gen-prompts.sh --check` CI'da kaymayı ve sızmayı yakalar. `copilot-instructions.md` gibi her zaman yüklenen
dosyalara triage talimatı **konmaz**. Claude Code skill'i açık `/loadtest-triage <ortam>` çağrısı ister, `script` tipli
bir ortam istenirse triage yapmaz ve `triage.sh` komutunu verir. Triage sırasında kod düzenlenmez; çalışan sürüm
IDE'deki koddan farklı olabilir (bkz. `triage/environments/uat.md`, "Sürüm kuralı").
İstemciniz relatif `./scripts/grafana-mcp.sh` yolunu çözemezse mutlak yol yazın.

**Binary kurulumu (UAT için zorunlu, lab için isteğe bağlı):** `go install github.com/grafana/mcp-grafana/cmd/mcp-grafana@latest`
ya da GitHub release'den indirin; `.env.mcp.<ortam>`'a `MCP_GRAFANA_BIN=/path/to/mcp-grafana` yazın. İstemci konfigleri
değişmez. Binary modda `GRAFANA_URL` varsayılanı `http://localhost:3000`'dir (host.docker.internal değil).

### 3. Triage'ı çalıştırma

**Kilitli ortamlar (dev, uat): tek komut.**

```bash
scripts/triage.sh uat 2026-11-06T14:00:00+03:00 2026-11-06T14:40:00+03:00 --service credit-service
```

Pencere biçimleri: iki RFC3339 zaman, `--last 30m`, ya da `--date 2026-11-06 --from 14:00 --to 14:40 --tz +03:00`.
Seçenekler: `--service <ad>` (varsayılan `credit-service`), `--agent claude|copilot` (varsayılan: PATH'te `copilot` varsa
o, yoksa `claude`), `--out <dosya>`, `--dry-run` (hiçbir şey çalıştırmadan komutu, geçici MCP konfigini ve prompt'u
gösterir; bankada ilk gün bununla başlayın). Script sırasıyla: pencereyi `triage-window.py` ile doğrular → kilit dosyası
ve yalnızca bu koşuya ait geçici bir MCP konfigi yazar → sabit prompt'u (talimat + ortam tanımı + pencere, dosya içerikleri
gömülü) agent CLI'ya etkileşimsiz verir; agent'ın dosya, kabuk veya yazma aracı yoktur, yalnızca `grafana-<ortam>`'ın
9 okuma aracı vardır → raporu `triage/reports/<ortam>-<from>-<to>-<servis>.md` olarak yazar → çıkışta (kesilse bile)
kilidi ve geçici konfigi siler, sunucu ölür. Sunucunun önünde `scripts/mcp-audit-proxy.py` durur: her `tools/call`
(araç adı, LogQL, zaman aralığı; log içeriği değil) `…audit.jsonl` olarak raporun yanına yazılır. **Sıfır çağrı = rapor
reddedilir** (çıkış 3, metin `.rejected.md` olarak saklanır): lab'de Copilot CLI izin sözdizimi yanlışken model tek sorgu
atmadan tamamen uydurma bir rapor yazmıştı; bu kilit o durumu yakalar ve "kim, ne zaman, neyi sorguladı" sorusunu cevaplar. Claude için komut `claude -p --mcp-config <geçici> --strict-mcp-config
--allowedTools mcp__grafana-<ortam>`, Copilot CLI için `copilot -p … --additional-mcp-config @<geçici> --allow-tool
grafana-<ortam> -s --no-ask-user`; hesabın varsayılan modeli reddediliyorsa (`CAPIError 400 model is not supported`)
`COPILOT_MODEL=gpt-4.1` gibi bir model verin. **Copilot politikası:** bu makinedeki Copilot CLI 1.0.15 hesabı özel MCP
sunucularını engelliyordu (`--output-format json` çıktısında `1 MCP server was blocked by policy: 'grafana-lab'`); model
sunucuyu hiç görmedi, uydurma bir rapor yazdı ve denetim kilidi onu reddetti. Kurumda Copilot CLI'ın çalışması için
"MCP servers in Copilot" politikasının açık olması gerekir; bunu ilk gün `--dry-run` ve lab koşusuyla doğrulayın.
Eski sürümlerde `-p` + MCP birlikteliği de hatalıydı ([github/copilot-cli#1592](https://github.com/github/copilot-cli/issues/1592),
[#633](https://github.com/github/copilot-cli/issues/633)). Claude Code yolu lab'de uçtan uca doğrulandı.
Token'ı diske yazmak istemiyorsanız `.env.mcp.<ortam>`'a `GRAFANA_SERVICE_ACCOUNT_TOKEN_CMD="vault kv get …"` yazın;
wrapper her başlangıçta komutu çalıştırır, çıktıyı sunucuya ortam değişkeni olarak verir.

**Lab: sohbetten.**

- **Claude Code:** proje klasöründe `claude` aç, `.mcp.json` sunucusunu onayla, `/loadtest-triage lab --last 15m`.
  Headless: `claude -p "/loadtest-triage lab --last 15m" --mcp-config .mcp.json --allowedTools "mcp__grafana-lab,Read,Skill,Bash(python3 scripts/triage-window.py:*)"`
  (son izin pencere script'i içindir; CLI'da geçerli bir oturum gerekir, "OAuth session expired" alırsanız `claude login`).
- **Copilot:** VS Code'da `.vscode/mcp.json` → `grafana-lab` "Start"; Copilot Chat (Agent mode) → `/lab-loadtest-triage`, pencereyi gir.
- **Cursor:** Settings → MCP'de `grafana-lab`'ı etkinleştir, chat'te talimat dosyasını lab için uygulamasını iste.
- Aynı script lab için de çalışır: `scripts/triage.sh lab --last 15m`. Bankaya gidecek bir prompt değişikliği önce
  burada, sonra `dev`'de aynı komutla denenir.

Triage'ın girdileri ortam adı ve zaman penceresidir ("yük testi UAT'de şu tarihte koştu"); talimat dosyası yalnızca
o ortamı ve o pencereyi sorgular.

**Zaman penceresi standardı.** Pencere, saat dilimi ekli RFC3339 çifti olarak verilir
(`2026-11-06T14:00:00+03:00 2026-11-06T14:35:00+03:00`). Tarih aritmetiği modele bırakılmaz:
`scripts/triage-window.py` girdiyi doğrular, UTC'ye çevirir ve `{"from","to"}` üretir; model bu değerleri aynen
kullanır. Script saat dilimsiz, ters sıralı, 12 saatten uzun veya gelecekteki pencereleri reddeder. Kısayollar da
script üzerinden gider: `--last 15m`, `--date 2026-11-06 --from 14:00 --to 14:35 --tz +03:00`. Copilot prompt'ları
`from`/`to` girdilerini ayrı ayrı sorar; "bul" modu (0b) bulduğu pencereyi ISO olarak gösterip onay ister.

### Beklenen sonuç

Rapor iki kök nedeni ayırt etmeli ve her birini **doğru servise** yerleştirmeli:

1. **Yük kaynaklı, kök neden downstream'de — scoring pool exhausted**: `credit-service`'te
   `POST /api/v1/loans/shopping/apply` → 503, `exceptionClass=ScoringUnavailableException`,
   mesaj `scoring-service call failed: HttpServerErrorException$ServiceUnavailable ...`. Aynı `traceId` ile
   `scoring-service`'te `level=ERROR` `scoring pool exhausted, inflight=N, waited=2000ms, poolSize=10` ve
   `POST /api/v1/scores` → 503. İstek/dk arttıkça başlar ve büyür, p95 ile birlikte yükselir. credit-service'teki
   503 bir yansımadır; düzeltme `scoring-service`'te: havuz boyutu / timeout / backpressure.
2. **Kod bug'ı, kök neden upstream'de — campaignCode NPE** (`NullPointerException` in
   `InstallmentCalculator.resolveRate`, 500, sadece `credit-service`): trafikten bağımsız ~%5 sabit oran, ilk
   dakikadan itibaren var. Aynı trace'in `scoring-service` tarafı başarılıdır (200), yani downstream temizdir.
   Düzeltme: null kontrolü / standart oran.

## Doğrulama

Bu lab uçtan uca koşulup doğrulandı; çıktılar `triage/reports/` altında:

- [`triage/reports/claude-code-headless-two-services-2026-11-06.md`](triage/reports/claude-code-headless-two-services-2026-11-06.md) — iki servisli kurulumda,
  pencere verilmeden ("son 1 saat, kendin bul") koşulan headless triage: 0b adımıyla son yoğun pencereyi seçti, 503'ün kök nedenini
  scoring-service'e (downstream), NPE'yi credit-service'e (upstream) yerleştirdi, iki taraftaki sayıları birebir eşleştirdi.
- [`triage/reports/claude-code-headless-2026-11-06.md`](triage/reports/claude-code-headless-2026-11-06.md) — `claude -p "/loadtest-triage ..." --mcp-config .mcp.json`
  ile headless Claude Code'un ürettiği rapor: iki kök neden (scoring pool exhausted = yük kaynaklı, campaignCode NPE = kod bug'ı) doğru ayrıştırılmış.
- [`triage/reports/2026-11-06-son-15dk.md`](triage/reports/2026-11-06-son-15dk.md) — aynı MCP sunucusu stdio üzerinden elle sürülerek üretilmiş ikinci rapor (çapraz kontrol).
- [`triage/reports/k6-run-2026-11-06.txt`](triage/reports/k6-run-2026-11-06.txt) — threshold'ları aşıp abort olan k6 koşusu.
- [`triage/reports/cross-service-trace-2026-11-06.md`](triage/reports/cross-service-trace-2026-11-06.md) — `scoring-service` ayrıldıktan
  sonraki doğrulama: tek bir `traceId`'nin iki servisteki satırları, k6 koşusu ve Loki'den havuz tükenmesi kanıtı.

> İlk üç rapor, skorlama henüz `credit-service` içinde simüle edilirken üretildi; o yüzden `scoring pool exhausted`
> satırlarını `credit-service` altında gösterirler. Bugünkü mimaride aynı satırlar `scoring-service` altındadır.

Aynı adımları kendiniz koşabilirsiniz:

```bash
cd credit-service && mvn -q package
```

```bash
cd scoring-service && mvn -q package
```

Tek bir trace'i iki serviste birden görmek (`<TRACE_ID>` yerine yukarıdaki ERROR satırlarından birinin `traceId`'sini koy):

```bash
curl -s -G 'http://localhost:3100/loki/api/v1/query_range' --data-urlencode 'query={service=~"credit-service|scoring-service"} | traceId="<TRACE_ID>"' --data-urlencode 'start='"$(( $(date +%s) - 600 ))000000000" | jq -r '.data.result[].values[][1] | fromjson | "\(.["@timestamp"]) \(.service) \(.level) \(.message) \(.httpStatus // "") \(.exceptionClass // "")"' | sort
```

```bash
curl -s -G 'http://localhost:3100/loki/api/v1/query_range' --data-urlencode 'query={service="credit-service", level="ERROR"}' --data-urlencode 'start='"$(( $(date +%s) - 600 ))000000000" --data-urlencode 'limit=20' | jq '.data.result[].values[][1] | fromjson | {message, traceId, exceptionClass}'
```

```bash
curl -s -u admin:admin localhost:3000/api/datasources/uid/loki/health
```

## Log sözleşmesi ve başka stack'ler

Triage, servislerin hangi dilde yazıldığına değil, log satırlarının **şekline** bağlıdır: satır başına bir
JSON, istek başına tam bir `request completed` satırı (`endpoint`, `httpStatus`, `durationMs`), W3C `traceId`,
büyük harf `level`, hata satırlarında `exceptionClass`/`exceptionMessage`/`stackTrace`. Bu şekil
[`docs/LOG_CONTRACT.md`](docs/LOG_CONTRACT.md)'de alan alan, tip tip ve "Loki'de ne label olmaz" dahil
tanımlıdır; sonunda Java (logback/logstash), .NET (Serilog) ve Node (pino) için üretim tablosu vardır.

Kanıt olarak [`samples/dotnet-echo-service/`](samples/dotnet-echo-service/README.md) (ASP.NET Core minimal
API + Serilog `ExpressionTemplate`) sözleşmeyi uygular; `alloy/config.alloy` ve triage şablonları değişmeden
onun loglarını okur. Varsayılan stack'e dahil değildir, `samples` profiliyle kalkar:

```bash
docker compose --profile samples up -d --build dotnet-echo-service
```

```bash
curl -s -X POST localhost:8090/api/v1/echo -H 'content-type: application/json' -d '{"message":"hi"}'
```

```bash
curl -s -G 'http://localhost:3100/loki/api/v1/query_range' --data-urlencode 'query=quantile_over_time(0.95, {service="dotnet-echo-service"} |= "request completed" | json | unwrap durationMs [1m]) by (endpoint)' --data-urlencode 'start='"$(( $(date +%s) - 600 ))000000000" | jq '.data.result[] | {endpoint: .metric.endpoint, p95: .values[-1][1]}'
```

```bash
docker compose --profile samples stop dotnet-echo-service
```

Kendi .NET (ABP) servisinize taşımak için örnekteki `ContractLogging.cs` + `RequestLogMiddleware.cs`
yeterlidir; adımlar örneğin README'sinde.

## Kurumsal ortam notları

Lab'ı banka benzeri bir ortamda pilotlarken dört şey değişir: log hattı sizin değildir (label/alan adları farklı),
müşteri tanımlayıcıları LLM'e gitmemelidir, Docker Desktop yasak olabilir ve AI kesinlikle sadece okumalıdır.
Aşağıdaki dört parça bu lab'da uygulanmış ve doğrulanmıştır; kurumsal hatta aynı kalıpları uygulayın.

### 1. PII maskeleme — Loki'ye yazılmadan önce

[`alloy/config.alloy`](alloy/config.alloy) içindeki `loki.process "json"` bloğu, `stage.json`'dan **önce** bir
`stage.replace` çalıştırır: `"customerId":"C773001"` → `"customerId":"C7***"` (ilk 2 karakter + `***`). Maskeleme ham
satırda yapılır: Loki'de saklanan ve MCP üzerinden AI'ya giden değer maskelidir, ham değer yalnızca konteyner stdout'unda
kalır. `traceId` değişmez, servisler arası korelasyon aynen çalışır. Doğrulama (`docker compose restart alloy` sonrası):

```bash
curl -s -G 'http://localhost:3100/loki/api/v1/query_range' --data-urlencode 'query={service=~"credit-service|scoring-service"} | json | customerId != ""' --data-urlencode 'start='"$(( $(date +%s) - 600 ))000000000" --data-urlencode 'limit=5' | jq -r '.data.result[].values[][1] | fromjson | "\(.service) traceId=\(.traceId) customerId=\(.customerId)"'
```

Beklenen: `credit-service traceId=6aed… customerId=C7***` ve aynı `traceId` ile `scoring-service … customerId=C7***`.

Kurumsal hatta: Alloy/Promtail konfigini log platformu ekibi yönetiyorsa, kimlik taşıyan her alan (müşteri no, TCKN, IBAN,
telefon) için bir `stage.replace` (Fluent Bit'te `modify`/Lua, Logstash'te `mutate gsub`) isteyin; maskeyi **toplayıcıda,
Loki'den önce** uygulatın. Uygulamada MDC'ye kimlik hiç koymamak en temiz çözümdür. Talimat dosyasındaki "Veri koruma"
bölümü AI'ya maskeli değeri bile rapora yazmamasını, satırları sadece `traceId` ile referanslamasını söyler.

### 2. Sadece okuma, sadece Loki MCP

[`scripts/grafana-mcp.sh`](scripts/grafana-mcp.sh) sunucuyu `--enabled-tools datasource,loki --disable-write` ile başlatır
(`docker run --rm mcp/grafana --help` ile doğrulanmış flag'ler; `--enabled-tools` bir allowlist'tir, diğer 20 kategori —
dashboard, alerting, incident, oncall, admin, api, search, prometheus, sift, annotations, rendering, snapshot, ... — kapalıdır).
Araç sayısı 65'ten 9'a iner: `list_datasources`, `get_datasource`, `check_datasources_health`, `list_loki_label_names`,
`list_loki_label_values`, `query_loki_logs`, `query_loki_stats`, `query_loki_patterns`, `analyze_loki_labels`.
Doğrulama (stdio üzerinden JSON-RPC `tools/list`):

```bash
scripts/mcp-tools-list.sh
```

İkinci savunma hattı token'dır: service account **Viewer** kalır ve tek datasource'a kısıtlanır. Grafana Enterprise/Cloud'da
datasource permissions ile sadece Loki datasource'una `Query` verilir; Grafana OSS'de datasource permissions yoktur, sadece
Loki datasource'u olan ayrı bir org açılır ve SA o org'da yaratılır (`GRAFANA_ORG_ID=<id> scripts/create-grafana-sa-token.sh`).
Adımlar ve API çağrıları [`scripts/create-grafana-sa-token.sh`](scripts/create-grafana-sa-token.sh) sonundaki yorum bloğunda.

### 3. Alan eşleme ve pencere tespiti

[`triage/LOADTEST_TRIAGE.md`](triage/LOADTEST_TRIAGE.md) en üstte bir **"Alan eşleme"** tablosu taşır: şablonlardaki her
label/alan (`service`, `level`, `traceId`, `endpoint`, `httpStatus`, `durationMs`, `exceptionClass`, `exceptionMessage`,
`request completed` işareti) için lab varsayılanı ve doldurulacak "Kurumsal değer" sütunu; AI şablonları bu eşlemeyle okur.
Yük testinin saati bilinmiyorsa **0b** adımı son N saatin 5 dakikalık hacim serisinden
(`sum(count_over_time({service="..."} [5m]))`) yoğun pencereyi bulur ve kullanıcıya onaylatır. **0c** adımı kurumsal Loki
limitleri için sorgu disiplinini verir: seçici `| json a, b`, küçük `limit`, pencereden geniş aralık yok.

### 4. Docker'sız çalışma, proxy ve kurumsal CA

Docker bu projede iki ayrı iş yapar ve ikisi karıştırılmamalıdır: (1) `docker-compose.yml` bankadaki UAT + Loki + Grafana'nın
**yerel taklididir**, kuruma hiçbir parçası gitmez; (2) `scripts/grafana-mcp.sh` MCP sunucusunu geliştirici makinesinde
başlatır ve Docker'a dokunan tek geliştirici-tarafı parça budur. Kurumsal iş istasyonunda Docker varsayılmadığı için script'in
**varsayılan modu native binary'dir**:

| Ortam | Binary bulundu (`MCP_GRAFANA_BIN` / PATH) | Binary yok |
|---|---|---|
| `lab` | binary | `docker run mcp/grafana` (uyarı basar; lab yığını zaten compose'da) |
| `uat` ve diğerleri | binary | **hata + kurulum talimatı**; Docker'a düşmez |

`MCP_GRAFANA_MODE=docker` yazılırsa herhangi bir ortamda Docker zorlanabilir (bilinçli seçim, varsayılan değil).
Binary modda `GRAFANA_URL` varsayılanı `http://localhost:3000`'dir; `.env.mcp.lab`'daki `host.docker.internal` localhost'a
çevrilir. Proxy (`HTTPS_PROXY` / `HTTP_PROXY` / `NO_PROXY`) ve kurumsal CA (`SSL_CERT_FILE`) iki modda da geçer; docker
modunda CA paketi konteynere salt-okunur bağlanır (kurumsal TLS inspection). `MCP_GRAFANA_EXTRA_ARGS` ile ek flag eklenebilir.
Hatalar açık mesajla biter:

```bash
MCP_GRAFANA_BIN=/bin/false scripts/grafana-mcp.sh
```

→ `grafana-mcp.sh: MCP_GRAFANA_BIN='/bin/false' is not an executable file` (macOS'ta `/bin/false` yoktur; Linux'ta aynı
komut `'/bin/false --help' failed - this does not look like an mcp-grafana binary` verir), çıkış kodu 1.
`scripts/grafana-mcp.sh uat` binary olmadan `environment 'uat' needs an mcp-grafana binary and none was found` der ve
kurulum talimatı basar; Docker yüklü olsa bile çalıştırmaz. Kurulum: `go install github.com/grafana/mcp-grafana/cmd/mcp-grafana@latest`
ya da GitHub release binary'si; `.env.mcp.<ortam>`'a `MCP_GRAFANA_BIN=/path/to/mcp-grafana` ekleyin. İstemci konfigleri değişmez.

### Bilinen açık: çok satırlı stack trace

Lab'daki servisler stack trace'i JSON satırının `stackTrace` alanına **tek satır** olarak yazar; bu yüzden Alloy'da
`stage.multiline` yoktur. Kurumsal uygulamalar düz metin + çok satırlı stack trace basıyorsa her satır ayrı log kaydı olur,
`| json` çalışmaz ve exception kümelemesi bozulur. Çözüm toplayıcıda, `stage.json`'dan önce
`stage.multiline { firstline = "^\\d{4}-\\d{2}-\\d{2}" max_wait_time = "3s" }` (satır başı deseni log formatına göre) ya da
uygulamada JSON encoder. Bu lab'da **test edilmedi**.

## Dosya yapısı

```
credit-service/        Giriş noktası Spring Boot servisi; scoring-service'i HTTP ile çağırır (+ Dockerfile)
scoring-service/       Downstream skor servisi; havuz tükenmesi hata modu burada (+ Dockerfile)
docker-compose.yml     loki, alloy, grafana, scoring-service, credit-service, k6 (profile: loadtest), dotnet-echo-service (profile: samples)
loki/loki.yaml         single-binary Loki 3.x
alloy/config.alloy     docker log toplama → Loki
grafana/               datasource + dashboard provisioning
k6/                    yük senaryosu
triage/                LOADTEST_TRIAGE.md (tek triage kaynağı), environments/<ortam>.md (ilk satır: type=ide|script), templates/, reports/
docs/LOG_CONTRACT.md   stack'ten bağımsız log sözleşmesi (triage'ın beklediği alanlar)
samples/dotnet-echo-service/  sözleşmeyi uygulayan ASP.NET Core + Serilog örneği (profile: samples)
scripts/               triage.sh (kilitli ortamların tek girişi), grafana-mcp.sh (MCP wrapper: binary, kilit, token komutu),
                       mcp-audit-proxy.py (araç çağrısı denetim izi), triage-window.py, gen-prompts.sh, create-grafana-sa-token.sh, mcp-tools-list.sh
.mcp.json .vscode/ .cursor/ .claude/ .github/   istemci konfigleri (ince)
```
