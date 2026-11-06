package com.lab.credit.service;

import org.springframework.stereotype.Component;

import java.math.BigDecimal;
import java.util.Map;

/** In-memory campaign lookup. Unknown codes fall back to the standard campaign; a null code yields null. */
@Component
public class CampaignCatalog {

    private static final Campaign STANDARD = new Campaign("STANDARD", new BigDecimal("0.0349"));

    private final Map<String, Campaign> campaigns = Map.of(
            "POS2025", new Campaign("POS2025", new BigDecimal("0.0299")),
            "SUMMER10", new Campaign("SUMMER10", new BigDecimal("0.0259")),
            "BLACKFRIDAY", new Campaign("BLACKFRIDAY", new BigDecimal("0.0199")));

    public Campaign find(String campaignCode) {
        if (campaignCode == null) {
            return null;
        }
        return campaigns.getOrDefault(campaignCode, STANDARD);
    }
}
