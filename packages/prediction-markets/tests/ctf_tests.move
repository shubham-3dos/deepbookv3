// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Comprehensive tests for the CTF prediction market.
/// Tests: split, merge, settle, solvency, pause, oracle validation, edge cases.
#[test_only]
module prediction_markets::ctf_tests;

use prediction_markets::{market_cap, predict::{Self, Predict}};
use std::unit_test::{assert_eq, destroy};
use sui::coin;

public struct USDC has drop {}

macro fun usdc($amount: u64): u64 { $amount * 1_000_000 }

fun setup(ctx: &mut TxContext): (Predict<USDC>, market_cap::MarketCap, ID) {
    let predict = predict::create_test_predict<USDC>(ctx);
    let oracle_id = object::id_from_address(@0xAA);
    let cap = market_cap::create_test_market_cap_threshold(object::id(&predict), oracle_id, ctx);
    (predict, cap, oracle_id)
}

// =========================================================================
// Split
// =========================================================================

#[test]
fun split_deposits_exact_amount() {
    let ctx = &mut tx_context::dummy();
    let (mut predict, cap, _) = setup(ctx);

    let amount = predict.split_collateral(&cap, coin::mint_for_testing<USDC>(usdc!(100), ctx));
    assert_eq!(amount, usdc!(100));
    assert_eq!(predict.test_balance(), usdc!(100));

    destroy(predict); destroy(cap);
}

#[test]
fun multiple_splits_accumulate() {
    let ctx = &mut tx_context::dummy();
    let (mut predict, cap, _) = setup(ctx);

    predict.split_collateral(&cap, coin::mint_for_testing<USDC>(usdc!(100), ctx));
    predict.split_collateral(&cap, coin::mint_for_testing<USDC>(usdc!(200), ctx));
    predict.split_collateral(&cap, coin::mint_for_testing<USDC>(usdc!(50), ctx));
    assert_eq!(predict.test_balance(), usdc!(350));

    destroy(predict); destroy(cap);
}

#[test, expected_failure(abort_code = predict::EPaused)]
fun split_fails_when_paused() {
    let ctx = &mut tx_context::dummy();
    let (mut predict, cap, _) = setup(ctx);
    predict.set_paused(true);
    predict.split_collateral(&cap, coin::mint_for_testing<USDC>(usdc!(100), ctx));
    abort
}

// =========================================================================
// Merge
// =========================================================================

#[test]
fun merge_withdraws_exact_amount() {
    let ctx = &mut tx_context::dummy();
    let (mut predict, cap, _) = setup(ctx);

    predict.split_collateral(&cap, coin::mint_for_testing<USDC>(usdc!(100), ctx));
    let payout = predict.merge_collateral(&cap, usdc!(100));
    assert_eq!(payout.value(), usdc!(100));
    assert_eq!(predict.test_balance(), 0);

    payout.destroy_for_testing(); destroy(predict); destroy(cap);
}

#[test]
fun merge_works_when_paused() {
    let ctx = &mut tx_context::dummy();
    let (mut predict, cap, _) = setup(ctx);
    predict.split_collateral(&cap, coin::mint_for_testing<USDC>(usdc!(100), ctx));
    predict.set_paused(true);
    let payout = predict.merge_collateral(&cap, usdc!(100));
    assert_eq!(payout.value(), usdc!(100));
    payout.destroy_for_testing(); destroy(predict); destroy(cap);
}

#[test, expected_failure(abort_code = predict::EInsufficientBalance)]
fun merge_fails_insufficient_balance() {
    let ctx = &mut tx_context::dummy();
    let (mut predict, cap, _) = setup(ctx);
    predict.split_collateral(&cap, coin::mint_for_testing<USDC>(usdc!(50), ctx));
    let _b = predict.merge_collateral(&cap, usdc!(100));
    abort
}

// =========================================================================
// Settle
// =========================================================================

#[test]
fun settle_winner_gets_full_amount() {
    let ctx = &mut tx_context::dummy();
    let (mut predict, cap, oracle_id) = setup(ctx);
    predict.split_collateral(&cap, coin::mint_for_testing<USDC>(usdc!(100), ctx));

    let payout = predict.settle_collateral(&cap, oracle_id, usdc!(100), true);
    assert_eq!(payout.value(), usdc!(100));
    assert_eq!(predict.test_balance(), 0);

    payout.destroy_for_testing(); destroy(predict); destroy(cap);
}

#[test]
fun settle_loser_gets_zero() {
    let ctx = &mut tx_context::dummy();
    let (mut predict, cap, oracle_id) = setup(ctx);
    predict.split_collateral(&cap, coin::mint_for_testing<USDC>(usdc!(100), ctx));

    let payout = predict.settle_collateral(&cap, oracle_id, usdc!(100), false);
    assert_eq!(payout.value(), 0);
    assert_eq!(predict.test_balance(), usdc!(100));

    payout.destroy_for_testing(); destroy(predict); destroy(cap);
}

#[test]
fun settle_works_when_paused() {
    let ctx = &mut tx_context::dummy();
    let (mut predict, cap, oracle_id) = setup(ctx);
    predict.split_collateral(&cap, coin::mint_for_testing<USDC>(usdc!(100), ctx));
    predict.set_paused(true);
    let payout = predict.settle_collateral(&cap, oracle_id, usdc!(100), true);
    assert_eq!(payout.value(), usdc!(100));
    payout.destroy_for_testing(); destroy(predict); destroy(cap);
}

// =========================================================================
// Oracle ID Validation (security fix)
// =========================================================================

#[test, expected_failure(abort_code = market_cap::EInvalidOracle)]
fun settle_wrong_oracle_rejected() {
    let ctx = &mut tx_context::dummy();
    let (mut predict, cap, _) = setup(ctx);
    let wrong_oracle = object::id_from_address(@0xBB);
    predict.split_collateral(&cap, coin::mint_for_testing<USDC>(usdc!(100), ctx));
    let _p = predict.settle_collateral(&cap, wrong_oracle, usdc!(100), true);
    abort
}

#[test, expected_failure(abort_code = market_cap::EInvalidPredict)]
fun settle_wrong_predict_rejected() {
    let ctx = &mut tx_context::dummy();
    let (mut predict, cap, oracle_id) = setup(ctx);
    // Cap for a different predict object
    let wrong_cap = market_cap::create_test_market_cap_threshold(
        object::id_from_address(@0xCC), oracle_id, ctx,
    );
    predict.split_collateral(&cap, coin::mint_for_testing<USDC>(usdc!(100), ctx));
    // Settle with wrong cap — should fail
    let _p = predict.settle_collateral(&wrong_cap, oracle_id, usdc!(100), true);
    abort
}

// =========================================================================
// Solvency Invariants
// =========================================================================

#[test]
fun solvency_after_split_merge_settle_cycle() {
    let ctx = &mut tx_context::dummy();
    let (mut predict, cap, oracle_id) = setup(ctx);

    predict.split_collateral(&cap, coin::mint_for_testing<USDC>(usdc!(100), ctx));
    let p1 = predict.merge_collateral(&cap, usdc!(60));
    assert_eq!(predict.test_balance(), usdc!(40));

    predict.split_collateral(&cap, coin::mint_for_testing<USDC>(usdc!(200), ctx));
    assert_eq!(predict.test_balance(), usdc!(240));

    let p2 = predict.settle_collateral(&cap, oracle_id, usdc!(40), true);
    assert_eq!(predict.test_balance(), usdc!(200));

    let p3 = predict.settle_collateral(&cap, oracle_id, usdc!(100), false);
    assert_eq!(predict.test_balance(), usdc!(200));

    let p4 = predict.merge_collateral(&cap, usdc!(200));
    assert_eq!(predict.test_balance(), 0);

    p1.destroy_for_testing(); p2.destroy_for_testing();
    p3.destroy_for_testing(); p4.destroy_for_testing();
    destroy(predict); destroy(cap);
}

#[test]
fun many_splits_then_full_settlement() {
    let ctx = &mut tx_context::dummy();
    let (mut predict, cap, oracle_id) = setup(ctx);

    let mut i = 0;
    while (i < 10) {
        predict.split_collateral(&cap, coin::mint_for_testing<USDC>(usdc!(100), ctx));
        i = i + 1;
    };
    assert_eq!(predict.test_balance(), usdc!(1000));

    i = 0;
    while (i < 10) {
        let p = predict.settle_collateral(&cap, oracle_id, usdc!(100), true);
        assert_eq!(p.value(), usdc!(100));
        p.destroy_for_testing();
        i = i + 1;
    };
    assert_eq!(predict.test_balance(), 0);

    destroy(predict); destroy(cap);
}

#[test]
fun mixed_winners_and_losers() {
    let ctx = &mut tx_context::dummy();
    let (mut predict, cap, oracle_id) = setup(ctx);

    // 5 splits of 100 USDC each = 500 total
    let mut i = 0;
    while (i < 5) {
        predict.split_collateral(&cap, coin::mint_for_testing<USDC>(usdc!(100), ctx));
        i = i + 1;
    };
    assert_eq!(predict.test_balance(), usdc!(500));

    // 3 winners claim 100 each = 300 out
    i = 0;
    while (i < 3) {
        let p = predict.settle_collateral(&cap, oracle_id, usdc!(100), true);
        p.destroy_for_testing();
        i = i + 1;
    };
    assert_eq!(predict.test_balance(), usdc!(200));

    // 2 losers claim 0 each
    i = 0;
    while (i < 2) {
        let p = predict.settle_collateral(&cap, oracle_id, usdc!(100), false);
        assert_eq!(p.value(), 0);
        p.destroy_for_testing();
        i = i + 1;
    };
    // 200 USDC remains (loser collateral retained in pool)
    assert_eq!(predict.test_balance(), usdc!(200));

    destroy(predict); destroy(cap);
}
