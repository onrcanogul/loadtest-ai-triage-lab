package com.lab.credit.service;

import java.math.BigDecimal;

/** A shopping-loan campaign with its monthly interest rate. */
public class Campaign {

    private final String code;
    private final BigDecimal rate;

    public Campaign(String code, BigDecimal rate) {
        this.code = code;
        this.rate = rate;
    }

    public String getCode() {
        return code;
    }

    public BigDecimal getRate() {
        return rate;
    }
}
