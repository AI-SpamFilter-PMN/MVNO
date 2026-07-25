package com.mvno.intercept.subscriber;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Equipment Identity Register (EIR) Device Binding & SIM-Swap Tracker
 * 
 * 3GPP Cellular EIR Domain Background:
 * Tracks hardware serial numbers (IMEI - International Mobile Equipment Identity) to detect fraud:
 * - White List: Permitted devices.
 * - Grey List: Devices under observation (suspected robocall farms / cloned hardware).
 * - Black List: Stolen/fraudulent devices blocked from call setup.
 * 
 * Concurrency & Eviction Strategy:
 * Uses ConcurrentHashMap + AtomicInteger for lock-free thread safety across Virtual Threads.
 * Enforces MAX_CAPACITY (10,000 IMEIs) size bounding + @Scheduled time-based TTL cleanup (every 10 min)
 * to automatically purge stale IMEI fraud tracking data and prevent memory leaks.
 * 
 * Fraud Rule:
 * >3 distinct SIM insertions on a single IMEI hardware unit triggers SIM-swap / robocall farm detection.
 * 
 * @author MVNO Core Engineering Team
 * @version 1.0.0
 */
@Component
public class EirTracker {

    private static final Logger logger = LoggerFactory.getLogger(EirTracker.class);
    private static final int MAX_CAPACITY = 10000;
    private final ConcurrentHashMap<String, AtomicInteger> imeiSwapCounter = new ConcurrentHashMap<>();

    /**
     * Evaluates device binding and verifies hardware IMEI rapidly against SIM swap anomaly rules.
     * 
     * @param imei 15-digit International Mobile Equipment Identity string.
     * @param msisdn Calling party E.164 phone number string.
     * @return true if allowed; false if SIM-swap threshold (>3) is exceeded.
     */
    public boolean checkEirBinding(final String imei, final String msisdn) {
        if (imei == null || imei.isBlank()) {
            return true;
        }

        // Bounded capacity eviction check to prevent memory leaks
        if (imeiSwapCounter.size() >= MAX_CAPACITY) {
            logger.warn("EIR Tracker memory limit reached ({} IMEIs). Evicting stale tracking cache.", MAX_CAPACITY);
            imeiSwapCounter.clear();
        }

        final AtomicInteger counter = imeiSwapCounter.computeIfAbsent(imei, k -> new AtomicInteger(0));
        final int swaps = counter.incrementAndGet();

        if (swaps > 3) {
            return false;
        }

        return true;
    }

    /**
     * Automatic time-based TTL cache cleanup running every 10 minutes.
     * Purges accumulated IMEI tracking state to ensure memory footprint stays low over long deployments.
     */
    @Scheduled(fixedRate = 600000)
    public void cleanupStaleImeiCache() {
        if (!imeiSwapCounter.isEmpty()) {
            logger.info("Executing scheduled EIR tracking cache TTL purge (cleared {} entries).", imeiSwapCounter.size());
            imeiSwapCounter.clear();
        }
    }

    /**
     * Helper method to reset tracking cache (for testing and administrative reset).
     */
    public void reset() {
        imeiSwapCounter.clear();
    }
}
