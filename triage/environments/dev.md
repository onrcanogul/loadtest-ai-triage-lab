<!-- triage-env type=script -->
# Ortam: dev

Tetikleme tipi **script**: bu ortam hiçbir IDE'de MCP sunucusu olarak kayıtlı **değildir** ve sohbetten
çağrılamaz. Tek giriş `scripts/triage.sh dev <from> <to> [--service X]`; sunucu o komutun çocuk süreci olarak
doğar, komut bitince ölür. Kurumsal DEV ortamı. Yük testleri burada test ekibi tarafından koşulur; biz DEV'e, test script'lerine ve
DEV'deki koda **doğrudan erişemeyiz**. Tek erişim: kurumun Grafana'sı (HTTP API, Viewer token) → DEV Loki.
`<doldur>` yazan alanları ilk kullanımdan önce doldurun; dolu olmayan bir alanı triage sırasında **varsayma**,
kullanıcıya sor.

| Alan | Değer |
|---|---|
| Tetikleme | `script` — yalnızca `scripts/triage.sh dev …`; IDE'de kayıtlı değil |
| MCP sunucusu | `grafana-dev` (yalnızca `triage.sh` başlatır; yalnızca bu sunucunun araçları kullanılır) |
| Env dosyası | `.env.mcp.dev` (`.env.mcp.dev.example`'dan kopyala; token Grafana yöneticilerinden) |
| Grafana | `<doldur>` (ör. https://grafana.dev.example.internal; VPN/proxy gerekebilir) |
| Loki datasource uid | `<doldur>` — `list_datasources` ile bul; birden fazla Loki varsa DEV olanı seç ve adını raporda yaz |
| Servisler (`service` label) | `<doldur>` — `list_loki_label_values` ile keşfet; label adı `service` olmayabilir (bkz. alan eşleme) |
| Alan eşleme | `<doldur>` — talimat dosyasındaki tablonun "Kurumsal değer" sütunu; `list_loki_label_names` + küçük `limit`'li `\| json` örneğiyle keşfet |
| Çalışan sürüm | `<doldur>` — DEV'de koşan build/commit nereden okunur? (ör. `/actuator/info`, `/version`, deploy pipeline kaydı, release notu). **IDE'deki kod bu sürüm değildir.** |
| Veri koruma | Kurumsal log hattında maskeleme olmayabilir: talimat dosyasındaki kurallar aynen geçerli, hiçbir müşteri tanımlayıcısı rapora girmez |
| Sorgu limitleri | Kurumsal Loki limitleri geçerli (talimat 0c); geniş `\| json` yerine seçici parse, küçük `limit` |

## Sürüm kuralı (DEV için zorunlu)

1. Raporun "Özet" bölümüne DEV'de koşan sürümü yaz (bulunamadıysa "sürüm doğrulanmadı").
2. Stack trace'teki sınıf ve satır numaraları **o sürüme** aittir. IDE'deki dosyada aynı satırı bulsan bile,
   sürüm farkı varsa satır kaymış olabilir; "Önerilen düzeltme" bölümünde sınıf/metod adıyla konuş, satır
   numarasını "DEV sürümüne göre" diye işaretle.
3. Triage sırasında **kod düzenleme**: yapılmaz. Rapor önce ekip tarafından teyit edilir; düzeltme ayrı bir
   iş olarak, doğru sürüm/branch üzerinde açılır.
