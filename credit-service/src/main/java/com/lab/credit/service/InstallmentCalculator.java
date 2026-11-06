package com.lab.credit.service;

import com.lab.credit.config.FailureModes;
import org.springframework.stereotype.Component;

import java.math.BigDecimal;
import java.math.RoundingMode;

/**
 * Computes the monthly installment with a simple annuity formula.
 *
 * Failure mode (b): long-term plans (>= {@value #LONG_TERM_THRESHOLD} installments) always take the
 * rate from the campaign, but a request without campaignCode has no campaign -> NullPointerException.
 * This is a plain code bug, independent of load. With FAILURE_NPE_BUG=false the null-safe branch is used.
 */
@Component
public class InstallmentCalculator {

    static final int LONG_TERM_THRESHOLD = 9;
    private static final BigDecimal STANDARD_MONTHLY_RATE = new BigDecimal("0.0349");

    private final CampaignCatalog campaignCatalog;
    private final FailureModes failureModes;

    public InstallmentCalculator(CampaignCatalog campaignCatalog, FailureModes failureModes) {
        this.campaignCatalog = campaignCatalog;
        this.failureModes = failureModes;
    }

    public BigDecimal monthlyInstallment(BigDecimal amount, int installmentCount, String campaignCode) {
        Campaign campaign = campaignCatalog.find(campaignCode);
        BigDecimal monthlyRate = resolveRate(campaign, installmentCount);
        return annuity(amount, monthlyRate, installmentCount);
    }

    private BigDecimal resolveRate(Campaign campaign, int installmentCount) {
        if (installmentCount >= LONG_TERM_THRESHOLD) {
            if (failureModes.npeBug()) {
                return campaign.getRate(); // BUG: campaign is null when no campaignCode was sent
            }
            return campaign != null ? campaign.getRate() : STANDARD_MONTHLY_RATE;
        }
        return campaign != null ? campaign.getRate() : STANDARD_MONTHLY_RATE;
    }

    private static BigDecimal annuity(BigDecimal amount, BigDecimal monthlyRate, int n) {
        // installment = P * r * (1+r)^n / ((1+r)^n - 1)
        BigDecimal onePlusR = BigDecimal.ONE.add(monthlyRate);
        BigDecimal pow = onePlusR.pow(n);
        BigDecimal numerator = amount.multiply(monthlyRate).multiply(pow);
        BigDecimal denominator = pow.subtract(BigDecimal.ONE);
        return numerator.divide(denominator, 2, RoundingMode.HALF_UP);
    }
}
