package com.lab.credit.service;

import com.lab.credit.domain.LoanApplication;
import com.lab.credit.domain.LoanStatus;
import com.lab.credit.repository.LoanApplicationRepository;
import com.lab.credit.web.dto.LoanApplicationRequest;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.slf4j.MDC;
import org.springframework.stereotype.Service;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.UUID;

@Service
public class LoanApplicationService {

    private static final Logger log = LoggerFactory.getLogger(LoanApplicationService.class);
    private static final int MIN_APPROVAL_SCORE = 400;

    private final ScoringClient scoringClient;
    private final InstallmentCalculator installmentCalculator;
    private final LoanApplicationRepository repository;

    public LoanApplicationService(ScoringClient scoringClient,
                                  InstallmentCalculator installmentCalculator,
                                  LoanApplicationRepository repository) {
        this.scoringClient = scoringClient;
        this.installmentCalculator = installmentCalculator;
        this.repository = repository;
    }

    public LoanApplication apply(LoanApplicationRequest request) {
        MDC.put("customerId", request.customerId());

        int score = scoringClient.score(request.customerId());
        BigDecimal monthlyInstallment = installmentCalculator.monthlyInstallment(
                request.amount(), request.installmentCount(), request.campaignCode());
        LoanStatus status = score >= MIN_APPROVAL_SCORE ? LoanStatus.APPROVED : LoanStatus.REJECTED;

        LoanApplication application = new LoanApplication(
                UUID.randomUUID().toString(), request.customerId(), request.amount(),
                request.installmentCount(), request.campaignCode(), score, status,
                monthlyInstallment, Instant.now());
        repository.save(application);

        MDC.put("applicationId", application.applicationId());
        log.info("loan application {} score={} installments={} campaign={}",
                status, score, request.installmentCount(), request.campaignCode());
        return application;
    }

    public LoanApplication get(String applicationId) {
        MDC.put("applicationId", applicationId);
        return repository.findById(applicationId)
                .orElseThrow(() -> new LoanNotFoundException(applicationId));
    }
}
