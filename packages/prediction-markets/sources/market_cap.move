// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// MarketCap capability for authorized market packages.
module prediction_markets::market_cap;

const EInvalidPredict: u64 = 0;
const EInvalidOracle: u64 = 1;

const MARKET_TYPE_THRESHOLD: u8 = 0;
const MARKET_TYPE_CATEGORICAL: u8 = 1;

public struct MarketCap has key, store {
    id: UID,
    predict_id: ID,
    oracle_id: ID,
    market_type: u8,
    num_outcomes: u8,
}

public fun predict_id(cap: &MarketCap): ID { cap.predict_id }

public fun oracle_id(cap: &MarketCap): ID { cap.oracle_id }

public fun market_type(cap: &MarketCap): u8 { cap.market_type }

public fun num_outcomes(cap: &MarketCap): u8 { cap.num_outcomes }

public fun is_threshold(cap: &MarketCap): bool { cap.market_type == MARKET_TYPE_THRESHOLD }

public fun is_categorical(cap: &MarketCap): bool { cap.market_type == MARKET_TYPE_CATEGORICAL }

public(package) fun new_threshold(predict_id: ID, oracle_id: ID, ctx: &mut TxContext): MarketCap {
    MarketCap {
        id: object::new(ctx),
        predict_id,
        oracle_id,
        market_type: MARKET_TYPE_THRESHOLD,
        num_outcomes: 2,
    }
}

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

/// Validate that this cap authorizes operations on the given predict pool.
public(package) fun assert_predict_valid(cap: &MarketCap, predict_id: ID) {
    assert!(cap.predict_id == predict_id, EInvalidPredict);
}

/// Validate that this cap authorizes operations on the given predict pool and oracle.
public(package) fun assert_valid(cap: &MarketCap, predict_id: ID, oracle_id: ID) {
    assert!(cap.predict_id == predict_id, EInvalidPredict);
    assert!(cap.oracle_id == oracle_id, EInvalidOracle);
}

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
