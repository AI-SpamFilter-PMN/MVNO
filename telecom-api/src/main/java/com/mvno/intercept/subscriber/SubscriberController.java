package com.mvno.intercept.subscriber;

import com.mvno.intercept.filter.AiFilterService;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

/**
 * Subscriber Policy & Telecom Interception REST Controller.
 * 
 * INTERFACE BOUNDARY:
 * Exposes synchronous HTTP REST endpoints called by three distinct callers:
 * 1. OsmoSMSC / ESME Gateway: Submits SMS delivery authorization requests to `/api/v1/intercept/sms`.
 * 2. Kamailio SIP Proxy: Queries voice call setup authorization during SIP INVITE at `/api/v1/intercept/call`.
 * 3. Web UI Teammates (Mahmoud & Ahmed): Fetch subscriber balances at `/api/v1/intercept/subscriber/{msisdn}`.
 * 
 * POLICY EVALUATION PIPELINE:
 * Step 1: Pre-flight Account & Fraud Verification (Prepaid OCS balance & EIR IMEI binding).
 * Step 2: Content/Metadata Proxying (forwards payload to AI Spam Filter server if pre-flight checks pass).
 */
// `@RestController` combines `@Controller` and `@ResponseBody` so returned Java objects serialize directly to JSON.
// `@RequestMapping` defines the shared root URL path prefix for all endpoints in this controller.
@RestController
@RequestMapping("/api/v1/intercept")
public class SubscriberController {

    private final SubscriberService subscriberService;
    private final AiFilterService aiFilterService;

    public SubscriberController(SubscriberService subscriberService, AiFilterService aiFilterService) {
        this.subscriberService = subscriberService;
        this.aiFilterService = aiFilterService;
    }

    // `@GetMapping` routes HTTP GET requests. `@PathVariable` extracts `{msisdn}` from the URL path string.
    @GetMapping("/subscriber/{msisdn}")
    public ResponseEntity<?> getSubscriber(@PathVariable String msisdn) {
        int balance = subscriberService.getBalance(msisdn);
        return ResponseEntity.ok(new SubscriberResponse(msisdn, balance));
    }

    // `@PostMapping` routes HTTP POST requests. `@RequestBody` deserializes incoming JSON into Java Record DTOs.
    @PostMapping("/sms")
    public ResponseEntity<InterceptResponse> interceptSms(@RequestBody SMSInterceptRequest req) {
        // Step 1: Verify prepaid account balance ($1/SMS tariff rate)
        int balance = subscriberService.getBalance(req.sender());
        if (balance <= 0) {
            return ResponseEntity.ok(new InterceptResponse(false, "Prepaid balance exhausted"));
        }

        // Step 2: Forward SMS text content to AI Spam Filter server for classification
        var result = aiFilterService.classifySms(req);
        return ResponseEntity.ok(result);
    }

    /**
     * Intercepts SIP Voice Call setup (INVITE) requests from Kamailio.
     * 
     * @param req Request DTO containing caller MSISDN, callee MSISDN, SIP Call-ID, and hardware IMEI.
     * @return InterceptResponse JSON indicating whether call setup should proceed or drop.
     */
    @PostMapping("/call")
    public ResponseEntity<InterceptResponse> interceptCall(@RequestBody CallInterceptRequest req) {
        // Step 1: Verify caller prepaid account balance ($5/call tariff rate)
        int balance = subscriberService.getBalance(req.caller());
        if (balance <= 0) {
            return ResponseEntity.ok(new InterceptResponse(false, "Prepaid balance exhausted"));
        }

        // Step 2: Verify Equipment Identity Register (EIR) hardware binding to block SIM-swap fraud
        if (req.imei() != null && !req.imei().isBlank()
                && !subscriberService.checkEirBinding(req.imei(), req.caller())) {
            return ResponseEntity.ok(new InterceptResponse(false, "EIR: SIM swap detected"));
        }

        // Step 3: Forward call metadata to AI Spam Filter server for classification
        var result = aiFilterService.classifyCall(req);
        return ResponseEntity.ok(result);
    }

    /** DTO Record for subscriber REST queries. */
    public record SubscriberResponse(String msisdn, int balance) {}
}
