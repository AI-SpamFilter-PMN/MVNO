package com.mvno.intercept;

import com.mvno.intercept.subscriber.InterceptResponse;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;

/**
 * Global Exception Handler for Telecom Gateway API.
 * Sanitizes uncaught exceptions and enforces SLA fallback responses.
 */
@RestControllerAdvice
public class GlobalExceptionHandler {

    private static final Logger log = LoggerFactory.getLogger(GlobalExceptionHandler.class);

    @ExceptionHandler(Exception.class)
    public ResponseEntity<InterceptResponse> handleAll(Exception e) {
        log.error("Unhandled exception in Gateway API: {}", e.getMessage(), e);
        return ResponseEntity.status(500)
                .body(new InterceptResponse(true, "Internal error — SLA allow"));
    }
}
