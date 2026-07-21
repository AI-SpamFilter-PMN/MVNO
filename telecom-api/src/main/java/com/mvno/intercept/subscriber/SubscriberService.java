package com.mvno.intercept.subscriber;

import org.springframework.stereotype.Service;

/**
 * Subscriber Domain Business Logic Service.
 * 
 * DESIGN PATTERN:
 * Orchestrates business policy enforcement between persistent subscriber account storage (`SubscriberRepository`)
 * and real-time equipment identity tracking (`EirTracker`).
 * 
 * CONSTRUCTOR INJECTION:
 * We use explicit constructor injection instead of `@Autowired` field injection.
 * Constructor injection guarantees immutable `final` field references, prevents NullPointerExceptions
 * during unit testing, and enforces compile-time dependency satisfaction.
 */
// `@Service` marks this business logic class as a Spring-managed service bean in the ApplicationContext.
@Service
public class SubscriberService {

    private final SubscriberRepository subscriberRepository;
    private final EirTracker eirTracker;

    /**
     * Constructs the SubscriberService with required domain components.
     * 
     * @param subscriberRepository Repository querying subscriber balances from SQLite WAL.
     * @param eirTracker Real-time Equipment Identity Register hardware IMEI tracker.
     */
    public SubscriberService(SubscriberRepository subscriberRepository, EirTracker eirTracker) {
        this.subscriberRepository = subscriberRepository;
        this.eirTracker = eirTracker;
    }

    /**
     * Delegates prepaid balance lookup to the database repository.
     * 
     * @param msisdn E.164 phone number string (e.g. "15551234567").
     * @return Prepaid account balance integer ($).
     */
    public int getBalance(String msisdn) {
        return subscriberRepository.findBalanceByMsisdn(msisdn);
    }

    /**
     * Delegates hardware IMEI device verification to the EIR tracker.
     * 
     * @param imei 15-digit International Mobile Equipment Identity string.
     * @param msisdn Calling party E.164 phone number.
     * @return True if device usage is normal; false if rapid SIM-swap anomaly is detected.
     */
    public boolean checkEirBinding(String imei, String msisdn) {
        return eirTracker.checkEirBinding(imei, msisdn);
    }
}
