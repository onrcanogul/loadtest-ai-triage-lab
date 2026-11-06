package com.lab.credit.web.dto;

import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Positive;

import java.math.BigDecimal;

public record LoanApplicationRequest(
        @NotBlank String customerId,
        @NotNull @Positive BigDecimal amount,
        @Min(1) @Max(36) int installmentCount,
        String campaignCode) {
}
