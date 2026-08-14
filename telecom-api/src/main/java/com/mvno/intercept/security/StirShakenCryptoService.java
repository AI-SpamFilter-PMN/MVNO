package com.mvno.intercept.security;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

import java.nio.charset.StandardCharsets;
import java.security.*;
import java.security.spec.ECGenParameterSpec;
import java.util.Base64;
import java.util.UUID;
import java.util.regex.Pattern;

/**
 * STIR/SHAKEN Cryptographic Caller ID Attestation Service (RFC 8224 / RFC 8588)
 *
 * Implements standard ES256 (ECDSA P-256 + SHA-256) PASSporT signing and verification.
 * Generates compact JWS tokens: <Base64Url(Header)>.<Base64Url(Payload)>.<Base64Url(Signature)>
 *
 * @author MVNO Core Engineering Team
 * @version 1.0.0
 */
@Service
public class StirShakenCryptoService {

    private static final Logger logger = LoggerFactory.getLogger(StirShakenCryptoService.class);
    private static final String CERT_URL = "https://cert.mvno.net/root.pem";

    private final KeyPair keyPair;

    public StirShakenCryptoService() {
        try {
            final KeyPairGenerator kpg = KeyPairGenerator.getInstance("EC");
            kpg.initialize(new ECGenParameterSpec("secp256r1"));
            this.keyPair = kpg.generateKeyPair();
            logger.info("STIR/SHAKEN ES256 ECDSA P-256 KeyPair initialized successfully.");
        } catch (final Exception e) {
            throw new IllegalStateException("Failed to initialize STIR/SHAKEN ECDSA KeyPair", e);
        }
    }

    /**
     * Signs a standard RFC 8588 SHAKEN PASSporT token.
     *
     * @param origTn Calling E.164 MSISDN
     * @param destTn Called E.164 MSISDN
     * @param attest Attestation level ("A", "B", or "C")
     * @return Compact serialized JWS string and SIP Identity header value
     */
    public String signPassport(final String origTn, final String destTn, final String attest) {
        try {
            final long iat = System.currentTimeMillis() / 1000L;
            final String origId = "urn:uuid:" + UUID.randomUUID();

            final String headerJson = String.format(
                "{\"alg\":\"ES256\",\"ppt\":\"shaken\",\"typ\":\"passport\",\"x5u\":\"%s\"}",
                CERT_URL
            );

            final String payloadJson = String.format(
                "{\"attest\":\"%s\",\"dest\":{\"tn\":[\"%s\"]},\"iat\":%d,\"orig\":{\"tn\":\"%s\"},\"origid\":\"%s\"}",
                attest != null ? attest : "A",
                destTn != null ? destTn : "",
                iat,
                origTn != null ? origTn : "",
                origId
            );

            final String encodedHeader = base64Url(headerJson.getBytes(StandardCharsets.UTF_8));
            final String encodedPayload = base64Url(payloadJson.getBytes(StandardCharsets.UTF_8));
            final String signingInput = encodedHeader + "." + encodedPayload;

            final Signature ecdsa = Signature.getInstance("SHA256withECDSA");
            ecdsa.initSign(keyPair.getPrivate());
            ecdsa.update(signingInput.getBytes(StandardCharsets.UTF_8));
            final byte[] derSignature = ecdsa.sign();

            final byte[] jwsSignature = derToJose(derSignature);
            final String encodedSignature = base64Url(jwsSignature);

            final String jws = signingInput + "." + encodedSignature;
            return String.format("%s;info=<%s>;alg=ES256;ppt=shaken", jws, CERT_URL);

        } catch (final Exception e) {
            logger.error("STIR/SHAKEN signing failed: {}", e.getMessage(), e);
            throw new RuntimeException("STIR/SHAKEN signature generation failed", e);
        }
    }

    /**
     * Verifies an incoming STIR/SHAKEN compact JWS signature.
     */
    public boolean verifyPassport(final String identityHeader) {
        if (identityHeader == null || identityHeader.isBlank()) {
            return false;
        }
        try {
            final String jws = identityHeader.split(";")[0].trim();
            final String[] parts = jws.split(Pattern.quote("."));
            if (parts.length != 3) {
                return false;
            }

            final String signingInput = parts[0] + "." + parts[1];
            final byte[] rawSig = Base64.getUrlDecoder().decode(parts[2]);
            final byte[] derSig = joseToDer(rawSig);

            final Signature ecdsa = Signature.getInstance("SHA256withECDSA");
            ecdsa.initVerify(keyPair.getPublic());
            ecdsa.update(signingInput.getBytes(StandardCharsets.UTF_8));
            return ecdsa.verify(derSig);

        } catch (final Exception e) {
            logger.warn("STIR/SHAKEN verification error: {}", e.getMessage());
            return false;
        }
    }

    private static String base64Url(final byte[] input) {
        return Base64.getUrlEncoder().withoutPadding().encodeToString(input);
    }

    /**
     * Converts standard DER-encoded ECDSA signature to fixed 64-byte JOSE format (R || S).
     */
    private static byte[] derToJose(final byte[] der) {
        if (der.length < 8 || der[0] != 0x30) {
            return der;
        }
        final byte[] jose = new byte[64];
        int rOffset = 4;
        int rLen = der[3];
        if (rLen == 33 && der[4] == 0) {
            rOffset++;
            rLen--;
        }
        System.arraycopy(der, rOffset, jose, 32 - rLen, rLen);

        int sLenOffset = rOffset + rLen + 1;
        int sLen = der[sLenOffset];
        int sOffset = sLenOffset + 1;
        if (sLen == 33 && der[sOffset] == 0) {
            sOffset++;
            sLen--;
        }
        System.arraycopy(der, sOffset, jose, 64 - sLen, sLen);
        return jose;
    }

    /**
     * Converts fixed 64-byte JOSE signature (R || S) to DER format for JRE Signature verifier.
     */
    private static byte[] joseToDer(final byte[] jose) {
        if (jose.length != 64) {
            return jose;
        }
        int rStart = 0;
        while (rStart < 32 && jose[rStart] == 0) rStart++;
        int rLen = 32 - rStart;
        boolean rPad = (jose[rStart] & 0x80) != 0;

        int sStart = 32;
        while (sStart < 64 && jose[sStart] == 0) sStart++;
        int sLen = 64 - sStart;
        boolean sPad = (jose[sStart] & 0x80) != 0;

        int totalLen = 2 + (rPad ? rLen + 1 : rLen) + 2 + (sPad ? sLen + 1 : sLen);
        byte[] der = new byte[2 + totalLen];
        der[0] = 0x30;
        der[1] = (byte) totalLen;

        int idx = 2;
        der[idx++] = 0x02;
        der[idx++] = (byte) (rPad ? rLen + 1 : rLen);
        if (rPad) der[idx++] = 0x00;
        System.arraycopy(jose, rStart, der, idx, rLen);
        idx += rLen;

        der[idx++] = 0x02;
        der[idx++] = (byte) (sPad ? sLen + 1 : sLen);
        if (sPad) der[idx++] = 0x00;
        System.arraycopy(jose, sStart, der, idx, sLen);

        return der;
    }
}
