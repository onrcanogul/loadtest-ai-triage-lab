package com.lab.scoring.service;

import com.lab.scoring.config.FailureModes;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

import java.util.concurrent.Semaphore;
import java.util.concurrent.ThreadLocalRandom;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Credit-score computation behind a deliberately small "connection pool" (KKB stand-in).
 *
 * Failure mode (a): a pool of {@value #POOL_SIZE} permits. Each call holds a permit for
 * 150ms + 15ms * inflight + jitter, so latency grows with concurrency until callers time out waiting
 * for a permit (2s) and the call fails with {@link ScoringPoolExhaustedException} -> HTTP 503.
 * The caller (credit-service) sees that 503 and maps it to its own 503; the ERROR line with the
 * root cause lives in THIS service's log, under the same traceId.
 */
@Service
public class ScoringService {

    private static final Logger log = LoggerFactory.getLogger(ScoringService.class);

    static final int POOL_SIZE = 10;
    static final long ACQUIRE_TIMEOUT_MS = 2_000;
    static final long BASE_LATENCY_MS = 150;
    static final long LATENCY_PER_INFLIGHT_MS = 15;

    private final Semaphore pool = new Semaphore(POOL_SIZE, true);
    private final AtomicInteger inflight = new AtomicInteger();
    private final FailureModes failureModes;

    public ScoringService(FailureModes failureModes) {
        this.failureModes = failureModes;
    }

    public int score(String customerId) {
        int current = inflight.incrementAndGet();
        try {
            if (!failureModes.poolExhaustion()) {
                simulateLookup(BASE_LATENCY_MS);
                return computeScore(customerId);
            }
            if (!pool.tryAcquire(ACQUIRE_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
                log.error("scoring pool exhausted, inflight={}, waited={}ms, poolSize={}",
                        current, ACQUIRE_TIMEOUT_MS, POOL_SIZE);
                throw new ScoringPoolExhaustedException(
                        "scoring pool exhausted (inflight=" + current + ", poolSize=" + POOL_SIZE + ")");
            }
            try {
                simulateLookup(BASE_LATENCY_MS + LATENCY_PER_INFLIGHT_MS * inflight.get());
                return computeScore(customerId);
            } finally {
                pool.release();
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new ScoringPoolExhaustedException("interrupted while waiting for scoring pool");
        } finally {
            inflight.decrementAndGet();
        }
    }

    private static void simulateLookup(long latencyMs) throws InterruptedException {
        long jitter = ThreadLocalRandom.current().nextLong(0, 30);
        Thread.sleep(latencyMs + jitter);
    }

    /** Deterministic pseudo score in [300, 900] derived from the customer id. */
    static int computeScore(String customerId) {
        return 300 + Math.floorMod(customerId.hashCode(), 601);
    }
}
