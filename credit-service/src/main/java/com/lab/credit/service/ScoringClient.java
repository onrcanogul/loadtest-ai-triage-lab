package com.lab.credit.service;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.http.client.ClientHttpRequestFactoryBuilder;
import org.springframework.boot.http.client.ClientHttpRequestFactorySettings;
import org.springframework.stereotype.Component;
import org.springframework.web.client.HttpServerErrorException;
import org.springframework.web.client.ResourceAccessException;
import org.springframework.web.client.RestClient;

import java.time.Duration;
import java.util.Map;

import static net.logstash.logback.argument.StructuredArguments.kv;

/**
 * HTTP client for scoring-service ({@code POST /api/v1/scores}).
 *
 * Built from Spring Boot's auto-configured {@link RestClient.Builder}, which is instrumented by
 * Micrometer Observation: every outgoing call carries a W3C {@code traceparent} header, so
 * scoring-service logs the same {@code traceId} as this service. There is no local pool or
 * simulation here any more; the pool-exhaustion failure mode lives in scoring-service.
 *
 * Any transport failure (connect/read timeout, connection refused) or 5xx from scoring-service is
 * mapped to {@link ScoringUnavailableException} -> HTTP 503 upstream, and logged here at ERROR with
 * the underlying exception class and message so the credit-service side of the trace is self-explanatory.
 */
@Component
public class ScoringClient {

    private static final Logger log = LoggerFactory.getLogger(ScoringClient.class);

    private final RestClient restClient;

    public ScoringClient(RestClient.Builder builder,
                         @Value("${scoring.base-url}") String baseUrl,
                         @Value("${scoring.connect-timeout:1s}") Duration connectTimeout,
                         @Value("${scoring.read-timeout:5s}") Duration readTimeout) {
        ClientHttpRequestFactorySettings settings = ClientHttpRequestFactorySettings.defaults()
                .withConnectTimeout(connectTimeout)
                .withReadTimeout(readTimeout);
        this.restClient = builder
                .baseUrl(baseUrl)
                .requestFactory(ClientHttpRequestFactoryBuilder.detect().build(settings))
                .build();
    }

    public int score(String customerId) {
        try {
            ScoreResponse response = restClient.post()
                    .uri("/api/v1/scores")
                    .body(Map.of("customerId", customerId))
                    .retrieve()
                    .body(ScoreResponse.class);
            if (response == null) {
                throw unavailable(new IllegalStateException("empty response body from scoring-service"));
            }
            return response.score();
        } catch (HttpServerErrorException e) {
            // scoring-service answered 5xx (503 = its pool is exhausted); the root-cause ERROR line is in ITS log
            throw unavailable(e);
        } catch (ResourceAccessException e) {
            // connect timeout, read timeout, connection refused, ...
            throw unavailable(e);
        }
    }

    private static ScoringUnavailableException unavailable(Exception cause) {
        String message = "scoring-service call failed: " + cause.getClass().getSimpleName() + ": " + cause.getMessage();
        log.error("scoring-service unavailable", kv("exceptionClass", cause.getClass().getName()),
                kv("exceptionMessage", String.valueOf(cause.getMessage())));
        return new ScoringUnavailableException(message, cause);
    }

    private record ScoreResponse(String customerId, int score) {
    }
}
