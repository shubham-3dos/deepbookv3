// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Simple price oracle for threshold prediction markets (YES/NO).
///
/// Settlement modes:
/// - At-expiry: settles on first price update after expiry
/// - Touch: settles when price crosses threshold N times
module prediction_markets::oracle_price;

use sui::{clock::Clock, event};

// === Errors ===
const EInvalidOracleCap: u64 = 0;
const EOracleStale: u64 = 1;
const EOracleAlreadyActive: u64 = 2;
const EOracleExpired: u64 = 3;
const EInvalidFairPrice: u64 = 4;
const EFairPriceDeltaExceeded: u64 = 5;
const EOraclePricesNotSet: u64 = 6;
const EInvalidTouchConfirmations: u64 = 7;

const STALENESS_THRESHOLD_MS: u64 = 30_000;
const MIN_TOUCH_INTERVAL_MS: u64 = 5_000;
const FLOAT_SCALING: u64 = 1_000_000_000;

// === Events ===

public struct OraclePriceActivated has copy, drop, store {
    oracle_id: ID, expiry: u64, threshold: u64, threshold_above: bool,
    is_touch_market: bool, timestamp: u64,
}

public struct OraclePriceUpdated has copy, drop, store {
    oracle_id: ID, spot: u64, fair_price: u64, touch_count: u64, timestamp: u64,
}

public struct OraclePriceSettled has copy, drop, store {
    oracle_id: ID, expiry: u64, settlement_price: u64, yes_wins: bool, timestamp: u64,
}

// === Structs ===

public struct OraclePrice<phantom Underlying> has key {
    id: UID,
    oracle_cap_id: ID,
    expiry: u64,
    active: bool,
    spot: u64,
    fair_price: u64,
    timestamp: u64,
    settlement_price: Option<u64>,
    threshold: u64,
    threshold_above: bool,
    touch_count: u64,
    touch_confirmations_required: u64,
    last_touch_timestamp: u64,
    max_fair_price_delta: u64,
    is_touch_market: bool,
    yes_wins: bool,
}

public struct OracleCapPrice has key, store { id: UID }

// === Public Functions ===

public fun activate<Underlying>(oracle: &mut OraclePrice<Underlying>, cap: &OracleCapPrice, clock: &Clock) {
    assert_authorized_cap(oracle, cap);
    assert!(!oracle.active, EOracleAlreadyActive);
    assert!(clock.timestamp_ms() < oracle.expiry, EOracleExpired);
    assert!(oracle.timestamp > 0, EOraclePricesNotSet);
    oracle.active = true;
    event::emit(OraclePriceActivated {
        oracle_id: oracle.id.to_inner(), expiry: oracle.expiry, threshold: oracle.threshold,
        threshold_above: oracle.threshold_above, is_touch_market: oracle.is_touch_market,
        timestamp: clock.timestamp_ms(),
    });
}

public fun update_price<Underlying>(
    oracle: &mut OraclePrice<Underlying>, cap: &OracleCapPrice,
    spot: u64, fair_price: u64, clock: &Clock,
) {
    assert_authorized_cap(oracle, cap);
    assert!(fair_price <= FLOAT_SCALING, EInvalidFairPrice);
    let now = clock.timestamp_ms();

    if (oracle.timestamp > 0 && oracle.settlement_price.is_none()) {
        let delta = if (fair_price > oracle.fair_price) { fair_price - oracle.fair_price }
                    else { oracle.fair_price - fair_price };
        assert!(delta <= oracle.max_fair_price_delta, EFairPriceDeltaExceeded);
    };

    if (oracle.settlement_price.is_none() && oracle.active) {
        if (oracle.is_touch_market) {
            let threshold_crossed = if (oracle.threshold_above) { spot >= oracle.threshold }
                                    else { spot <= oracle.threshold };
            if (threshold_crossed && now >= oracle.last_touch_timestamp + MIN_TOUCH_INTERVAL_MS) {
                oracle.touch_count = oracle.touch_count + 1;
                oracle.last_touch_timestamp = now;
                if (oracle.touch_count >= oracle.touch_confirmations_required) {
                    oracle.settlement_price = option::some(spot);
                    oracle.active = false;
                    oracle.yes_wins = true;
                    event::emit(OraclePriceSettled {
                        oracle_id: oracle.id.to_inner(), expiry: oracle.expiry,
                        settlement_price: spot, yes_wins: true, timestamp: now,
                    });
                };
            } else if (!threshold_crossed) { oracle.touch_count = 0; };
            if (now > oracle.expiry && oracle.settlement_price.is_none()) {
                oracle.settlement_price = option::some(spot);
                oracle.active = false;
                oracle.yes_wins = false;
                event::emit(OraclePriceSettled {
                    oracle_id: oracle.id.to_inner(), expiry: oracle.expiry,
                    settlement_price: spot, yes_wins: false, timestamp: now,
                });
            };
        } else {
            if (now > oracle.expiry) {
                let yes_wins = if (oracle.threshold_above) { spot >= oracle.threshold }
                               else { spot <= oracle.threshold };
                oracle.settlement_price = option::some(spot);
                oracle.active = false;
                oracle.yes_wins = yes_wins;
                event::emit(OraclePriceSettled {
                    oracle_id: oracle.id.to_inner(), expiry: oracle.expiry,
                    settlement_price: spot, yes_wins, timestamp: now,
                });
            };
        };
    };

    if (oracle.settlement_price.is_none()) {
        oracle.spot = spot;
        oracle.fair_price = fair_price;
    };
    oracle.timestamp = now;
    event::emit(OraclePriceUpdated {
        oracle_id: oracle.id.to_inner(), spot: oracle.spot, fair_price: oracle.fair_price,
        touch_count: oracle.touch_count, timestamp: now,
    });
}

public fun id<Underlying>(oracle: &OraclePrice<Underlying>): ID { oracle.id.to_inner() }
public fun expiry<Underlying>(oracle: &OraclePrice<Underlying>): u64 { oracle.expiry }
public fun threshold<Underlying>(oracle: &OraclePrice<Underlying>): u64 { oracle.threshold }
public fun is_settled<Underlying>(oracle: &OraclePrice<Underlying>): bool { oracle.settlement_price.is_some() }
public fun is_yes_winner<Underlying>(oracle: &OraclePrice<Underlying>): bool { oracle.yes_wins }
public fun is_active<Underlying>(oracle: &OraclePrice<Underlying>): bool { oracle.active }
public fun fair_price<Underlying>(oracle: &OraclePrice<Underlying>): u64 { oracle.fair_price }
public fun spot<Underlying>(oracle: &OraclePrice<Underlying>): u64 { oracle.spot }

public fun is_stale<Underlying>(oracle: &OraclePrice<Underlying>, clock: &Clock): bool {
    clock.timestamp_ms() > oracle.timestamp + STALENESS_THRESHOLD_MS
}

// === Public-Package Functions ===

public(package) fun create_oracle_cap(ctx: &mut TxContext): OracleCapPrice {
    OracleCapPrice { id: object::new(ctx) }
}

public(package) fun create_oracle<Underlying>(
    cap: &OracleCapPrice, expiry: u64, threshold: u64, threshold_above: bool,
    is_touch_market: bool, touch_confirmations_required: u64, max_fair_price_delta: u64,
    ctx: &mut TxContext,
): ID {
    if (is_touch_market) { assert!(touch_confirmations_required >= 1, EInvalidTouchConfirmations); };
    let oracle_uid = object::new(ctx);
    let oracle_id = oracle_uid.to_inner();
    transfer::share_object(OraclePrice<Underlying> {
        id: oracle_uid, oracle_cap_id: cap.id.to_inner(), expiry, active: false,
        spot: 0, fair_price: 0, timestamp: 0, settlement_price: option::none(),
        threshold, threshold_above, touch_count: 0, touch_confirmations_required,
        last_touch_timestamp: 0, max_fair_price_delta, is_touch_market, yes_wins: false,
    });
    oracle_id
}

public(package) fun assert_not_stale<Underlying>(oracle: &OraclePrice<Underlying>, clock: &Clock) {
    assert!(!is_stale(oracle, clock), EOracleStale);
}

fun assert_authorized_cap<Underlying>(oracle: &OraclePrice<Underlying>, cap: &OracleCapPrice) {
    assert!(oracle.oracle_cap_id == cap.id.to_inner(), EInvalidOracleCap);
}

// === Test Functions ===

#[test_only]
public(package) fun create_test_oracle<Underlying>(
    expiry: u64, threshold: u64, threshold_above: bool, is_touch_market: bool,
    touch_confirmations_required: u64, max_fair_price_delta: u64,
    fair_price: u64, spot: u64, timestamp: u64, ctx: &mut TxContext,
): OraclePrice<Underlying> {
    OraclePrice<Underlying> {
        id: object::new(ctx), oracle_cap_id: object::id_from_address(@0x0),
        expiry, active: true, spot, fair_price, timestamp,
        settlement_price: option::none(), threshold, threshold_above,
        touch_count: 0, touch_confirmations_required, last_touch_timestamp: 0,
        max_fair_price_delta, is_touch_market, yes_wins: false,
    }
}

#[test_only]
public(package) fun settle_test_oracle<Underlying>(
    oracle: &mut OraclePrice<Underlying>, price: u64, yes_wins: bool,
) {
    oracle.settlement_price = option::some(price);
    oracle.active = false;
    oracle.yes_wins = yes_wins;
}
