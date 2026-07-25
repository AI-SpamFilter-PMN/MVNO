package com.mvno.intercept.subscriber;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.Mockito;
import org.springframework.dao.EmptyResultDataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;

class SubscriberRepositoryTest {

    private JdbcTemplate jdbcTemplate;
    private SubscriberRepository repository;

    @BeforeEach
    void setUp() {
        jdbcTemplate = Mockito.mock(JdbcTemplate.class);
        repository = new SubscriberRepository(jdbcTemplate);
    }

    @Test
    void testFindBalanceByMsisdn_Success() {
        Mockito.when(jdbcTemplate.queryForObject(anyString(), eq(Integer.class), eq("15551234567")))
                .thenReturn(100);

        int balance = repository.findBalanceByMsisdn("15551234567");
        assertEquals(100, balance);
    }

    @Test
    void testFindBalanceByMsisdn_MissingSubscriberReturnsZero() {
        Mockito.when(jdbcTemplate.queryForObject(anyString(), eq(Integer.class), eq("15550000000")))
                .thenThrow(new EmptyResultDataAccessException(1));

        int balance = repository.findBalanceByMsisdn("15550000000");
        assertEquals(0, balance);
    }

    @Test
    void testFindBalanceByMsisdn_NullOrBlankMsisdnReturnsZero() {
        assertEquals(0, repository.findBalanceByMsisdn(null));
        assertEquals(0, repository.findBalanceByMsisdn(""));
    }
}
