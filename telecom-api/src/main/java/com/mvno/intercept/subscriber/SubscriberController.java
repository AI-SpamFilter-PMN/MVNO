package com.mvno.intercept.subscriber;

import com.mvno.intercept.filter.AiFilterService;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

/**
 * ==============================================================================
 * Subscriber Interception REST Controller
 * ==============================================================================
 * Exposes REST endpoints called by Kamailio, OsmoSMSC, and Web UI teammates:
 * 1. POST /api/v1/intercept/sms  — Intercept SMS messages
 * 2. POST /api/v1/intercept/call — Intercept Voice calls
 * 3. GET  /api/v1/intercept/subscriber/{msisdn} — Query subscriber balance
 */
@RestController
@RequestMapping("/api/v1/intercept")
public class SubscriberController {

    private final SubscriberService subscriberService;
    private final AiFilterService aiFilterService;

    public SubscriberController(SubscriberService subscriberService, AiFilterService aiFilterService) {
        this.subscriberService = subscriberService;
        this.aiFilterService = aiFilterService;
    }

    /**
     * Endpoint for Web UI teammates to query subscriber balance and profile.
     */
    @GetMapping("/subscriber/{msisdn}")
    public ResponseEntity<?> getSubscriber(@PathVariable String msisdn) {
        int balance = subscriberService.getBalance(msisdn);
        return ResponseEntity.ok(new SubscriberResponse(msisdn, balance));
    }

    /**
     * Intercepts SMS delivery from OsmoSMSC (SMPP).
     * 1. Checks prepaid balance ($1/SMS). If balance == 0, returns allow: false immediately.
     * 2. Proxies payload to AI Filter model server.
     */
    @PostMapping("/sms")
    public ResponseEntity<InterceptResponse> interceptSms(@RequestBody SMSInterceptRequest req) {
        int balance = subscriberService.getBalance(req.sender());
        if (balance <= 0) {
            return ResponseEntity.ok(new InterceptResponse(false, "Prepaid balance exhausted"));
        }
        var result = aiFilterService.classifySms(req);
        return ResponseEntity.ok(result);
    }

    /**
     * Intercepts SIP Voice Call INVITEs from Kamailio.
     * 1. Checks prepaid balance ($5/call). If balance == 0, returns allow: false immediately.
     * 2. Checks EIR IMEI binding. If SIM swap detected, returns allow: false.
     * 3. Proxies call metadata to AI Filter model server.
     */
    @PostMapping("/call")
    public ResponseEntity<InterceptResponse> interceptCall(@RequestBody CallInterceptRequest req) {
        int balance = subscriberService.getBalance(req.caller());
        if (balance <= 0) {
            return ResponseEntity.ok(new InterceptResponse(false, "Prepaid balance exhausted"));
        }
        if (req.imei() != null && !req.imei().isBlank()
                && !subscriberService.checkEirBinding(req.imei(), req.caller())) {
            return ResponseEntity.ok(new InterceptResponse(false, "EIR: SIM swap detected"));
        }
        var result = aiFilterService.classifyCall(req);
        return ResponseEntity.ok(result);
    }

    public record SubscriberResponse(String msisdn, int balance) {}
}
