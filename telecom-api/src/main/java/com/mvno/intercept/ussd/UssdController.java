package com.mvno.intercept.ussd;

import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.Map;

/**
 * USSD Gateway REST Controller
 */
@RestController
@RequestMapping("/api/v1/intercept/ussd")
public class UssdController {

    private final UssdSessionService ussdService;

    public UssdController(final UssdSessionService ussdService) {
        this.ussdService = ussdService;
    }

    @PostMapping
    public ResponseEntity<UssdSessionService.UssdResponse> handleUssd(@RequestBody final Map<String, String> req) {
        final String msisdn = req.getOrDefault("msisdn", req.getOrDefault("sender", ""));
        final String input = req.getOrDefault("input", req.getOrDefault("content", "*100#"));

        final UssdSessionService.UssdResponse resp = ussdService.processUssd(msisdn, input);
        return ResponseEntity.ok(resp);
    }
}
