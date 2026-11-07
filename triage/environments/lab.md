<!-- triage-env type=ide -->
# Ortam: lab

Yerel laboratuvar (docker compose). Bu dosya, `triage/LOADTEST_TRIAGE.md` adım 0a'da okunur.
Tetikleme tipi **ide**: tek `ide` tipli ortam budur; MCP sunucusu IDE'lerde kayıtlıdır ve sohbetten
(`/loadtest-triage lab …`, `/lab-loadtest-triage`) çağrılabilir. Prompt burada geliştirilir ve denenir.

| Alan | Değer |
|---|---|
| Tetikleme | `ide` — sohbetten ve `scripts/triage.sh lab …` ile |
| MCP sunucusu | `grafana-lab` (yalnızca bu sunucunun araçları kullanılır) |
| Env dosyası | `.env.mcp.lab` (`scripts/create-grafana-sa-token.sh` üretir) |
| Grafana | http://localhost:3000 (konteynerden `host.docker.internal:3000`) |
| Loki datasource uid | `loki` |
| Servisler (`service` label) | `credit-service` (giriş noktası), `scoring-service` (downstream), `dotnet-echo-service` (örnek, profil `samples`) |
| Alan eşleme | Lab varsayılanları geçerli; eşleme tablosundaki "Kurumsal değer" sütunu boş kalır |
| Çalışan sürüm | Her zaman bu klasördeki kod (`docker compose up --build` ile derlenir). Stack trace satır numaraları local dosyalarla birebir aynıdır |
| Veri koruma | `customerId` Alloy'da maskelenir (`C7***`); kurallar talimat dosyasındaki gibi |
| Sorgu limitleri | Yok; yine de şablonlardaki `limit` ve aralıklara uy |
