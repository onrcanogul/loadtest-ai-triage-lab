---
name: loadtest-triage
description: SADECE kullanıcı açıkça "/loadtest-triage <ortam> ..." dediğinde çalışır. Belirtilen ortamın (lab | uat) Grafana MCP sunucusu üzerinden Loki loglarını sorgulayıp yük testi kök neden raporu üretir. Kod yazma, düzenleme, test veya genel sorularda KULLANMA; ortam verilmediyse sor.
---

Bu skill gündelik kodlama akışından ayrıdır: IDE'deki kod ve local ortam, triage'ın verisi **değildir**.
Veri, seçilen ortamın Grafana'sından (API) gelir.

Argümanlar: `$ARGUMENTS` = `<ortam> <pencere> [servis]`
- `<ortam>`: `lab` veya `uat` (zorunlu; yoksa kullanıcıya sor, varsayma).
- `<pencere>`: tercihen iki RFC3339 zaman (`2026-11-06T14:00:00+03:00 2026-11-06T14:35:00+03:00`);
  `--last 15m`; `--date 2026-11-06 --from 14:00 --to 14:35 --tz +03:00`; ya da `bul`.
  Tarih aritmetiğini **sen yapma**: pencereyi script ile hesaplat ve çıktıdaki `from`/`to` değerlerini
  aynen kullan (talimat dosyası "Zaman penceresi sözleşmesi"). Komut biçimi tam olarak şu olsun
  (başka biçim izinli değildir): `python3 scripts/triage-window.py <argümanlar>`. Script reddederse hatayı
  kullanıcıya ilet ve düzeltilmiş girdi iste. "son 15 dk" gibi bir ifade geldiyse onu `--last 15m` olarak
  script'e ver. Bash aracını yalnızca bu komut için kullan.

Adımlar:
1. `triage/environments/<ortam>.md` dosyasını oku. `<doldur>` kalan bir alan varsa onu sor; varsayma.
2. `triage/LOADTEST_TRIAGE.md` dosyasını oku ve adımları sırayla uygula.
3. **Yalnızca** `grafana-<ortam>` MCP sunucusunun araçlarını kullan (`mcp__grafana-<ortam>__query_loki_logs` vb.).
   Başka bir Grafana sunucusunun aracı görünse bile çağırma.
4. Triage sırasında dosya düzenleme, kod değiştirme, komut çalıştırma yapma; çıktı yalnızca rapordur.

Raporu, talimat dosyasındaki "Rapor formatı" bölümüne birebir uyarak Türkçe yaz; Özet'e ortam adını ve
(uat için) çalışan sürümü ekle.
