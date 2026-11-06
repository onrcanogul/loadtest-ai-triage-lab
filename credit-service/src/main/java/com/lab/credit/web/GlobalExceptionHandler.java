package com.lab.credit.web;

import com.lab.credit.service.LoanNotFoundException;
import com.lab.credit.service.ScoringUnavailableException;
import jakarta.servlet.http.HttpServletRequest;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.MethodArgumentNotValidException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;

import java.util.Map;

import static net.logstash.logback.argument.StructuredArguments.kv;

@RestControllerAdvice
public class GlobalExceptionHandler {

    private static final Logger log = LoggerFactory.getLogger(GlobalExceptionHandler.class);

    /** Request attribute read by {@link RequestLogFilter} so the request log line carries the exception. */
    static final String EXCEPTION_ATTRIBUTE = GlobalExceptionHandler.class.getName() + ".exception";

    @ExceptionHandler(ScoringUnavailableException.class)
    public ResponseEntity<Map<String, String>> scoringUnavailable(ScoringUnavailableException ex, HttpServletRequest request) {
        request.setAttribute(EXCEPTION_ATTRIBUTE, ex);
        log.warn("scoring unavailable", kv("exceptionClass", ex.getClass().getSimpleName()),
                kv("exceptionMessage", ex.getMessage()));
        return error(HttpStatus.SERVICE_UNAVAILABLE, "SCORING_UNAVAILABLE", ex.getMessage());
    }

    @ExceptionHandler(LoanNotFoundException.class)
    public ResponseEntity<Map<String, String>> notFound(LoanNotFoundException ex) {
        return error(HttpStatus.NOT_FOUND, "NOT_FOUND", ex.getMessage());
    }

    @ExceptionHandler(MethodArgumentNotValidException.class)
    public ResponseEntity<Map<String, String>> invalid(MethodArgumentNotValidException ex) {
        return error(HttpStatus.BAD_REQUEST, "VALIDATION_ERROR", ex.getBindingResult().toString());
    }

    @ExceptionHandler(Exception.class)
    public ResponseEntity<Map<String, String>> unexpected(Exception ex, HttpServletRequest request) {
        request.setAttribute(EXCEPTION_ATTRIBUTE, ex);
        log.error("unhandled exception", kv("exceptionClass", ex.getClass().getName()),
                kv("exceptionMessage", String.valueOf(ex.getMessage())), ex);
        return error(HttpStatus.INTERNAL_SERVER_ERROR, "INTERNAL_ERROR", "unexpected error");
    }

    private static ResponseEntity<Map<String, String>> error(HttpStatus status, String code, String message) {
        return ResponseEntity.status(status).body(Map.of("error", code, "message", message));
    }
}
