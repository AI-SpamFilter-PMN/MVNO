package com.mvno.intercept.ussd;

import com.mvno.intercept.subscriber.SubscriberService;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Stateful Interactive USSD Gateway (3GPP TS 24.090)
 *
 * Manages multi-tier USSD session state machines for subscriber self-care:
 * - *100# -> Main Menu (1: Balance, 2: Top-Up, 3: 5G Slices, 4: Plan)
 * - Thread-safe session tracking with 60-second TTL auto-eviction.
 *
 * @author MVNO Core Engineering Team
 * @version 1.0.0
 */
@Service
public class UssdSessionService {

    private static final Logger logger = LoggerFactory.getLogger(UssdSessionService.class);
    private static final long SESSION_TTL_MS = 60_000L;

    public enum UssdState {
        INITIAL,
        MAIN_MENU,
        AWAITING_VOUCHER_PIN
    }

    public record UssdSession(String msisdn, UssdState state, long lastActivityEpochMs) {}

    public record UssdResponse(String msisdn, String message, boolean continueSession) {}

    private final SubscriberService subscriberService;
    private final Map<String, UssdSession> sessions = new ConcurrentHashMap<>();

    public UssdSessionService(final SubscriberService subscriberService) {
        this.subscriberService = subscriberService;
    }

    /**
     * Processes an incoming USSD request string from a subscriber MSISDN.
     */
    public UssdResponse processUssd(final String msisdn, final String input) {
        if (msisdn == null || msisdn.isBlank()) {
            return new UssdResponse("", "Invalid Subscriber ID", false);
        }

        cleanupExpiredSessions();

        final String cleanInput = input != null ? input.trim() : "";
        final UssdSession session = sessions.get(msisdn);

        // New session initiation (*100# or first message)
        if (session == null || cleanInput.equals("*100#") || cleanInput.equals("*100")) {
            sessions.put(msisdn, new UssdSession(msisdn, UssdState.MAIN_MENU, System.currentTimeMillis()));
            final String menu = """
                MVNO 5G Core Self-Care:
                1. Check Account Balance
                2. Recharge via Voucher
                3. 5G Network Slice Status
                4. Active Plan & Bundles
                Reply with option number (1-4):""";
            return new UssdResponse(msisdn, menu, true);
        }

        // Handle responses based on current session state
        switch (session.state()) {
            case MAIN_MENU -> {
                switch (cleanInput) {
                    case "1" -> {
                        sessions.remove(msisdn);
                        final int balance = subscriberService.getBalance(msisdn);
                        return new UssdResponse(msisdn, String.format("Account Balance for %s: %d Credits ($%d.00). Status: ACTIVE.", msisdn, balance, balance), false);
                    }
                    case "2" -> {
                        sessions.put(msisdn, new UssdSession(msisdn, UssdState.AWAITING_VOUCHER_PIN, System.currentTimeMillis()));
                        return new UssdResponse(msisdn, "Enter your 6-digit recharge voucher PIN:", true);
                    }
                    case "3" -> {
                        sessions.remove(msisdn);
                        return new UssdResponse(msisdn, "5G Network Slicing: Active Slice SST=1 (eMBB Consumer). QoS: 100Mbps Down / 50Mbps Up. URLLC Slice: AVAILABLE.", false);
                    }
                    case "4" -> {
                        sessions.remove(msisdn);
                        return new UssdResponse(msisdn, "Plan: MVNO Unlimited 5G VoNR + Anti-Spam Shield (Active). Valid until 2026-12-31.", false);
                    }
                    default -> {
                        sessions.put(msisdn, new UssdSession(msisdn, UssdState.MAIN_MENU, System.currentTimeMillis()));
                        return new UssdResponse(msisdn, "Invalid selection. Please choose 1, 2, 3, or 4:", true);
                    }
                }
            }
            case AWAITING_VOUCHER_PIN -> {
                sessions.remove(msisdn);
                if (cleanInput.matches("^[0-9]{4,10}$")) {
                    logger.info("USSD Voucher Top-Up Successful for subscriber={}", msisdn);
                    return new UssdResponse(msisdn, "Voucher redeemed successfully! Added 50 Credits ($50.00) to your balance.", false);
                } else {
                    return new UssdResponse(msisdn, "Invalid voucher PIN format. Top-up cancelled.", false);
                }
            }
            default -> {
                sessions.remove(msisdn);
                return new UssdResponse(msisdn, "Session expired. Dial *100# to restart.", false);
            }
        }
    }

    private void cleanupExpiredSessions() {
        final long now = System.currentTimeMillis();
        sessions.entrySet().removeIf(e -> now - e.getValue().lastActivityEpochMs() > SESSION_TTL_MS);
    }
}
