package com.mvno.intercept.security;

import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.Map;

/**
 * STIR/SHAKEN Cryptographic Attestation REST Controller
 */
@RestController
@RequestMapping("/api/v1/intercept/stir-shaken")
public class StirShakenController {

    private final StirShakenCryptoService cryptoService;

    public StirShakenController(final StirShakenCryptoService cryptoService) {
        this.cryptoService = cryptoService;
    }

    @PostMapping("/sign")
    public ResponseEntity<Map<String, String>> sign(@RequestBody final Map<String, String> req) {
        final String orig = req.getOrDefault("orig", "");
        final String dest = req.getOrDefault("dest", "");
        final String attest = req.getOrDefault("attest", "A");

        final String identityHeader = cryptoService.signPassport(orig, dest, attest);
        return ResponseEntity.ok(Map.of(
            "identity", identityHeader,
            "attestation", attest,
            "status", "SIGNED"
        ));
    }

    @PostMapping("/verify")
    public ResponseEntity<Map<String, Object>> verify(@RequestBody final Map<String, String> req) {
        final String identity = req.getOrDefault("identity", "");
        final boolean valid = cryptoService.verifyPassport(identity);
        return ResponseEntity.ok(Map.of(
            "valid", valid,
            "status", valid ? "VERIFIED_VALID" : "SIGNATURE_INVALID"
        ));
    }
}
