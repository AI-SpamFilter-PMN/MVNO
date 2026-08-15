package com.mvno.intercept.subscriber;

import com.mvno.intercept.filter.AiFilterService;
import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.Mockito;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.any;

class SubscriberControllerTest {

    private SubscriberService subscriberService;
    private AiFilterService aiFilterService;
    private com.mvno.intercept.security.StirShakenCryptoService stirShakenCryptoService;
    private SubscriberController controller;

    @BeforeEach
    void setUp() {
        subscriberService = Mockito.mock(SubscriberService.class);
        aiFilterService = Mockito.mock(AiFilterService.class);
        stirShakenCryptoService = Mockito.mock(com.mvno.intercept.security.StirShakenCryptoService.class);
        controller = new SubscriberController(subscriberService, aiFilterService, stirShakenCryptoService, new SimpleMeterRegistry());
    }

    @Test
    void testGetSubscriberBalance() {
        Mockito.when(subscriberService.getBalance("15551234567")).thenReturn(50);

        ResponseEntity<SubscriberController.SubscriberResponse> response = controller.getSubscriber("15551234567");

        assertEquals(HttpStatus.OK, response.getStatusCode());
        assertNotNull(response.getBody());
        assertEquals("15551234567", response.getBody().msisdn());
        assertEquals(50, response.getBody().balance());
    }

    @Test
    void testInterceptSms_ExhaustedBalance() {
        Mockito.when(subscriberService.isLocalSubscriber("15550000000")).thenReturn(true);
        Mockito.when(subscriberService.getBalance("15550000000")).thenReturn(0);

        SMSInterceptRequest req = new SMSInterceptRequest("15550000000", "15559999999", "Hello world");
        ResponseEntity<InterceptResponse> response = controller.interceptSms(req);

        assertEquals(HttpStatus.OK, response.getStatusCode());
        assertNotNull(response.getBody());
        assertFalse(response.getBody().allow());
        assertEquals("Prepaid balance exhausted", response.getBody().reason());
    }

    @Test
    void testInterceptSms_ExternalSenderBypassesBalanceCheck() {
        // External sender not registered in local subscriber database
        Mockito.when(subscriberService.isLocalSubscriber("19998887777")).thenReturn(false);
        Mockito.when(aiFilterService.classifySms(any())).thenReturn(new InterceptResponse(true, "Clean SMS"));

        SMSInterceptRequest req = new SMSInterceptRequest("19998887777", "15551234567", "Inbound A2P / Inter-Carrier SMS");
        ResponseEntity<InterceptResponse> response = controller.interceptSms(req);

        assertEquals(HttpStatus.OK, response.getStatusCode());
        assertNotNull(response.getBody());
        assertTrue(response.getBody().allow());
        assertEquals("Clean SMS", response.getBody().reason());
    }

    @Test
    void testInterceptSms_AllowedSms() {
        Mockito.when(subscriberService.isLocalSubscriber("15551234567")).thenReturn(true);
        Mockito.when(subscriberService.getBalance("15551234567")).thenReturn(10);
        Mockito.when(aiFilterService.classifySms(any())).thenReturn(new InterceptResponse(true, "Clean SMS"));

        SMSInterceptRequest req = new SMSInterceptRequest("15551234567", "15559999999", "Legitimate text message");
        ResponseEntity<InterceptResponse> response = controller.interceptSms(req);

        assertEquals(HttpStatus.OK, response.getStatusCode());
        assertNotNull(response.getBody());
        assertTrue(response.getBody().allow());
        assertEquals("Clean SMS", response.getBody().reason());
    }

    @Test
    void testInterceptSms_InvalidPayload() {
        SMSInterceptRequest req = new SMSInterceptRequest("", "15559999999", "Hello world");
        ResponseEntity<InterceptResponse> response = controller.interceptSms(req);

        assertEquals(HttpStatus.BAD_REQUEST, response.getStatusCode());
        assertNotNull(response.getBody());
        assertFalse(response.getBody().allow());
    }

    @Test
    void testInterceptCall_EirSimSwapBlocked() {
        Mockito.when(subscriberService.isLocalSubscriber("15551234567")).thenReturn(true);
        Mockito.when(subscriberService.getBalance("15551234567")).thenReturn(20);
        Mockito.when(subscriberService.checkEirBinding("867530900000001", "15551234567")).thenReturn(false);

        CallInterceptRequest req = new CallInterceptRequest("15551234567", "15558888888", "call-id-123", "867530900000001");
        ResponseEntity<InterceptResponse> response = controller.interceptCall(req);

        assertEquals(HttpStatus.OK, response.getStatusCode());
        assertNotNull(response.getBody());
        assertFalse(response.getBody().allow());
        assertEquals("EIR: SIM swap detected", response.getBody().reason());
    }

    @Test
    void testInterceptCall_ZeroBalance() {
        Mockito.when(subscriberService.isLocalSubscriber("15550000000")).thenReturn(true);
        Mockito.when(subscriberService.getBalance("15550000000")).thenReturn(0);

        CallInterceptRequest req = new CallInterceptRequest("15550000000", "15558888888", "call-id-zero", "356938035643809");
        ResponseEntity<InterceptResponse> response = controller.interceptCall(req);

        assertEquals(HttpStatus.OK, response.getStatusCode());
        assertNotNull(response.getBody());
        assertFalse(response.getBody().allow());
        assertEquals("Prepaid balance exhausted", response.getBody().reason());
    }

    @Test
    void testInterceptCall_AllowedCall() {
        Mockito.when(subscriberService.getBalance("15551234567")).thenReturn(100);
        Mockito.when(subscriberService.checkEirBinding("356938035643809", "15551234567")).thenReturn(true);
        Mockito.when(aiFilterService.classifyCall(any())).thenReturn(new InterceptResponse(true, "Clean call"));

        CallInterceptRequest req = new CallInterceptRequest("15551234567", "15558888888", "call-id-clean", "356938035643809");
        ResponseEntity<InterceptResponse> response = controller.interceptCall(req);

        assertEquals(HttpStatus.OK, response.getStatusCode());
        assertNotNull(response.getBody());
        assertTrue(response.getBody().allow());
        assertEquals("Clean call", response.getBody().reason());
    }

    @Test
    void testInterceptCallGet_MissingCallerBadRequest() {
        ResponseEntity<InterceptResponse> response = controller.interceptCallGet(null, "15558888888", "call-id-get", null, null);

        assertEquals(HttpStatus.BAD_REQUEST, response.getStatusCode());
        assertNotNull(response.getBody());
        assertFalse(response.getBody().allow());
        assertEquals("Invalid request: missing caller MSISDN", response.getBody().reason());
    }

    @Test
    void testInterceptCall_StirShakenSpoofBlocked() {
        Mockito.when(stirShakenCryptoService.verifyPassport("invalid.jwt.token")).thenReturn(false);

        CallInterceptRequest req = new CallInterceptRequest("15551234567", "15558888888", "call-id-spoof", "356938035643809", "invalid.jwt.token");
        ResponseEntity<InterceptResponse> response = controller.interceptCall(req);

        assertEquals(HttpStatus.OK, response.getStatusCode());
        assertNotNull(response.getBody());
        assertFalse(response.getBody().allow());
        assertEquals("STIR/SHAKEN: Invalid Caller ID Cryptographic Attestation", response.getBody().reason());
    }
}
