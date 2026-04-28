// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Tests for oracle_categorical: activation, price updates, resolution,
/// fair price sum validation, expiry enforcement, and edge cases.
#[test_only]
module prediction_markets::oracle_categorical_tests;

use prediction_markets::oracle_categorical;
use std::unit_test::destroy;
use sui::clock;

// =========================================================================
// Helpers
// =========================================================================

fun four_outcome_oracle(
    expiry: u64,
    ctx: &mut TxContext,
): (oracle_categorical::OracleCategorical, oracle_categorical::OracleCapCategorical) {
    oracle_categorical::create_test_oracle_with_cap(
        expiry,
        4,
        vector[250_000_000, 250_000_000, 250_000_000, 250_000_000], // 25% each
        1000, // timestamp_ms
        ctx,
    )
}

// =========================================================================
// Initial State
// =========================================================================

#[test]
fun initial_state_correct() {
    let ctx = &mut tx_context::dummy();
    let (oracle, cap) = four_outcome_oracle(60_000, ctx);

    assert!(oracle.expiry() == 60_000);
    assert!(oracle.num_outcomes() == 4);
    assert!(oracle.is_active());
    assert!(!oracle.is_resolved());
    assert!(oracle.fair_price(0) == 250_000_000);
    assert!(oracle.fair_price(3) == 250_000_000);

    destroy(oracle);
    destroy(cap);
}

// =========================================================================
// Price Updates
// =========================================================================

#[test]
fun update_prices_valid() {
    let ctx = &mut tx_context::dummy();
    let (mut oracle, cap) = four_outcome_oracle(60_000, ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(5_000);

    // Sum = 1.0 exactly
    oracle.update_prices(&cap, vector[400_000_000, 300_000_000, 200_000_000, 100_000_000], &clock);
    assert!(oracle.fair_price(0) == 400_000_000);
    assert!(oracle.fair_price(1) == 300_000_000);
    assert!(oracle.fair_price(2) == 200_000_000);
    assert!(oracle.fair_price(3) == 100_000_000);

    clock.destroy_for_testing();
    destroy(oracle);
    destroy(cap);
}

#[test]
fun update_prices_within_tolerance() {
    let ctx = &mut tx_context::dummy();
    let (mut oracle, cap) = four_outcome_oracle(60_000, ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(5_000);

    // Sum = 1.019 (within 2% tolerance)
    oracle.update_prices(&cap, vector[400_000_000, 300_000_000, 200_000_000, 119_000_000], &clock);
    assert!(oracle.fair_price(3) == 119_000_000);

    clock.destroy_for_testing();
    destroy(oracle);
    destroy(cap);
}

#[test, expected_failure(abort_code = oracle_categorical::EPricesSumInvalid)]
fun update_prices_sum_too_high() {
    let ctx = &mut tx_context::dummy();
    let (mut oracle, cap) = four_outcome_oracle(60_000, ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(5_000);

    // Sum = 1.05 (> 1.02 tolerance)
    oracle.update_prices(&cap, vector[400_000_000, 300_000_000, 200_000_000, 150_000_000], &clock);
    abort
}

#[test, expected_failure(abort_code = oracle_categorical::EPricesSumInvalid)]
fun update_prices_sum_too_low() {
    let ctx = &mut tx_context::dummy();
    let (mut oracle, cap) = four_outcome_oracle(60_000, ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(5_000);

    // Sum = 0.95 (< 0.98 tolerance)
    oracle.update_prices(&cap, vector[400_000_000, 300_000_000, 200_000_000, 50_000_000], &clock);
    abort
}

#[test, expected_failure(abort_code = oracle_categorical::EInvalidFairPrices)]
fun update_prices_wrong_count() {
    let ctx = &mut tx_context::dummy();
    let (mut oracle, cap) = four_outcome_oracle(60_000, ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(5_000);

    // 3 prices for 4-outcome oracle
    oracle.update_prices(&cap, vector[400_000_000, 300_000_000, 300_000_000], &clock);
    abort
}

#[test, expected_failure(abort_code = oracle_categorical::EOracleExpired)]
fun update_prices_after_expiry() {
    let ctx = &mut tx_context::dummy();
    let (mut oracle, cap) = four_outcome_oracle(10_000, ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(11_000);

    oracle.update_prices(&cap, vector[250_000_000, 250_000_000, 250_000_000, 250_000_000], &clock);
    abort
}

// =========================================================================
// Resolution
// =========================================================================

#[test]
fun resolve_after_expiry() {
    let ctx = &mut tx_context::dummy();
    let (mut oracle, cap) = four_outcome_oracle(10_000, ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(11_000);

    oracle.resolve(&cap, 2, &clock);
    assert!(oracle.is_resolved());
    assert!(oracle.winning_outcome().destroy_some() == 2);
    assert!(!oracle.is_active());

    clock.destroy_for_testing();
    destroy(oracle);
    destroy(cap);
}

#[test, expected_failure(abort_code = oracle_categorical::EOracleNotExpired)]
fun resolve_before_expiry_fails() {
    let ctx = &mut tx_context::dummy();
    let (mut oracle, cap) = four_outcome_oracle(60_000, ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(5_000);

    oracle.resolve(&cap, 0, &clock);
    abort
}

#[test, expected_failure(abort_code = oracle_categorical::EAlreadyResolved)]
fun resolve_twice_fails() {
    let ctx = &mut tx_context::dummy();
    let (mut oracle, cap) = four_outcome_oracle(10_000, ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(11_000);

    oracle.resolve(&cap, 1, &clock);
    oracle.resolve(&cap, 2, &clock); // should fail
    abort
}

#[test, expected_failure(abort_code = oracle_categorical::EInvalidOutcome)]
fun resolve_invalid_outcome_fails() {
    let ctx = &mut tx_context::dummy();
    let (mut oracle, cap) = four_outcome_oracle(10_000, ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(11_000);

    oracle.resolve(&cap, 4, &clock); // 4 >= num_outcomes (4)
    abort
}

#[test, expected_failure(abort_code = oracle_categorical::EAlreadyResolved)]
fun update_prices_after_resolve_fails() {
    let ctx = &mut tx_context::dummy();
    // expiry = 10s, resolve after expiry, then try update
    let (mut oracle, cap) = four_outcome_oracle(10_000, ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(11_000);

    oracle.resolve(&cap, 0, &clock);

    // Try updating prices after resolution -- but expiry check happens first
    // Since clock > expiry, it would fail with EOracleExpired, not EAlreadyResolved
    // Let's use a fresh oracle to test this more precisely
    clock.destroy_for_testing();
    destroy(oracle);
    destroy(cap);

    let ctx2 = &mut tx_context::dummy();
    let (mut oracle2, cap2) = four_outcome_oracle(60_000, ctx2);
    let mut clock2 = clock::create_for_testing(ctx2);
    clock2.set_for_testing(5_000);

    // Resolve via test helper (bypasses expiry check)
    oracle_categorical::resolve_test_oracle(&mut oracle2, 0);

    // Now update_prices should fail with EAlreadyResolved
    oracle2.update_prices(
        &cap2,
        vector[250_000_000, 250_000_000, 250_000_000, 250_000_000],
        &clock2,
    );
    abort
}

// =========================================================================
// Staleness
// =========================================================================

#[test]
fun staleness_check() {
    let ctx = &mut tx_context::dummy();
    let (oracle, cap) = four_outcome_oracle(60_000, ctx);
    let mut clock = clock::create_for_testing(ctx);

    clock.set_for_testing(31_000); // 30s since t=1000
    assert!(!oracle.is_stale(&clock));

    clock.set_for_testing(31_001);
    assert!(oracle.is_stale(&clock));

    clock.destroy_for_testing();
    destroy(oracle);
    destroy(cap);
}

// =========================================================================
// Cap Authorization
// =========================================================================

#[test, expected_failure(abort_code = oracle_categorical::EInvalidOracleCap)]
fun wrong_cap_rejected() {
    let ctx = &mut tx_context::dummy();
    let (mut oracle, _cap) = four_outcome_oracle(60_000, ctx);
    let wrong_cap = oracle_categorical::create_oracle_cap(ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(5_000);

    oracle.update_prices(
        &wrong_cap,
        vector[250_000_000, 250_000_000, 250_000_000, 250_000_000],
        &clock,
    );
    abort
}

// =========================================================================
// num_outcomes Validation
// =========================================================================

#[test, expected_failure(abort_code = oracle_categorical::EInvalidNumOutcomes)]
fun create_oracle_zero_outcomes() {
    let ctx = &mut tx_context::dummy();
    let cap = oracle_categorical::create_oracle_cap(ctx);
    oracle_categorical::create_oracle(&cap, 60_000, 0, ctx);
    abort
}

#[test, expected_failure(abort_code = oracle_categorical::EInvalidNumOutcomes)]
fun create_oracle_one_outcome() {
    let ctx = &mut tx_context::dummy();
    let cap = oracle_categorical::create_oracle_cap(ctx);
    oracle_categorical::create_oracle(&cap, 60_000, 1, ctx);
    abort
}
