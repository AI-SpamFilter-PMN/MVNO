package com.mvno.intercept.subscriber;

import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

class EirTrackerTest {

    private EirTracker eirTracker;

    @BeforeEach
    void setUp() {
        eirTracker = new EirTracker(new SimpleMeterRegistry());
        eirTracker.reset();
    }

    @Test
    void testCheckEirBinding_AllowedFirstThreeSwaps() {
        String imei = "356923090000001";
        assertTrue(eirTracker.checkEirBinding(imei, "15551111111"));
        assertTrue(eirTracker.checkEirBinding(imei, "15552222222"));
        assertTrue(eirTracker.checkEirBinding(imei, "15553333333"));
    }

    @Test
    void testCheckEirBinding_BlockedOnFourthSwap() {
        String imei = "356923090000002";
        assertTrue(eirTracker.checkEirBinding(imei, "15551111111"));
        assertTrue(eirTracker.checkEirBinding(imei, "15552222222"));
        assertTrue(eirTracker.checkEirBinding(imei, "15553333333"));

        // 4th distinct MSISDN evaluation exceeds threshold >3
        assertFalse(eirTracker.checkEirBinding(imei, "15554444444"));
    }

    @Test
    void testCheckEirBinding_NullOrBlankImeiAllowed() {
        assertTrue(eirTracker.checkEirBinding(null, "15551111111"));
        assertTrue(eirTracker.checkEirBinding("", "15551111111"));
    }

    @Test
    void testEirTracker_SameMsisdnRepeatedBinding() {
        String imei = "356923090000003";
        // Multiple calls from the SAME MSISDN should count as 1 distinct binding
        assertTrue(eirTracker.checkEirBinding(imei, "15551111111"));
        assertTrue(eirTracker.checkEirBinding(imei, "15551111111"));
        assertTrue(eirTracker.checkEirBinding(imei, "15551111111"));
        assertTrue(eirTracker.checkEirBinding(imei, "15551111111"));
        assertTrue(eirTracker.checkEirBinding(imei, "15551111111"));
    }
}
