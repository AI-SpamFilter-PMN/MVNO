package com.mvno.intercept.config;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Configuration;
import org.springframework.web.servlet.config.annotation.InterceptorRegistry;
import org.springframework.web.servlet.config.annotation.WebMvcConfigurer;

/**
 * Web MVC Configuration — Gateway API-Key Authentication (Zero-Trust Section 1.2)
 *
 * Registers the {@link ApiKeyInterceptor} on all {@code /api/v1/intercept/**}
 * endpoints. The key is read from the {@code intercept.api-key} property
 * (environment override: {@code X_API_KEY}).
 *
 * @author MVNO Core Engineering Team
 * @version 1.0.0
 */
@Configuration
public class WebConfig implements WebMvcConfigurer {

    private final String apiKey;

    public WebConfig(@Value("${intercept.api-key}") final String apiKey) {
        this.apiKey = apiKey;
    }

    @Override
    public void addInterceptors(final InterceptorRegistry registry) {
        registry.addInterceptor(new ApiKeyInterceptor(apiKey))
                .addPathPatterns("/api/v1/intercept/**");
    }
}
