/// CTF-style categorical prediction market (4-outcome template).
///
/// - Split: 1 USDC → 1 of each OUTCOME_N coin (paired minting, 100% backed)
/// - Merge: 1 of each OUTCOME_N → 1 USDC (paired burning)
/// - Settle: oracle resolves → winning outcome redeems for $1, losers for $0
module prediction_market_categorical::market;

use prediction_market_categorical::{
    outcome_0::OUTCOME_0,
    outcome_1::OUTCOME_1,
    outcome_2::OUTCOME_2,
    outcome_3::OUTCOME_3
};
use prediction_markets::{
    market_cap::MarketCap,
    oracle_categorical::OracleCategorical,
    predict::Predict
};
use sui::{coin::{Self, Coin, TreasuryCap}, event};

const EAmountMismatch: u64 = 0;
const EOracleNotResolved: u64 = 1;
const EInvalidOracle: u64 = 2;
const EOutcomeCountMismatch: u64 = 3;

public struct PositionSplit has copy, drop, store {
    market_id: ID,
    trader: address,
    amount: u64,
}

public struct PositionMerged has copy, drop, store {
    market_id: ID,
    trader: address,
    amount: u64,
}

public struct PositionSettled has copy, drop, store {
    market_id: ID,
    trader: address,
    outcome_index: u8,
    amount: u64,
    payout: u64,
}

public struct MarketState has key {
    id: UID,
    cap: MarketCap,
    treasury_0: TreasuryCap<OUTCOME_0>,
    treasury_1: TreasuryCap<OUTCOME_1>,
    treasury_2: TreasuryCap<OUTCOME_2>,
    treasury_3: TreasuryCap<OUTCOME_3>,
}

// === Public Functions ===

public fun initialize(
    cap: MarketCap,
    treasury_0: TreasuryCap<OUTCOME_0>,
    treasury_1: TreasuryCap<OUTCOME_1>,
    treasury_2: TreasuryCap<OUTCOME_2>,
    treasury_3: TreasuryCap<OUTCOME_3>,
    ctx: &mut TxContext,
) {
    assert!(cap.num_outcomes() == 4, EOutcomeCountMismatch);
    transfer::share_object(MarketState {
        id: object::new(ctx),
        cap,
        treasury_0,
        treasury_1,
        treasury_2,
        treasury_3,
    });
}

/// Split: 1 USDC → 1 of each outcome coin.
public fun split<Quote>(
    state: &mut MarketState,
    predict: &mut Predict<Quote>,
    payment: Coin<Quote>,
    ctx: &mut TxContext,
): (Coin<OUTCOME_0>, Coin<OUTCOME_1>, Coin<OUTCOME_2>, Coin<OUTCOME_3>) {
    let amount = predict.split_collateral(&state.cap, payment);
    event::emit(PositionSplit { market_id: object::id(state), trader: ctx.sender(), amount });
    (
        coin::mint(&mut state.treasury_0, amount, ctx),
        coin::mint(&mut state.treasury_1, amount, ctx),
        coin::mint(&mut state.treasury_2, amount, ctx),
        coin::mint(&mut state.treasury_3, amount, ctx),
    )
}

/// Merge: 1 of each outcome → 1 USDC.
public fun merge<Quote>(
    state: &mut MarketState,
    predict: &mut Predict<Quote>,
    coin_0: Coin<OUTCOME_0>,
    coin_1: Coin<OUTCOME_1>,
    coin_2: Coin<OUTCOME_2>,
    coin_3: Coin<OUTCOME_3>,
    ctx: &mut TxContext,
): Coin<Quote> {
    let amount = coin_0.value();
    assert!(amount == coin_1.value(), EAmountMismatch);
    assert!(amount == coin_2.value(), EAmountMismatch);
    assert!(amount == coin_3.value(), EAmountMismatch);
    coin::burn(&mut state.treasury_0, coin_0);
    coin::burn(&mut state.treasury_1, coin_1);
    coin::burn(&mut state.treasury_2, coin_2);
    coin::burn(&mut state.treasury_3, coin_3);
    let payout = predict.merge_collateral(&state.cap, amount);
    event::emit(PositionMerged { market_id: object::id(state), trader: ctx.sender(), amount });
    payout.into_coin(ctx)
}

/// Settle outcome 0.
public fun settle_outcome_0<Quote>(
    state: &mut MarketState,
    predict: &mut Predict<Quote>,
    oracle: &OracleCategorical,
    position_coin: Coin<OUTCOME_0>,
    ctx: &mut TxContext,
): Coin<Quote> {
    assert!(oracle.is_resolved(), EOracleNotResolved);
    assert!(oracle.id() == state.cap.oracle_id(), EInvalidOracle);
    let amount = position_coin.value();
    let is_winner = oracle.winning_outcome().destroy_some() == 0;
    coin::burn(&mut state.treasury_0, position_coin);
    let payout = predict.settle_collateral(&state.cap, oracle.id(), amount, is_winner);
    let payout_amount = payout.value();
    event::emit(PositionSettled {
        market_id: object::id(state),
        trader: ctx.sender(),
        outcome_index: 0,
        amount,
        payout: payout_amount,
    });
    payout.into_coin(ctx)
}

/// Settle outcome 1.
public fun settle_outcome_1<Quote>(
    state: &mut MarketState,
    predict: &mut Predict<Quote>,
    oracle: &OracleCategorical,
    position_coin: Coin<OUTCOME_1>,
    ctx: &mut TxContext,
): Coin<Quote> {
    assert!(oracle.is_resolved(), EOracleNotResolved);
    assert!(oracle.id() == state.cap.oracle_id(), EInvalidOracle);
    let amount = position_coin.value();
    let is_winner = oracle.winning_outcome().destroy_some() == 1;
    coin::burn(&mut state.treasury_1, position_coin);
    let payout = predict.settle_collateral(&state.cap, oracle.id(), amount, is_winner);
    let payout_amount = payout.value();
    event::emit(PositionSettled {
        market_id: object::id(state),
        trader: ctx.sender(),
        outcome_index: 1,
        amount,
        payout: payout_amount,
    });
    payout.into_coin(ctx)
}

/// Settle outcome 2.
public fun settle_outcome_2<Quote>(
    state: &mut MarketState,
    predict: &mut Predict<Quote>,
    oracle: &OracleCategorical,
    position_coin: Coin<OUTCOME_2>,
    ctx: &mut TxContext,
): Coin<Quote> {
    assert!(oracle.is_resolved(), EOracleNotResolved);
    assert!(oracle.id() == state.cap.oracle_id(), EInvalidOracle);
    let amount = position_coin.value();
    let is_winner = oracle.winning_outcome().destroy_some() == 2;
    coin::burn(&mut state.treasury_2, position_coin);
    let payout = predict.settle_collateral(&state.cap, oracle.id(), amount, is_winner);
    let payout_amount = payout.value();
    event::emit(PositionSettled {
        market_id: object::id(state),
        trader: ctx.sender(),
        outcome_index: 2,
        amount,
        payout: payout_amount,
    });
    payout.into_coin(ctx)
}

/// Settle outcome 3.
public fun settle_outcome_3<Quote>(
    state: &mut MarketState,
    predict: &mut Predict<Quote>,
    oracle: &OracleCategorical,
    position_coin: Coin<OUTCOME_3>,
    ctx: &mut TxContext,
): Coin<Quote> {
    assert!(oracle.is_resolved(), EOracleNotResolved);
    assert!(oracle.id() == state.cap.oracle_id(), EInvalidOracle);
    let amount = position_coin.value();
    let is_winner = oracle.winning_outcome().destroy_some() == 3;
    coin::burn(&mut state.treasury_3, position_coin);
    let payout = predict.settle_collateral(&state.cap, oracle.id(), amount, is_winner);
    let payout_amount = payout.value();
    event::emit(PositionSettled {
        market_id: object::id(state),
        trader: ctx.sender(),
        outcome_index: 3,
        amount,
        payout: payout_amount,
    });
    payout.into_coin(ctx)
}
