package com.mvno.intercept.config;

import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.web.servlet.HandlerInterceptor;

/**
 * Gateway API-Key Authentication Interceptor (Zero-Trust §1.2)
 *
 * Rejects HTTP requests to interception endpoints that do not present a valid
 * {@code X-API-Key} header matching the configured {@code intercept.api-key}
 * property. Returns HTTP 401 Unauthorized for missing or mismatched keys.
 *
 * @author MVNO Core Engineering Team
 * @version 1.0.0
 */
public class ApiKeyInterceptor implements HandlerInterceptor {

    public static final String API_KEY_HEADER = "X-API-Key";

    private final String apiKey;

    public ApiKeyInterceptor(final String apiKey) {
        this.apiKey = apiKey;
    }

    @Override
    public boolean preHandle(final HttpServletRequest request, final HttpServletResponse response, final Object handler) {
        final String provided = request.getHeader(API_KEY_HEADER);
        if (!apiKey.equals(provided)) {
            response.setStatus(HttpServletResponse.SC_UNAUTHORIZED);
            return false;
        }
        return true;
    }
}
