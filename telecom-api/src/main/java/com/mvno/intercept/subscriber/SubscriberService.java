package com.mvno.intercept.subscriber;

import org.springframework.stereotype.Service;

/**
 * Subscriber Domain Business Service
 * 
 * Orchestrates subscriber balance evaluation and Equipment Identity Register (EIR) tracking.
 * Uses constructor injection to guarantee immutable final field references and null-safety.
 * 
 * @author MVNO Core Engineering Team
 * @version 1.0.0
 */
@Service
public class SubscriberService {

    private final SubscriberRepository subscriberRepository;
    private final EirTracker eirTracker;

    public SubscriberService(final SubscriberRepository subscriberRepository, final EirTracker eirTracker) {
        this.subscriberRepository = subscriberRepository;
        this.eirTracker = eirTracker;
    }

    /**
     * Retrieves prepaid account balance for target phone number.
     * 
     * @param msisdn E.164 phone number string.
     * @return Account balance ($).
     */
    public int getBalance(final String msisdn) {
        return subscriberRepository.findBalanceByMsisdn(msisdn);
    }

    /**
     * Checks if target MSISDN belongs to a registered local subscriber in the HLR/SQLite DB.
     * 
     * @param msisdn E.164 phone number string.
     * @return true if registered local subscriber; false for external/inter-carrier numbers.
     */
    public boolean isLocalSubscriber(final String msisdn) {
        return subscriberRepository.findByMsisdn(msisdn).isPresent();
    }

    /**
     * Delegates hardware IMEI device verification to EIR tracker.
     * 
     * @param imei 15-digit IMEI serial number string.
     * @param msisdn Calling party E.164 phone number string.
     * @return true if normal; false if rapid SIM-swap anomaly detected.
     */
    public boolean checkEirBinding(final String imei, final String msisdn) {
        return eirTracker.checkEirBinding(imei, msisdn);
    }
}
