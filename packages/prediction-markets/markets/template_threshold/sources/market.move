/// CTF-style threshold prediction market.
///
/// - Split: 1 USDC → 1 YES + 1 NO (paired minting, 100% backed)
/// - Merge: 1 YES + 1 NO → 1 USDC (paired burning)
/// - Settle: oracle resolves → winner redeems for $1, loser for $0
/// - Trading: users trade Coin<YES>/Coin<NO> on DeepBook pools directly
module prediction_market_threshold::market;

use prediction_market_threshold::{no::NO, yes::YES};
use prediction_markets::{market_cap::MarketCap, oracle_price::OraclePrice, predict::Predict};
use sui::{coin::{Self, Coin, TreasuryCap}, event};

const EAmountMismatch: u64 = 0;
const EOracleNotSettled: u64 = 1;
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
    is_yes: bool,
    amount: u64,
    payout: u64,
}

public struct MarketState has key {
    id: UID,
    cap: MarketCap,
    yes_treasury: TreasuryCap<YES>,
    no_treasury: TreasuryCap<NO>,
}

// === Public Functions ===

/// Initialize the market state.
public fun initialize(
    cap: MarketCap,
    yes_treasury: TreasuryCap<YES>,
    no_treasury: TreasuryCap<NO>,
    ctx: &mut TxContext,
) {
    assert!(cap.num_outcomes() == 2, EOutcomeCountMismatch);
    let state = MarketState { id: object::new(ctx), cap, yes_treasury, no_treasury };
    transfer::share_object(state);
}

/// Split: deposit USDC, receive equal amounts of YES + NO coins.
/// 1 USDC → 1 YES + 1 NO. Always 100% collateral-backed.
public fun split<Quote>(
    state: &mut MarketState,
    predict: &mut Predict<Quote>,
    payment: Coin<Quote>,
    ctx: &mut TxContext,
): (Coin<YES>, Coin<NO>) {
    let amount = predict.split_collateral(&state.cap, payment);

    event::emit(PositionSplit {
        market_id: object::id(state),
        trader: ctx.sender(),
        amount,
    });

    (
        coin::mint(&mut state.yes_treasury, amount, ctx),
        coin::mint(&mut state.no_treasury, amount, ctx),
    )
}

/// Merge: burn equal amounts of YES + NO, receive USDC back.
/// 1 YES + 1 NO → 1 USDC. Inverse of split.
public fun merge<Quote>(
    state: &mut MarketState,
    predict: &mut Predict<Quote>,
    yes_coin: Coin<YES>,
    no_coin: Coin<NO>,
    ctx: &mut TxContext,
): Coin<Quote> {
    let amount = yes_coin.value();
    assert!(amount == no_coin.value(), EAmountMismatch);

    coin::burn(&mut state.yes_treasury, yes_coin);
    coin::burn(&mut state.no_treasury, no_coin);

    let payout = predict.merge_collateral(&state.cap, amount);

    event::emit(PositionMerged {
        market_id: object::id(state),
        trader: ctx.sender(),
        amount,
    });

    payout.into_coin(ctx)
}

/// Settle YES tokens after oracle resolution.
/// Winner gets $1 per token. Loser gets $0.
public fun settle_yes<Underlying, Quote>(
    state: &mut MarketState,
    predict: &mut Predict<Quote>,
    oracle: &OraclePrice<Underlying>,
    yes_coin: Coin<YES>,
    ctx: &mut TxContext,
): Coin<Quote> {
    assert!(oracle.is_settled(), EOracleNotSettled);
    assert!(oracle.id() == state.cap.oracle_id(), EInvalidOracle);
    let amount = yes_coin.value();
    let is_winner = oracle.is_yes_winner();

    coin::burn(&mut state.yes_treasury, yes_coin);
    let payout = predict.settle_collateral(&state.cap, oracle.id(), amount, is_winner);
    let payout_amount = payout.value();

    event::emit(PositionSettled {
        market_id: object::id(state),
        trader: ctx.sender(),
        is_yes: true,
        amount,
        payout: payout_amount,
    });

    payout.into_coin(ctx)
}

/// Settle NO tokens after oracle resolution.
public fun settle_no<Underlying, Quote>(
    state: &mut MarketState,
    predict: &mut Predict<Quote>,
    oracle: &OraclePrice<Underlying>,
    no_coin: Coin<NO>,
    ctx: &mut TxContext,
): Coin<Quote> {
    assert!(oracle.is_settled(), EOracleNotSettled);
    assert!(oracle.id() == state.cap.oracle_id(), EInvalidOracle);
    let amount = no_coin.value();
    let is_winner = !oracle.is_yes_winner();

    coin::burn(&mut state.no_treasury, no_coin);
    let payout = predict.settle_collateral(&state.cap, oracle.id(), amount, is_winner);
    let payout_amount = payout.value();

    event::emit(PositionSettled {
        market_id: object::id(state),
        trader: ctx.sender(),
        is_yes: false,
        amount,
        payout: payout_amount,
    });

    payout.into_coin(ctx)
}
