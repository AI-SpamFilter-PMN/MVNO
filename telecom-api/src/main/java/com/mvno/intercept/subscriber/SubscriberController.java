package com.mvno.intercept.subscriber;

import com.mvno.intercept.filter.AiFilterService;
import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

/**
 * Subscriber Policy & Telecom Interception REST Controller
 * 
 * Exposes REST API endpoints invoked by three core callers:
 * 1. OsmoSMSC / ESME: Submits SMS delivery hold queries to POST /api/v1/intercept/sms.
 * 2. Kamailio SIP Proxy: Queries voice call setup authorization to POST /api/v1/intercept/call.
 * 3. Web NOC Dashboard: Queries subscriber prepaid balances at GET /api/v1/intercept/subscriber/{msisdn}.
 * 
 * Multi-Layer Policy Pipeline:
 * - Layer 1 (Prepaid OCS Check): Checks balance from SQLite WAL mode. Balance <= 0 -> blocked.
 * - Layer 2 (EIR Hardware Check): Verifies hardware IMEI binding to block rapid SIM swaps.
 * - Layer 3 (AI Model Proxying): Forwards content/metadata to AI Spam Filter server.
 * 
 * @author MVNO Core Engineering Team
 * @version 1.0.0
 */
@RestController
@RequestMapping("/api/v1/intercept")
public class SubscriberController {

    private final SubscriberService subscriberService;
    private final AiFilterService aiFilterService;
    private final com.mvno.intercept.security.StirShakenCryptoService stirShakenCryptoService;
    private final Counter smsRequests;
    private final Counter smsBlocked;
    private final Counter callRequests;
    private final Counter callBlocked;
    private final Counter callBlockedEir;
    private final Counter callBlockedStir;
    private final Counter subscriberLookups;

    public SubscriberController(
            final SubscriberService subscriberService,
            final AiFilterService aiFilterService,
            final com.mvno.intercept.security.StirShakenCryptoService stirShakenCryptoService,
            final MeterRegistry meterRegistry) {
        this.subscriberService = subscriberService;
        this.aiFilterService = aiFilterService;
        this.stirShakenCryptoService = stirShakenCryptoService;
        this.smsRequests = meterRegistry.counter("mvno.sms.requests");
        this.smsBlocked = meterRegistry.counter("mvno.sms.blocked");
        this.callRequests = meterRegistry.counter("mvno.call.requests");
        this.callBlocked = meterRegistry.counter("mvno.call.blocked");
        this.callBlockedEir = meterRegistry.counter("mvno.call.blocked.eir");
        this.callBlockedStir = meterRegistry.counter("mvno.call.blocked.stir");
        this.subscriberLookups = meterRegistry.counter("mvno.subscriber.lookups");
    }

    /**
     * Retrieves prepaid account balance for subscriber phone number.
     * 
     * @param msisdn E.164 phone number string (e.g. "15551234567").
     * @return SubscriberResponse JSON.
     */
    @GetMapping("/subscriber/{msisdn}")
    public ResponseEntity<SubscriberResponse> getSubscriber(@PathVariable final String msisdn) {
        subscriberLookups.increment();
        final int balance = subscriberService.getBalance(msisdn);
        return ResponseEntity.ok(new SubscriberResponse(msisdn, balance));
    }

    /**
     * Evaluates SMS delivery authorization for incoming SMPP 3.4 / 5G NAS messages.
     * 
     * @param req SMS interception request DTO.
     * @return InterceptResponse decision.
     */
    @PostMapping("/sms")
    public ResponseEntity<InterceptResponse> interceptSms(@RequestBody final SMSInterceptRequest req) {
        smsRequests.increment();
        if (req == null || req.sender() == null || req.sender().isBlank()) {
            return ResponseEntity.badRequest().body(new InterceptResponse(false, "Invalid request: missing sender MSISDN"));
        }

        final int balance = subscriberService.getBalance(req.sender());
        if (balance <= 0) {
            smsBlocked.increment();
            return ResponseEntity.ok(new InterceptResponse(false, "Prepaid balance exhausted"));
        }

        final InterceptResponse result = aiFilterService.classifySms(req);
        if (!result.allow()) {
            smsBlocked.increment();
        }
        return ResponseEntity.ok(result);
    }

    /**
     * Evaluates SIP Voice Call setup authorization for incoming SIP INVITE requests (POST JSON).
     */
    @PostMapping("/call")
    public ResponseEntity<InterceptResponse> interceptCall(@RequestBody final CallInterceptRequest req) {
        return processCallIntercept(req, null, null, null, null, null);
    }

    /**
     * Evaluates SIP Voice Call setup authorization for incoming SIP INVITE requests (GET Query Params).
     */
    @GetMapping("/call")
    public ResponseEntity<InterceptResponse> interceptCallGet(
            @RequestParam(required = false) final String caller,
            @RequestParam(required = false) final String callee,
            @RequestParam(required = false, name = "call_id") final String callId,
            @RequestParam(required = false) final String imei,
            @RequestParam(required = false) final String identity) {
        return processCallIntercept(null, caller, callee, callId, imei, identity);
    }

    private ResponseEntity<InterceptResponse> processCallIntercept(
            final CallInterceptRequest req,
            final String caller,
            final String callee,
            final String callId,
            final String imei,
            final String identity) {
        callRequests.increment();
        final String effectiveCaller = (req != null && req.caller() != null && !req.caller().isBlank()) ? req.caller() : caller;
        final String effectiveCallee = (req != null && req.callee() != null && !req.callee().isBlank()) ? req.callee() : callee;
        final String effectiveCallId = (req != null && req.callId() != null && !req.callId().isBlank()) ? req.callId() : callId;
        final String effectiveImei = (req != null && req.imei() != null && !req.imei().isBlank()) ? req.imei() : imei;
        final String effectiveIdentity = (req != null && req.identity() != null && !req.identity().isBlank()) ? req.identity() : identity;

        if (effectiveCaller == null || effectiveCaller.isBlank()) {
            return ResponseEntity.badRequest().body(new InterceptResponse(false, "Invalid request: missing caller MSISDN"));
        }

        // STIR/SHAKEN Cryptographic Caller ID Enforcement (RFC 8224 / 8588)
        if (effectiveIdentity != null && !effectiveIdentity.isBlank()) {
            final boolean valid = stirShakenCryptoService.verifyPassport(effectiveIdentity);
            if (!valid) {
                callBlocked.increment();
                callBlockedStir.increment();
                return ResponseEntity.ok(new InterceptResponse(false, "STIR/SHAKEN: Invalid Caller ID Cryptographic Attestation"));
            }
        }

        final int balance = subscriberService.getBalance(effectiveCaller);
        if (balance <= 0) {
            callBlocked.increment();
            return ResponseEntity.ok(new InterceptResponse(false, "Prepaid balance exhausted"));
        }

        if (effectiveImei != null && !effectiveImei.isBlank()
                && !subscriberService.checkEirBinding(effectiveImei, effectiveCaller)) {
            callBlockedEir.increment();
            return ResponseEntity.ok(new InterceptResponse(false, "EIR: SIM swap detected"));
        }

        final CallInterceptRequest fullReq = new CallInterceptRequest(effectiveCaller, effectiveCallee, effectiveCallId, effectiveImei, effectiveIdentity);
        final InterceptResponse result = aiFilterService.classifyCall(fullReq);
        if (!result.allow()) {
            callBlocked.increment();
        }
        return ResponseEntity.ok(result);
    }

    public record SubscriberResponse(String msisdn, int balance) {}
}
