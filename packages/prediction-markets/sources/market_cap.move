// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Capability granting authority to operate on a Predict pool's collateral.
///
/// A `MarketCap` binds three things: the Predict pool ID, the oracle ID, and
/// a market type (threshold or categorical). It is created by the registry
/// when a market is registered and held inside the calling market's shared
/// `MarketState`. Because the cap is never extracted from the state, the
/// authorization survives package upgrades.
module prediction_markets::market_cap;

const EInvalidPredict: u64 = 0;
const EInvalidOracle: u64 = 1;

// Two-outcome (YES/NO) threshold market.
const MARKET_TYPE_THRESHOLD: u8 = 0;
// N-outcome (2 <= N <= 255) categorical market.
const MARKET_TYPE_CATEGORICAL: u8 = 1;

/// Authorization capability bound to a single (Predict, oracle, market type)
/// triple. Held inside the calling market's shared state.
public struct MarketCap has key, store {
    id: UID,
    predict_id: ID,
    oracle_id: ID,
    market_type: u8,
    num_outcomes: u8,
}

// === Public Functions ===

/// Predict pool ID this cap is bound to.
public fun predict_id(cap: &MarketCap): ID { cap.predict_id }

/// Oracle ID this cap is bound to.
public fun oracle_id(cap: &MarketCap): ID { cap.oracle_id }

/// Market-type tag (`MARKET_TYPE_THRESHOLD` or `MARKET_TYPE_CATEGORICAL`).
public fun market_type(cap: &MarketCap): u8 { cap.market_type }

/// Number of outcomes for this market (always 2 for threshold; 2..=255 otherwise).
public fun num_outcomes(cap: &MarketCap): u8 { cap.num_outcomes }

/// True if this cap authorizes a threshold market.
public fun is_threshold(cap: &MarketCap): bool { cap.market_type == MARKET_TYPE_THRESHOLD }

/// True if this cap authorizes a categorical market.
public fun is_categorical(cap: &MarketCap): bool { cap.market_type == MARKET_TYPE_CATEGORICAL }

// === Public-Package Functions ===

/// Mint a fresh threshold-market cap (always 2 outcomes).
public(package) fun new_threshold(predict_id: ID, oracle_id: ID, ctx: &mut TxContext): MarketCap {
    MarketCap {
        id: object::new(ctx),
        predict_id,
        oracle_id,
        market_type: MARKET_TYPE_THRESHOLD,
        num_outcomes: 2,
    }
}

/// Mint a fresh categorical-market cap with the given outcome count.
public(package) fun new_categorical(
    predict_id: ID,
    oracle_id: ID,
    num_outcomes: u8,
    ctx: &mut TxContext,
): MarketCap {
    MarketCap {
        id: object::new(ctx),
        predict_id,
        oracle_id,
        market_type: MARKET_TYPE_CATEGORICAL,
        num_outcomes,
    }
}

/// Abort unless this cap authorizes operations on the given Predict pool.
public(package) fun assert_predict_id(cap: &MarketCap, predict_id: ID) {
    assert!(cap.predict_id == predict_id, EInvalidPredict);
}

/// Abort unless this cap authorizes operations on the given Predict pool
/// AND the given oracle. Used by settlement, which must verify both.
public(package) fun assert_predict_and_oracle_id(cap: &MarketCap, predict_id: ID, oracle_id: ID) {
    assert!(cap.predict_id == predict_id, EInvalidPredict);
    assert!(cap.oracle_id == oracle_id, EInvalidOracle);
}

// === Test-Only Functions ===

#[test_only]
public fun create_test_market_cap_threshold(
    predict_id: ID,
    oracle_id: ID,
    ctx: &mut TxContext,
): MarketCap {
    new_threshold(predict_id, oracle_id, ctx)
}

#[test_only]
public fun create_test_market_cap_categorical(
    predict_id: ID,
    oracle_id: ID,
    num_outcomes: u8,
    ctx: &mut TxContext,
): MarketCap {
    new_categorical(predict_id, oracle_id, num_outcomes, ctx)
}
