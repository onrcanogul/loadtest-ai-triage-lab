package com.lab.credit.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * Deliberate failure mode of this lab service. ON by default and switched off with FAILURE_NPE_BUG=false.
 * The pool-exhaustion failure mode (FAILURE_POOL_EXHAUSTION) lives in scoring-service.
 */
@ConfigurationProperties(prefix = "failure")
public record FailureModes(boolean npeBug) {
}
