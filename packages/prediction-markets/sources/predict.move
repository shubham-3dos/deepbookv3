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

const EPaused: u64 = 0;
const EInsufficientBalance: u64 = 1;
const EZeroAmount: u64 = 2;

/// Emitted when collateral is split into a paired set of outcome tokens.
public struct CollateralSplit has copy, drop, store {
    predict_id: ID,
    oracle_id: ID,
    amount: u64,
}

/// Emitted when a paired set of outcome tokens is merged back into collateral.
public struct CollateralMerged has copy, drop, store {
    predict_id: ID,
    oracle_id: ID,
    amount: u64,
}

/// Emitted when an outcome position is settled. `is_winner` distinguishes the
/// winning-outcome payout (1:1 against collateral) from the losing-outcome
/// no-op (zero balance returned).
public struct CollateralSettled has copy, drop, store {
    predict_id: ID,
    oracle_id: ID,
    amount: u64,
    is_winner: bool,
}

/// Emitted whenever the pool's pause flag changes.
public struct PauseUpdated has copy, drop, store {
    predict_id: ID,
    paused: bool,
}

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
    cap.assert_predict_id(object::id(predict));

    let amount = payment.value();
    assert!(amount > 0, EZeroAmount);
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
    cap.assert_predict_id(object::id(predict));
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
    cap.assert_predict_and_oracle_id(object::id(predict), oracle_id);

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

/// Total collateral currently held by the pool.
public fun balance<Quote>(predict: &Predict<Quote>): u64 {
    predict.balance.value()
}

// === Public-Package Functions ===

/// Create and share a new collateral pool. Returns the new Predict pool's ID.
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

/// Admin-only deposit: add collateral without minting outcome tokens.
/// Intended for subsidy/seeding; does not mint YES/NO/outcome positions.
public(package) fun deposit<Quote>(predict: &mut Predict<Quote>, coin: Coin<Quote>) {
    predict.balance.join(coin.into_balance());
}

/// Admin-only flip of the `paused` flag. Pausing blocks new splits but does
/// not block merge or settle (those reduce risk; pause only blocks new risk).
public(package) fun set_paused<Quote>(predict: &mut Predict<Quote>, paused: bool) {
    predict.paused = paused;
    event::emit(PauseUpdated { predict_id: object::id(predict), paused });
}

// === Test-Only Functions ===

#[test_only]
public(package) fun create_test_predict<Quote>(ctx: &mut TxContext): Predict<Quote> {
    Predict<Quote> { id: object::new(ctx), balance: balance::zero(), paused: false }
}

#[test_only]
public fun test_balance<Quote>(predict: &Predict<Quote>): u64 {
    predict.balance.value()
}
