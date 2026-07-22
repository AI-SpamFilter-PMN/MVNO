package com.mvno.intercept.subscriber;

import org.springframework.stereotype.Service;

/**
 * <h1>Subscriber Domain Business Service</h1>
 * 
 * <p>The {@code SubscriberService} orchestrates subscriber account balance evaluation and hardware
 * Equipment Identity Register (EIR) tracking operations.</p>
 * 
 * <h2>Constructor Dependency Injection</h2>
 * <p>Uses explicit constructor injection to guarantee immutable {@code final} field references,
 * prevent NullPointerExceptions during unit testing, and enforce compile-time dependency validation.</p>
 * 
 * @author MVNO Core Engineering Team
 * @version 1.0.0
 * @see com.mvno.intercept.subscriber.SubscriberRepository
 * @see com.mvno.intercept.subscriber.EirTracker
 */
@Service
public class SubscriberService {

    private final SubscriberRepository subscriberRepository;
    private final EirTracker eirTracker;

    /**
     * Constructs the Subscriber Service with required domain components.
     * 
     * @param subscriberRepository Repository querying subscriber balances from SQLite WAL database.
     * @param eirTracker Real-time Equipment Identity Register hardware IMEI tracker.
     */
    public SubscriberService(final SubscriberRepository subscriberRepository, final EirTracker eirTracker) {
        this.subscriberRepository = subscriberRepository;
        this.eirTracker = eirTracker;
    }

    /**
     * Retrieves the prepaid account balance for a target subscriber phone number.
     * 
     * @param msisdn E.164 phone number string (e.g. "15551234567").
     * @return Account balance integer ($).
     */
    public int getBalance(final String msisdn) {
        return subscriberRepository.findBalanceByMsisdn(msisdn);
    }

    /**
     * Delegates hardware IMEI device verification to the EIR tracker.
     * 
     * @param imei 15-digit International Mobile Equipment Identity hardware serial number string.
     * @param msisdn Calling party E.164 phone number string.
     * @return {@code true} if device binding is normal; {@code false} if rapid SIM-swap anomaly is detected.
     */
    public boolean checkEirBinding(final String imei, final String msisdn) {
        return eirTracker.checkEirBinding(imei, msisdn);
    }
}
