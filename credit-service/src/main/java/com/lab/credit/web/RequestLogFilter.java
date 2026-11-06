package com.lab.credit.web;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.slf4j.MDC;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;
import org.springframework.web.servlet.HandlerMapping;

import java.io.IOException;

import static net.logstash.logback.argument.StructuredArguments.kv;

/**
 * Writes exactly one "request completed" log line per HTTP request with endpoint, httpStatus and
 * durationMs. Runs after Spring's observation filter, so traceId/spanId are already in the MDC.
 */
@Component
public class RequestLogFilter extends OncePerRequestFilter {

    private static final Logger log = LoggerFactory.getLogger(RequestLogFilter.class);
    private static final String[] MDC_KEYS = {"endpoint", "customerId", "applicationId"};

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
            throws ServletException, IOException {
        long start = System.nanoTime();
        MDC.put("endpoint", request.getMethod() + " " + request.getRequestURI());
        try {
            chain.doFilter(request, response);
        } finally {
            long durationMs = (System.nanoTime() - start) / 1_000_000;
            String endpoint = request.getMethod() + " " + routePattern(request);
            int status = response.getStatus();
            Throwable ex = (Throwable) request.getAttribute(GlobalExceptionHandler.EXCEPTION_ATTRIBUTE);
            MDC.remove("endpoint"); // the request line carries the route pattern as a structured field instead
            if (ex == null) {
                log.info("request completed", kv("endpoint", endpoint), kv("httpStatus", status),
                        kv("durationMs", durationMs));
            } else {
                log.info("request completed", kv("endpoint", endpoint), kv("httpStatus", status),
                        kv("durationMs", durationMs), kv("exceptionClass", ex.getClass().getName()),
                        kv("exceptionMessage", String.valueOf(ex.getMessage())));
            }
            for (String key : MDC_KEYS) {
                MDC.remove(key);
            }
        }
    }

    /** "/api/v1/loans/{applicationId}" instead of the concrete id, when Spring MVC matched a route. */
    private static String routePattern(HttpServletRequest request) {
        Object pattern = request.getAttribute(HandlerMapping.BEST_MATCHING_PATTERN_ATTRIBUTE);
        return pattern != null ? pattern.toString() : request.getRequestURI();
    }
}
