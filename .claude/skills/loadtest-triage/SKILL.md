---
name: loadtest-triage
description: SADECE kullanıcı açıkça "/loadtest-triage <ortam> ..." dediğinde çalışır. Yalnızca `ide` tipli ortam (lab) için sohbetten triage yapar; `script` tipli ortamlar (dev, uat) sohbetten çağrılamaz, kullanıcı scripts/triage.sh komutuna yönlendirilir. Kod yazma, düzenleme, test veya genel sorularda KULLANMA; ortam verilmediyse sor.
---

Bu skill gündelik kodlama akışından ayrıdır: IDE'deki kod ve local ortam, triage'ın verisi **değildir**.
Veri, seçilen ortamın Grafana'sından (API) gelir.

Argümanlar: `$ARGUMENTS` = `<ortam> <pencere> [servis]`
- `<ortam>`: zorunlu; yoksa kullanıcıya sor, varsayma. Önce `triage/environments/<ortam>.md` ilk satırındaki
  `<!-- triage-env type=… -->` işaretine bak. `type=script` ise (dev, uat) **triage yapma**: bu ortamlar IDE'de
  kayıtlı değildir, araçları yoktur; kullanıcıya tam komutu ver ve dur:
  `scripts/triage.sh <ortam> <from> <to> [--service X]`. Yalnızca `type=ide` (lab) sohbetten koşar.
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
