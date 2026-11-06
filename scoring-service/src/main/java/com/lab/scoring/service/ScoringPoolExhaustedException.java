package com.lab.scoring.service;

/** Thrown when no scoring "connection" becomes free within the acquire timeout. Mapped to HTTP 503. */
public class ScoringPoolExhaustedException extends RuntimeException {

    public ScoringPoolExhaustedException(String message) {
        super(message);
    }
}
