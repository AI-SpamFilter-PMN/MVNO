package com.mvno.intercept.subscriber;

import org.springframework.stereotype.Service;

/**
 * ==============================================================================
 * Subscriber Business Logic Service
 * ==============================================================================
 * Handles prepaid OCS (Online Charging System) balance verification, EIR SIM-swap
 * checks, and blacklist validation before authorizing SMS and Voice Call transactions.
 */
@Service
public class SubscriberService {

    private final SubscriberRepository subscriberRepository;
    private final EirTracker eirTracker;

    public SubscriberService(SubscriberRepository subscriberRepository, EirTracker eirTracker) {
        this.subscriberRepository = subscriberRepository;
        this.eirTracker = eirTracker;
    }

    /**
     * Gets prepaid balance for a given MSISDN.
     */
    public int getBalance(String msisdn) {
        return subscriberRepository.findBalanceByMsisdn(msisdn);
    }

    /**
     * Checks EIR device binding to prevent SIM-swap fraud.
     */
    public boolean checkEirBinding(String imei, String msisdn) {
        return eirTracker.checkEirBinding(imei, msisdn);
    }
}
