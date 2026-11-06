package com.lab.credit.domain;

import java.math.BigDecimal;
import java.time.Instant;

public record LoanApplication(
        String applicationId,
        String customerId,
        BigDecimal amount,
        int installmentCount,
        String campaignCode,
        int score,
        LoanStatus status,
        BigDecimal monthlyInstallment,
        Instant createdAt) {
}
