---
mode: agent
description: lab ortamındaki yük testi için Loki (Grafana MCP, grafana-lab) kök neden triage'ı. Sadece bu komutla çalışır.
tools: ['grafana-lab/list_datasources', 'grafana-lab/get_datasource', 'grafana-lab/check_datasources_health', 'grafana-lab/list_loki_label_names', 'grafana-lab/list_loki_label_values', 'grafana-lab/query_loki_logs', 'grafana-lab/query_loki_stats', 'grafana-lab/query_loki_patterns', 'grafana-lab/analyze_loki_labels']
---
<!-- ÜRETİLMİŞ DOSYA — elle düzenleme. Kaynak: triage/templates/loadtest-triage.prompt.md.tmpl, üretici: scripts/gen-prompts.sh -->
Bu prompt gündelik kodlama akışından ayrıdır: çalışma alanındaki kod ve local ortam triage'ın verisi
**değildir**; veri `grafana-lab` MCP sunucusu üzerinden lab ortamının Grafana'sından gelir.

1. `triage/environments/lab.md` dosyasını oku; `<doldur>` kalan bir alan varsa sor, varsayma.
2. `triage/LOADTEST_TRIAGE.md` dosyasını oku ve adımları sırayla, yalnızca `grafana-lab` araçlarıyla uygula.
3. Dosya düzenleme veya kod değiştirme yapma; çıktı yalnızca rapordur.

Girdiler (zaman penceresi için tarih aritmetiği yapma; biçim uymuyorsa bu biçimde yeniden iste):
- Başlangıç (RFC3339 + saat dilimi): ${input:from:2026-11-06T14:00:00+03:00}
- Bitiş (RFC3339 + saat dilimi): ${input:to:2026-11-06T14:35:00+03:00}
- Servis: ${input:service:credit-service}

Pencere kuralı (talimat dosyası "Zaman penceresi sözleşmesi"): başlangıç ve bitiş saat dilimi ekli RFC3339
olmalı, bitiş başlangıçtan sonra ve aralık en fazla 12 saat. Biri boşsa ya da "bul" yazıldıysa 0b adımıyla
yoğun pencereyi bul, ISO olarak göster ve onay almadan devam etme. Kullandığın pencereyi raporun Özet'ine yaz.

Raporu, talimat dosyasındaki "Rapor formatı" bölümüne birebir uyarak Türkçe yaz; Özet'e ortam adını
ve ortamda çalışan sürümü ekle.
