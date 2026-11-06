package com.lab.credit.web.dto;

import com.lab.credit.domain.LoanApplication;
import com.lab.credit.domain.LoanStatus;

import java.math.BigDecimal;

public record LoanApplicationResponse(String applicationId, LoanStatus status, BigDecimal monthlyInstallment) {

    public static LoanApplicationResponse from(LoanApplication application) {
        return new LoanApplicationResponse(
                application.applicationId(), application.status(), application.monthlyInstallment());
    }
}
