package com.lab.credit.service;

public class LoanNotFoundException extends RuntimeException {

    public LoanNotFoundException(String applicationId) {
        super("loan application not found: " + applicationId);
    }
}
