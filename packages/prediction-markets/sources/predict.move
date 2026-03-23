// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// CTF-style collateral pool for prediction markets.
///
/// The pool holds USDC and is always 100% backed:
/// - Split: 1 USDC → 1 YES + 1 NO (paired minting)
/// - Merge: 1 YES + 1 NO → 1 USDC (paired burning)
/// - Settle: winner redeems for $1, loser for $0
///
/// Zero protocol risk. No spread pricing. No exposure tracking.
/// Price discovery happens on DeepBook pools, not here.
module prediction_markets::predict;

use prediction_markets::market_cap::MarketCap;
use sui::{balance::{Self, Balance}, coin::Coin, event};

// === Errors ===
const EPaused: u64 = 0;
const EInsufficientBalance: u64 = 1;

// === Events ===

public struct CollateralSplit has copy, drop, store {
    predict_id: ID,
    oracle_id: ID,
    amount: u64,
}

public struct CollateralMerged has copy, drop, store {
    predict_id: ID,
    oracle_id: ID,
    amount: u64,
}

public struct CollateralSettled has copy, drop, store {
    predict_id: ID,
    oracle_id: ID,
    amount: u64,
    is_winner: bool,
}

public struct PauseUpdated has copy, drop, store {
    predict_id: ID,
    paused: bool,
}

// === Structs ===

/// Collateral pool for prediction markets.
public struct Predict<phantom Quote> has key {
    id: UID,
    balance: Balance<Quote>,
    paused: bool,
}

// === Public Functions ===

/// Split collateral into outcome tokens.
public fun split_collateral<Quote>(
    predict: &mut Predict<Quote>,
    cap: &MarketCap,
    payment: Coin<Quote>,
): u64 {
    assert!(!predict.paused, EPaused);
    cap.assert_valid(object::id(predict), cap.oracle_id());

    let amount = payment.value();
    predict.balance.join(payment.into_balance());

    event::emit(CollateralSplit {
        predict_id: object::id(predict),
        oracle_id: cap.oracle_id(),
        amount,
    });

    amount
}

/// Merge outcome tokens back into collateral.
public fun merge_collateral<Quote>(
    predict: &mut Predict<Quote>,
    cap: &MarketCap,
    amount: u64,
): Balance<Quote> {
    cap.assert_valid(object::id(predict), cap.oracle_id());
    assert!(predict.balance.value() >= amount, EInsufficientBalance);

    event::emit(CollateralMerged {
        predict_id: object::id(predict),
        oracle_id: cap.oracle_id(),
        amount,
    });

    predict.balance.split(amount)
}

/// Settle a position after oracle resolution.
/// oracle_id must match the oracle this MarketCap was registered for.
public fun settle_collateral<Quote>(
    predict: &mut Predict<Quote>,
    cap: &MarketCap,
    oracle_id: ID,
    amount: u64,
    is_winner: bool,
): Balance<Quote> {
    cap.assert_valid(object::id(predict), oracle_id);

    event::emit(CollateralSettled {
        predict_id: object::id(predict),
        oracle_id,
        amount,
        is_winner,
    });

    if (is_winner) {
        assert!(predict.balance.value() >= amount, EInsufficientBalance);
        predict.balance.split(amount)
    } else {
        balance::zero()
    }
}

public fun balance<Quote>(predict: &Predict<Quote>): u64 {
    predict.balance.value()
}

// === Public-Package Functions ===

public(package) fun create<Quote>(ctx: &mut TxContext): ID {
    let predict = Predict<Quote> {
        id: object::new(ctx),
        balance: balance::zero(),
        paused: false,
    };
    let predict_id = object::id(&predict);
    transfer::share_object(predict);
    predict_id
}

public(package) fun deposit<Quote>(predict: &mut Predict<Quote>, coin: Coin<Quote>) {
    predict.balance.join(coin.into_balance());
}

public(package) fun set_paused<Quote>(predict: &mut Predict<Quote>, paused: bool) {
    predict.paused = paused;
    event::emit(PauseUpdated { predict_id: object::id(predict), paused });
}

// === Test Functions ===

#[test_only]
public(package) fun create_test_predict<Quote>(ctx: &mut TxContext): Predict<Quote> {
    Predict<Quote> { id: object::new(ctx), balance: balance::zero(), paused: false }
}

#[test_only]
public fun test_balance<Quote>(predict: &Predict<Quote>): u64 {
    predict.balance.value()
}
