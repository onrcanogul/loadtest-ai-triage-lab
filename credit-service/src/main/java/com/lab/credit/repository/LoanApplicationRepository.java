package com.lab.credit.repository;

import com.lab.credit.domain.LoanApplication;
import org.springframework.stereotype.Repository;

import java.util.Map;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;

@Repository
public class LoanApplicationRepository {

    private final Map<String, LoanApplication> store = new ConcurrentHashMap<>();

    public LoanApplication save(LoanApplication application) {
        store.put(application.applicationId(), application);
        return application;
    }

    public Optional<LoanApplication> findById(String applicationId) {
        return Optional.ofNullable(store.get(applicationId));
    }
}
