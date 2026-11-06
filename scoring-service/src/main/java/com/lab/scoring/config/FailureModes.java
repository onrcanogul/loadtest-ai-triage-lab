package com.lab.scoring.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * Deliberate failure mode of this lab service. ON by default, switched off with FAILURE_POOL_EXHAUSTION=false.
 */
@ConfigurationProperties(prefix = "failure")
public record FailureModes(boolean poolExhaustion) {
}
