package com.mvno.intercept.subscriber;

import com.mvno.intercept.filter.AiFilterService;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

/**
 * <h1>Subscriber Policy &amp; Telecom Interception REST Controller</h1>
 * 
 * <p>The {@code SubscriberController} exposes synchronous HTTP REST API endpoints invoked by three
 * distinct network callers:</p>
 * <ol>
 *   <li><b>OsmoSMSC / ESME Gateway:</b> Submits SMS delivery hold authorization queries to {@code POST /api/v1/intercept/sms}.</li>
 *   <li><b>Kamailio SIP Proxy:</b> Queries voice call setup authorization during SIP {@code INVITE} at {@code POST /api/v1/intercept/call}.</li>
 *   <li><b>Web NOC Dashboard:</b> Queries subscriber prepaid account balances at {@code GET /api/v1/intercept/subscriber/{msisdn}}.</li>
 * </ol>
 * 
 * <h2>Multi-Layer Interception Pipeline</h2>
 * <ul>
 *   <li><b>Layer 1 (Prepaid OCS Check):</b> Queries subscriber balance from SQLite WAL mode. If balance &le; 0, drops traffic immediately.</li>
 *   <li><b>Layer 2 (EIR Hardware Check):</b> Verifies hardware IMEI binding against rapid SIM-swap anomalies.</li>
 *   <li><b>Layer 3 (AI Model Proxying):</b> Forwards SMS text / Call metadata to the external AI Spam Model server.</li>
 * </ul>
 * 
 * @author MVNO Core Engineering Team
 * @version 1.0.0
 * @see com.mvno.intercept.subscriber.SubscriberService
 * @see com.mvno.intercept.filter.AiFilterService
 */
@RestController
@RequestMapping("/api/v1/intercept")
public class SubscriberController {

    private final SubscriberService subscriberService;
    private final AiFilterService aiFilterService;

    /**
     * Constructs the Subscriber Controller with required business service dependencies.
     * 
     * @param subscriberService Domain service managing subscriber database queries and EIR tracking.
     * @param aiFilterService SLA-resilient proxy service communicating with external AI classification model.
     */
    public SubscriberController(final SubscriberService subscriberService, final AiFilterService aiFilterService) {
        this.subscriberService = subscriberService;
        this.aiFilterService = aiFilterService;
    }

    /**
     * Retrieves the prepaid account balance for a given subscriber phone number.
     * 
     * @param msisdn Target subscriber E.164 phone number string (e.g. "15551234567").
     * @return {@link ResponseEntity} containing {@link SubscriberResponse} JSON with MSISDN and balance ($).
     */
    @GetMapping("/subscriber/{msisdn}")
    public ResponseEntity<SubscriberResponse> getSubscriber(@PathVariable final String msisdn) {
        final int balance = subscriberService.getBalance(msisdn);
        return ResponseEntity.ok(new SubscriberResponse(msisdn, balance));
    }

    /**
     * Evaluates SMS delivery authorization for incoming SMPP 3.4 / 5G NAS messages.
     * 
     * @param req The incoming {@link SMSInterceptRequest} DTO.
     * @return {@link ResponseEntity} containing {@link InterceptResponse} decision.
     */
    @PostMapping("/sms")
    public ResponseEntity<InterceptResponse> interceptSms(@RequestBody final SMSInterceptRequest req) {
        // Layer 1: Verify prepaid account balance ($1/SMS tariff rate)
        final int balance = subscriberService.getBalance(req.sender());
        if (balance <= 0) {
            return ResponseEntity.ok(new InterceptResponse(false, "Prepaid balance exhausted"));
        }

        // Layer 2: Forward SMS text content to AI Spam Filter server for classification
        final InterceptResponse result = aiFilterService.classifySms(req);
        return ResponseEntity.ok(result);
    }

    /**
     * Evaluates SIP Voice Call setup authorization for incoming SIP {@code INVITE} requests from Kamailio.
     * 
     * @param req The incoming {@link CallInterceptRequest} DTO containing caller, callee, Call-ID, and IMEI.
     * @return {@link ResponseEntity} containing {@link InterceptResponse} decision.
     */
    @PostMapping("/call")
    public ResponseEntity<InterceptResponse> interceptCall(@RequestBody final CallInterceptRequest req) {
        // Layer 1: Verify caller prepaid account balance ($5/call tariff rate)
        final int balance = subscriberService.getBalance(req.caller());
        if (balance <= 0) {
            return ResponseEntity.ok(new InterceptResponse(false, "Prepaid balance exhausted"));
        }

        // Layer 2: Verify Equipment Identity Register (EIR) hardware binding to block SIM-swap fraud
        if (req.imei() != null && !req.imei().isBlank()
                && !subscriberService.checkEirBinding(req.imei(), req.caller())) {
            return ResponseEntity.ok(new InterceptResponse(false, "EIR: SIM swap detected"));
        }

        // Layer 3: Forward call metadata to AI Spam Filter server for classification
        final InterceptResponse result = aiFilterService.classifyCall(req);
        return ResponseEntity.ok(result);
    }

    /** DTO Record representing JSON subscriber response. */
    public record SubscriberResponse(String msisdn, int balance) {}
}
