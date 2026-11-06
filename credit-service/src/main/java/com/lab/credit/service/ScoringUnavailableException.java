package com.lab.credit.service;

/** Thrown when scoring-service cannot be reached in time or answers 5xx. Mapped to HTTP 503. */
public class ScoringUnavailableException extends RuntimeException {

    public ScoringUnavailableException(String message) {
        super(message);
    }

    public ScoringUnavailableException(String message, Throwable cause) {
        super(message, cause);
    }
}
