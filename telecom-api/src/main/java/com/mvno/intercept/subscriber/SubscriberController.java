package com.mvno.intercept.subscriber;

import com.mvno.intercept.filter.AiFilterService;
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

    public SubscriberController(final SubscriberService subscriberService, final AiFilterService aiFilterService) {
        this.subscriberService = subscriberService;
        this.aiFilterService = aiFilterService;
    }

    /**
     * Retrieves prepaid account balance for subscriber phone number.
     * 
     * @param msisdn E.164 phone number string (e.g. "15551234567").
     * @return SubscriberResponse JSON.
     */
    @GetMapping("/subscriber/{msisdn}")
    public ResponseEntity<SubscriberResponse> getSubscriber(@PathVariable final String msisdn) {
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
        // Layer 1: Verify prepaid account balance ($1/SMS tariff rate)
        final int balance = subscriberService.getBalance(req.sender());
        if (balance <= 0) {
            return ResponseEntity.ok(new InterceptResponse(false, "Prepaid balance exhausted"));
        }

        // Layer 2: Forward SMS text content to AI Spam Filter server
        final InterceptResponse result = aiFilterService.classifySms(req);
        return ResponseEntity.ok(result);
    }

    /**
     * Evaluates SIP Voice Call setup authorization for incoming SIP INVITE requests from Kamailio.
     * 
     * @param req Call interception request DTO.
     * @return InterceptResponse decision.
     */
    @PostMapping("/call")
    public ResponseEntity<InterceptResponse> interceptCall(@RequestBody final CallInterceptRequest req) {
        // Layer 1: Verify caller prepaid account balance ($5/call tariff rate)
        final int balance = subscriberService.getBalance(req.caller());
        if (balance <= 0) {
            return ResponseEntity.ok(new InterceptResponse(false, "Prepaid balance exhausted"));
        }

        // Layer 2: Verify Equipment Identity Register (EIR) hardware binding
        if (req.imei() != null && !req.imei().isBlank()
                && !subscriberService.checkEirBinding(req.imei(), req.caller())) {
            return ResponseEntity.ok(new InterceptResponse(false, "EIR: SIM swap detected"));
        }

        // Layer 3: Forward call metadata to AI Spam Filter server
        final InterceptResponse result = aiFilterService.classifyCall(req);
        return ResponseEntity.ok(result);
    }

    public record SubscriberResponse(String msisdn, int balance) {}
}
