// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Registry for CTF prediction markets.
/// Manages AdminCap, collateral pool, oracle creation, and market registration.
module prediction_markets::registry;

use prediction_markets::{
    market_cap,
    oracle_categorical::{Self, OracleCapCategorical},
    oracle_price::{Self, OracleCapPrice},
    predict
};
use sui::{coin::Coin, event};

const EPredictAlreadyCreated: u64 = 0;

/// Emitted once when the registry's collateral pool is created.
public struct PredictCreated has copy, drop, store { predict_id: ID }

/// Emitted when a new threshold price oracle is registered.
public struct PriceOracleCreated has copy, drop, store {
    oracle_id: ID,
    oracle_cap_id: ID,
    expiry: u64,
    threshold: u64,
    threshold_above: bool,
    is_touch_market: bool,
}

/// Emitted when a new categorical oracle is registered.
public struct CategoricalOracleCreated has copy, drop, store {
    oracle_id: ID,
    oracle_cap_id: ID,
    expiry: u64,
    num_outcomes: u8,
}

/// Admin capability minted at module init; gates registry-level operations.
public struct AdminCap has key, store { id: UID }

/// Singleton registry binding the prediction-markets package to its
/// collateral pool. Created at module init; the `predict_id` is filled in
/// once via `create_predict`.
public struct Registry has key { id: UID, predict_id: Option<ID> }

// === Public Functions ===

/// Get the Predict ID (None if not yet created).
public fun predict_id(registry: &Registry): Option<ID> {
    registry.predict_id
}

/// Admin-only: create the package's single collateral pool. Idempotent;
/// reverts with `EPredictAlreadyCreated` on the second call.
public fun create_predict<Quote>(
    registry: &mut Registry,
    _admin_cap: &AdminCap,
    ctx: &mut TxContext,
): ID {
    assert!(registry.predict_id.is_none(), EPredictAlreadyCreated);
    let predict_id = predict::create<Quote>(ctx);
    registry.predict_id = option::some(predict_id);
    event::emit(PredictCreated { predict_id });
    predict_id
}

/// Admin-only: deposit collateral into the pool without minting outcomes
/// (subsidy/seeding path).
public fun admin_deposit<Quote>(
    predict: &mut predict::Predict<Quote>,
    _admin_cap: &AdminCap,
    coin: Coin<Quote>,
) {
    predict.deposit(coin);
}

/// Admin-only: pause or unpause new splits on the collateral pool.
public fun set_paused<Quote>(
    predict: &mut predict::Predict<Quote>,
    _admin_cap: &AdminCap,
    paused: bool,
) {
    predict.set_paused(paused);
}

/// Admin-only: mint a price-oracle operator capability.
public fun create_oracle_cap_price(_admin_cap: &AdminCap, ctx: &mut TxContext): OracleCapPrice {
    oracle_price::create_oracle_cap(ctx)
}

/// Admin-only: create a new threshold price oracle bound to the given operator cap.
public fun create_price_oracle<Underlying>(
    _admin_cap: &AdminCap,
    cap: &OracleCapPrice,
    expiry: u64,
    threshold: u64,
    threshold_above: bool,
    is_touch_market: bool,
    touch_confirmations_required: u64,
    max_fair_price_delta: u64,
    ctx: &mut TxContext,
): ID {
    let oracle_id = oracle_price::create_oracle<Underlying>(
        cap,
        expiry,
        threshold,
        threshold_above,
        is_touch_market,
        touch_confirmations_required,
        max_fair_price_delta,
        ctx,
    );
    event::emit(PriceOracleCreated {
        oracle_id,
        oracle_cap_id: object::id(cap),
        expiry,
        threshold,
        threshold_above,
        is_touch_market,
    });
    oracle_id
}

/// Admin-only: mint a categorical-oracle operator capability.
public fun create_oracle_cap_categorical(
    _admin_cap: &AdminCap,
    ctx: &mut TxContext,
): OracleCapCategorical {
    oracle_categorical::create_oracle_cap(ctx)
}

/// Admin-only: create a new categorical oracle bound to the given operator cap.
public fun create_categorical_oracle(
    _admin_cap: &AdminCap,
    cap: &OracleCapCategorical,
    expiry: u64,
    num_outcomes: u8,
    max_fair_prices_delta: u64,
    ctx: &mut TxContext,
): ID {
    let oracle_id = oracle_categorical::create_oracle(
        cap,
        expiry,
        num_outcomes,
        max_fair_prices_delta,
        ctx,
    );
    event::emit(CategoricalOracleCreated {
        oracle_id,
        oracle_cap_id: object::id(cap),
        expiry,
        num_outcomes,
    });
    oracle_id
}

/// Admin-only: resolve a categorical oracle to its winning outcome.
public fun resolve_categorical_oracle(
    oracle: &mut oracle_categorical::OracleCategorical,
    _admin_cap: &AdminCap,
    cap: &OracleCapCategorical,
    winning_outcome: u8,
    clock: &sui::clock::Clock,
) {
    oracle_categorical::resolve(oracle, cap, winning_outcome, clock);
}

/// Admin-only: mint a `MarketCap` authorizing a threshold market template
/// to operate on the given pool/oracle pair.
public fun register_threshold_market<Quote>(
    _admin_cap: &AdminCap,
    predict: &predict::Predict<Quote>,
    oracle_id: ID,
    ctx: &mut TxContext,
): market_cap::MarketCap {
    market_cap::new_threshold(object::id(predict), oracle_id, ctx)
}

/// Admin-only: mint a `MarketCap` authorizing a categorical market template
/// to operate on the given pool/oracle pair.
public fun register_categorical_market<Quote>(
    _admin_cap: &AdminCap,
    predict: &predict::Predict<Quote>,
    oracle_id: ID,
    num_outcomes: u8,
    ctx: &mut TxContext,
): market_cap::MarketCap {
    market_cap::new_categorical(object::id(predict), oracle_id, num_outcomes, ctx)
}

// === Private Functions ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(Registry { id: object::new(ctx), predict_id: option::none() });
    transfer::transfer(AdminCap { id: object::new(ctx) }, ctx.sender());
}

// === Test-Only Functions ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) { init(ctx); }
#[test_only]
public fun create_admin_cap_for_testing(ctx: &mut TxContext): AdminCap {
    AdminCap { id: object::new(ctx) }
}
