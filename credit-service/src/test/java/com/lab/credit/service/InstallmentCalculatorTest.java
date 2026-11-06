package com.lab.credit.service;

import com.lab.credit.config.FailureModes;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class InstallmentCalculatorTest {

    private final CampaignCatalog catalog = new CampaignCatalog();

    @Test
    void computesInstallmentWithCampaignRate() {
        InstallmentCalculator calculator = new InstallmentCalculator(catalog, new FailureModes(true));

        BigDecimal installment = calculator.monthlyInstallment(new BigDecimal("12000"), 12, "POS2025");

        assertThat(installment).isEqualByComparingTo("1204.83");
    }

    @Test
    void longTermPlanWithoutCampaignThrowsNpeWhenBugEnabled() {
        InstallmentCalculator calculator = new InstallmentCalculator(catalog, new FailureModes(true));

        assertThatThrownBy(() -> calculator.monthlyInstallment(new BigDecimal("12000"), 9, null))
                .isInstanceOf(NullPointerException.class);
    }

    @Test
    void longTermPlanWithoutCampaignUsesStandardRateWhenBugDisabled() {
        InstallmentCalculator calculator = new InstallmentCalculator(catalog, new FailureModes(false));

        BigDecimal installment = calculator.monthlyInstallment(new BigDecimal("12000"), 9, null);

        assertThat(installment).isPositive();
    }
}
