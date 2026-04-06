// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Tests for oracle_price: settlement (at-expiry + touch), fair price delta,
/// staleness, activation, and edge cases.
#[test_only]
module prediction_markets::oracle_price_tests;

use prediction_markets::oracle_price;
use std::unit_test::destroy;
use sui::clock;

public struct BTC has drop {}

// =========================================================================
// Helpers
// =========================================================================

fun at_expiry_oracle(
    expiry: u64,
    threshold: u64,
    threshold_above: bool,
    ctx: &mut TxContext,
): (oracle_price::OraclePrice<BTC>, oracle_price::OracleCapPrice) {
    oracle_price::create_test_oracle_with_cap<BTC>(
        expiry,
        threshold,
        threshold_above,
        false, // not touch
        0,
        100_000_000, // max delta = 10%
        500_000_000, // fair = 50%
        100_000, // spot
        1000, // timestamp 1s
        ctx,
    )
}

fun touch_oracle(
    expiry: u64,
    threshold: u64,
    confirmations: u64,
    ctx: &mut TxContext,
): (oracle_price::OraclePrice<BTC>, oracle_price::OracleCapPrice) {
    oracle_price::create_test_oracle_with_cap<BTC>(
        expiry,
        threshold,
        true, // threshold_above
        true, // touch market
        confirmations,
        500_000_000, // max delta = 50% (lenient for tests)
        500_000_000,
        90_000, // spot below threshold
        1000,
        ctx,
    )
}

// =========================================================================
// Staleness
// =========================================================================

#[test]
fun not_stale_within_30s() {
    let ctx = &mut tx_context::dummy();
    let (oracle, cap) = at_expiry_oracle(60_000, 100_000, true, ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(31_000); // 30s since timestamp=1000
    assert!(!oracle.is_stale(&clock));
    clock.destroy_for_testing();
    destroy(oracle);
    destroy(cap);
}

#[test]
fun stale_after_30s() {
    let ctx = &mut tx_context::dummy();
    let (oracle, cap) = at_expiry_oracle(60_000, 100_000, true, ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(31_001);
    assert!(oracle.is_stale(&clock));
    clock.destroy_for_testing();
    destroy(oracle);
    destroy(cap);
}

#[test, expected_failure(abort_code = oracle_price::EOracleStale)]
fun assert_not_stale_fails() {
    let ctx = &mut tx_context::dummy();
    let (oracle, _cap) = at_expiry_oracle(60_000, 100_000, true, ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(40_000);
    oracle.assert_not_stale(&clock);
    abort
}

// =========================================================================
// At-Expiry Settlement via update_price
// =========================================================================

#[test]
fun at_expiry_settles_yes_above() {
    let ctx = &mut tx_context::dummy();
    let (mut oracle, cap) = at_expiry_oracle(10_000, 100_000, true, ctx);
    let mut clock = clock::create_for_testing(ctx);

    // Update before expiry: no settlement
    clock.set_for_testing(5_000);
    oracle.update_price(&cap, 110_000, 600_000_000, &clock);
    assert!(!oracle.is_settled());

    // Update after expiry: spot > threshold => YES
    clock.set_for_testing(11_000);
    oracle.update_price(&cap, 110_000, 600_000_000, &clock);
    assert!(oracle.is_settled());
    assert!(oracle.is_yes_winner());
    assert!(!oracle.is_active());

    clock.destroy_for_testing();
    destroy(oracle);
    destroy(cap);
}

#[test]
fun at_expiry_settles_no_below() {
    let ctx = &mut tx_context::dummy();
    let (mut oracle, cap) = at_expiry_oracle(10_000, 100_000, true, ctx);
    let mut clock = clock::create_for_testing(ctx);

    // After expiry: spot < threshold => NO
    clock.set_for_testing(11_000);
    oracle.update_price(&cap, 90_000, 400_000_000, &clock);
    assert!(oracle.is_settled());
    assert!(!oracle.is_yes_winner());

    clock.destroy_for_testing();
    destroy(oracle);
    destroy(cap);
}

#[test]
fun at_expiry_settles_yes_at_threshold() {
    let ctx = &mut tx_context::dummy();
    // threshold_above = true, spot == threshold => YES (>=)
    let (mut oracle, cap) = at_expiry_oracle(10_000, 100_000, true, ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(11_000);
    oracle.update_price(&cap, 100_000, 500_000_000, &clock);
    assert!(oracle.is_settled());
    assert!(oracle.is_yes_winner()); // spot >= threshold

    clock.destroy_for_testing();
    destroy(oracle);
    destroy(cap);
}

#[test]
fun at_expiry_threshold_below() {
    let ctx = &mut tx_context::dummy();
    // threshold_above = false => YES wins when spot <= threshold
    let (mut oracle, cap) = at_expiry_oracle(10_000, 100_000, false, ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(11_000);
    oracle.update_price(&cap, 90_000, 400_000_000, &clock);
    assert!(oracle.is_settled());
    assert!(oracle.is_yes_winner()); // 90k <= 100k

    clock.destroy_for_testing();
    destroy(oracle);
    destroy(cap);
}

// =========================================================================
// No Update Event After Settlement
// =========================================================================

#[test]
fun no_crash_on_update_after_settlement() {
    let ctx = &mut tx_context::dummy();
    let (mut oracle, cap) = at_expiry_oracle(10_000, 100_000, true, ctx);
    let mut clock = clock::create_for_testing(ctx);

    // Update before expiry: spot changes
    clock.set_for_testing(5_000);
    oracle.update_price(&cap, 110_000, 600_000_000, &clock);
    assert!(!oracle.is_settled());
    assert!(oracle.spot() == 110_000);

    // Settle at expiry
    clock.set_for_testing(11_000);
    oracle.update_price(&cap, 115_000, 600_000_000, &clock);
    assert!(oracle.is_settled());

    // Further updates after settlement should not crash
    clock.set_for_testing(12_000);
    oracle.update_price(&cap, 120_000, 600_000_000, &clock);
    // Oracle remains settled, spot frozen at pre-settlement value
    assert!(oracle.is_settled());
    assert!(oracle.is_yes_winner());

    clock.destroy_for_testing();
    destroy(oracle);
    destroy(cap);
}

// =========================================================================
// Fair Price Delta Validation
// =========================================================================

#[test, expected_failure(abort_code = oracle_price::EFairPriceDeltaExceeded)]
fun fair_price_delta_exceeded() {
    let ctx = &mut tx_context::dummy();
    // max_fair_price_delta = 10% = 100_000_000
    let (mut oracle, cap) = at_expiry_oracle(60_000, 100_000, true, ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(2_000);
    // Current fair = 500_000_000, new = 700_000_000, delta = 200M > 100M
    oracle.update_price(&cap, 100_000, 700_000_000, &clock);
    abort
}

#[test]
fun fair_price_delta_within_limit() {
    let ctx = &mut tx_context::dummy();
    let (mut oracle, cap) = at_expiry_oracle(60_000, 100_000, true, ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(2_000);
    // delta = 50M <= 100M max
    oracle.update_price(&cap, 100_000, 550_000_000, &clock);
    assert!(oracle.fair_price() == 550_000_000);

    clock.destroy_for_testing();
    destroy(oracle);
    destroy(cap);
}

#[test, expected_failure(abort_code = oracle_price::EInvalidFairPrice)]
fun fair_price_exceeds_one() {
    let ctx = &mut tx_context::dummy();
    let (mut oracle, cap) = at_expiry_oracle(60_000, 100_000, true, ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(2_000);
    // fair_price > FLOAT_SCALING
    oracle.update_price(&cap, 100_000, 1_100_000_000, &clock);
    abort
}

// =========================================================================
// Touch Settlement via update_price
// =========================================================================

#[test]
fun touch_settles_after_confirmations() {
    let ctx = &mut tx_context::dummy();
    // threshold = 100k, threshold_above = true, 2 confirmations needed
    let (mut oracle, cap) = touch_oracle(60_000, 100_000, 2, ctx);
    let mut clock = clock::create_for_testing(ctx);

    // Touch 1: cross threshold at t=6s (>= 1s + 5s debounce)
    clock.set_for_testing(6_000);
    oracle.update_price(&cap, 110_000, 600_000_000, &clock);
    assert!(!oracle.is_settled());

    // Touch 2: cross again at t=12s (>= 6s + 5s)
    clock.set_for_testing(12_000);
    oracle.update_price(&cap, 120_000, 700_000_000, &clock);
    assert!(oracle.is_settled());
    assert!(oracle.is_yes_winner());

    clock.destroy_for_testing();
    destroy(oracle);
    destroy(cap);
}

#[test]
fun touch_resets_on_uncross() {
    let ctx = &mut tx_context::dummy();
    let (mut oracle, cap) = touch_oracle(60_000, 100_000, 3, ctx);
    let mut clock = clock::create_for_testing(ctx);

    // Touch 1: cross
    clock.set_for_testing(6_000);
    oracle.update_price(&cap, 110_000, 600_000_000, &clock);
    assert!(!oracle.is_settled());

    // Uncross: price drops below threshold, count resets
    clock.set_for_testing(12_000);
    oracle.update_price(&cap, 90_000, 400_000_000, &clock);
    assert!(!oracle.is_settled());

    // Touch 1 again (from zero): cross
    clock.set_for_testing(18_000);
    oracle.update_price(&cap, 110_000, 600_000_000, &clock);
    assert!(!oracle.is_settled()); // Only 1 of 3

    clock.destroy_for_testing();
    destroy(oracle);
    destroy(cap);
}

#[test]
fun touch_debounce_prevents_rapid_touches() {
    let ctx = &mut tx_context::dummy();
    let (mut oracle, cap) = touch_oracle(60_000, 100_000, 2, ctx);
    let mut clock = clock::create_for_testing(ctx);

    // Touch 1 at t=6s
    clock.set_for_testing(6_000);
    oracle.update_price(&cap, 110_000, 600_000_000, &clock);
    assert!(!oracle.is_settled());

    // Rapid touch at t=7s (only 1s later, < 5s debounce) -- should NOT count
    clock.set_for_testing(7_000);
    oracle.update_price(&cap, 120_000, 650_000_000, &clock);
    assert!(!oracle.is_settled()); // Still only 1 touch

    // Touch 2 at t=12s (6s after last touch, >= 5s) -- should count
    clock.set_for_testing(12_000);
    oracle.update_price(&cap, 130_000, 700_000_000, &clock);
    assert!(oracle.is_settled());
    assert!(oracle.is_yes_winner());

    clock.destroy_for_testing();
    destroy(oracle);
    destroy(cap);
}

#[test]
fun touch_market_no_wins_on_expiry() {
    let ctx = &mut tx_context::dummy();
    // 3 confirmations needed, expires at 20s
    let (mut oracle, cap) = touch_oracle(20_000, 100_000, 3, ctx);
    let mut clock = clock::create_for_testing(ctx);

    // Only 1 touch before expiry
    clock.set_for_testing(6_000);
    oracle.update_price(&cap, 110_000, 600_000_000, &clock);
    assert!(!oracle.is_settled());

    // Expired with insufficient touches, price still above threshold
    clock.set_for_testing(21_000);
    oracle.update_price(&cap, 110_000, 600_000_000, &clock);
    assert!(oracle.is_settled());
    assert!(!oracle.is_yes_winner()); // NO wins

    clock.destroy_for_testing();
    destroy(oracle);
    destroy(cap);
}

// =========================================================================
// Cap Authorization
// =========================================================================

#[test, expected_failure(abort_code = oracle_price::EInvalidOracleCap)]
fun wrong_cap_rejected() {
    let ctx = &mut tx_context::dummy();
    let (mut oracle, _cap) = at_expiry_oracle(60_000, 100_000, true, ctx);
    let wrong_cap = oracle_price::create_oracle_cap(ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(2_000);
    oracle.update_price(&wrong_cap, 100_000, 500_000_000, &clock);
    abort
}
