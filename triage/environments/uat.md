# Ortam: uat

Kurumsal UAT ortamı. Yük testleri burada test ekibi tarafından koşulur; biz UAT'ye, test script'lerine ve
UAT'deki koda **doğrudan erişemeyiz**. Tek erişim: kurumun Grafana'sı (HTTP API, Viewer token) → UAT Loki.
`<doldur>` yazan alanları ilk kullanımdan önce doldurun; dolu olmayan bir alanı triage sırasında **varsayma**,
kullanıcıya sor.

| Alan | Değer |
|---|---|
| MCP sunucusu | `grafana-uat` (yalnızca bu sunucunun araçları kullanılır; `grafana-lab` araçlarına dokunma) |
| Env dosyası | `.env.mcp.uat` (`.env.mcp.uat.example`'dan kopyala; token Grafana yöneticilerinden) |
| Grafana | `<doldur>` (ör. https://grafana.uat.example.internal; VPN/proxy gerekebilir) |
| Loki datasource uid | `<doldur>` — `list_datasources` ile bul; birden fazla Loki varsa UAT olanı seç ve adını raporda yaz |
| Servisler (`service` label) | `<doldur>` — `list_loki_label_values` ile keşfet; label adı `service` olmayabilir (bkz. alan eşleme) |
| Alan eşleme | `<doldur>` — talimat dosyasındaki tablonun "Kurumsal değer" sütunu; `list_loki_label_names` + küçük `limit`'li `\| json` örneğiyle keşfet |
| Çalışan sürüm | `<doldur>` — UAT'de koşan build/commit nereden okunur? (ör. `/actuator/info`, `/version`, deploy pipeline kaydı, release notu). **IDE'deki kod bu sürüm değildir.** |
| Veri koruma | Kurumsal log hattında maskeleme olmayabilir: talimat dosyasındaki kurallar aynen geçerli, hiçbir müşteri tanımlayıcısı rapora girmez |
| Sorgu limitleri | Kurumsal Loki limitleri geçerli (talimat 0c); geniş `\| json` yerine seçici parse, küçük `limit` |

## Sürüm kuralı (UAT için zorunlu)

1. Raporun "Özet" bölümüne UAT'de koşan sürümü yaz (bulunamadıysa "sürüm doğrulanmadı").
2. Stack trace'teki sınıf ve satır numaraları **o sürüme** aittir. IDE'deki dosyada aynı satırı bulsan bile,
   sürüm farkı varsa satır kaymış olabilir; "Önerilen düzeltme" bölümünde sınıf/metod adıyla konuş, satır
   numarasını "UAT sürümüne göre" diye işaretle.
3. Triage sırasında **kod düzenleme**: yapılmaz. Rapor önce ekip tarafından teyit edilir; düzeltme ayrı bir
   iş olarak, doğru sürüm/branch üzerinde açılır.
