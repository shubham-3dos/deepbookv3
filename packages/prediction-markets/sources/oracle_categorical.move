// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Categorical oracle for multi-outcome prediction markets.
module prediction_markets::oracle_categorical;

use sui::{clock::Clock, event};

const EInvalidOracleCap: u64 = 0;
const EOracleStale: u64 = 1;
const EOracleAlreadyActive: u64 = 2;
const EOracleExpired: u64 = 3;
const EAlreadyResolved: u64 = 4;
const EInvalidOutcome: u64 = 5;
const EInvalidFairPrices: u64 = 7;
const EPricesSumInvalid: u64 = 8;
const EOraclePricesNotSet: u64 = 9;
const EOracleNotExpired: u64 = 10;

const FLOAT_SCALING: u64 = 1_000_000_000;
const FAIR_PRICE_SUM_TOLERANCE: u64 = 20_000_000;
const STALENESS_THRESHOLD_MS: u64 = 30_000;

// === Events ===

public struct OracleCategoricalActivated has copy, drop, store {
    oracle_id: ID, num_outcomes: u8, expiry: u64, timestamp: u64,
}
public struct OracleCategoricalUpdated has copy, drop, store {
    oracle_id: ID, fair_prices: vector<u64>, timestamp: u64,
}
public struct OracleCategoricalResolved has copy, drop, store {
    oracle_id: ID, winning_outcome: u8, timestamp: u64,
}

// === Structs ===

public struct OracleCategorical has key {
    id: UID,
    oracle_cap_id: ID,
    expiry: u64,
    active: bool,
    num_outcomes: u8,
    fair_prices: vector<u64>,
    timestamp: u64,
    winning_outcome: Option<u8>,
}

public struct OracleCapCategorical has key, store { id: UID }

// === Public Functions ===

public fun activate(oracle: &mut OracleCategorical, cap: &OracleCapCategorical, clock: &Clock) {
    assert_authorized_cap(oracle, cap);
    assert!(!oracle.active, EOracleAlreadyActive);
    assert!(clock.timestamp_ms() < oracle.expiry, EOracleExpired);
    assert!(oracle.timestamp > 0, EOraclePricesNotSet);
    oracle.active = true;
    event::emit(OracleCategoricalActivated {
        oracle_id: oracle.id.to_inner(), num_outcomes: oracle.num_outcomes,
        expiry: oracle.expiry, timestamp: clock.timestamp_ms(),
    });
}

public fun update_prices(
    oracle: &mut OracleCategorical, cap: &OracleCapCategorical,
    fair_prices: vector<u64>, clock: &Clock,
) {
    assert_authorized_cap(oracle, cap);
    assert!(clock.timestamp_ms() < oracle.expiry, EOracleExpired);
    assert!(oracle.winning_outcome.is_none(), EAlreadyResolved);
    assert!(fair_prices.length() == (oracle.num_outcomes as u64), EInvalidFairPrices);

    let mut sum = 0u64;
    fair_prices.do_ref!(|p| { sum = sum + *p; });
    assert!(
        sum >= FLOAT_SCALING - FAIR_PRICE_SUM_TOLERANCE
            && sum <= FLOAT_SCALING + FAIR_PRICE_SUM_TOLERANCE,
        EPricesSumInvalid,
    );

    oracle.fair_prices = fair_prices;
    oracle.timestamp = clock.timestamp_ms();
    event::emit(OracleCategoricalUpdated {
        oracle_id: oracle.id.to_inner(), fair_prices: oracle.fair_prices, timestamp: oracle.timestamp,
    });
}

public fun resolve(
    oracle: &mut OracleCategorical, cap: &OracleCapCategorical,
    winning_outcome: u8, clock: &Clock,
) {
    assert_authorized_cap(oracle, cap);
    assert!(clock.timestamp_ms() >= oracle.expiry, EOracleNotExpired);
    assert!(oracle.winning_outcome.is_none(), EAlreadyResolved);
    assert!(winning_outcome < oracle.num_outcomes, EInvalidOutcome);
    oracle.winning_outcome = option::some(winning_outcome);
    oracle.active = false;
    event::emit(OracleCategoricalResolved {
        oracle_id: oracle.id.to_inner(), winning_outcome, timestamp: clock.timestamp_ms(),
    });
}

public fun id(oracle: &OracleCategorical): ID { oracle.id.to_inner() }
public fun expiry(oracle: &OracleCategorical): u64 { oracle.expiry }
public fun num_outcomes(oracle: &OracleCategorical): u8 { oracle.num_outcomes }
public fun fair_prices(oracle: &OracleCategorical): vector<u64> { oracle.fair_prices }
public fun fair_price(oracle: &OracleCategorical, index: u8): u64 { oracle.fair_prices[index as u64] }
public fun is_resolved(oracle: &OracleCategorical): bool { oracle.winning_outcome.is_some() }
public fun winning_outcome(oracle: &OracleCategorical): Option<u8> { oracle.winning_outcome }
public fun is_active(oracle: &OracleCategorical): bool { oracle.active }
public fun is_stale(oracle: &OracleCategorical, clock: &Clock): bool {
    clock.timestamp_ms() > oracle.timestamp + STALENESS_THRESHOLD_MS
}

// === Public-Package Functions ===

public(package) fun create_oracle_cap(ctx: &mut TxContext): OracleCapCategorical {
    OracleCapCategorical { id: object::new(ctx) }
}

public(package) fun create_oracle(
    cap: &OracleCapCategorical, expiry: u64, num_outcomes: u8, ctx: &mut TxContext,
): ID {
    let oracle_uid = object::new(ctx);
    let oracle_id = oracle_uid.to_inner();
    let mut fair_prices = vector[];
    let mut i = 0u8;
    while (i < num_outcomes) { fair_prices.push_back(0); i = i + 1; };
    transfer::share_object(OracleCategorical {
        id: oracle_uid, oracle_cap_id: cap.id.to_inner(), expiry, active: false,
        num_outcomes, fair_prices, timestamp: 0, winning_outcome: option::none(),
    });
    oracle_id
}

public(package) fun assert_not_stale(oracle: &OracleCategorical, clock: &Clock) {
    assert!(!is_stale(oracle, clock), EOracleStale);
}

fun assert_authorized_cap(oracle: &OracleCategorical, cap: &OracleCapCategorical) {
    assert!(oracle.oracle_cap_id == cap.id.to_inner(), EInvalidOracleCap);
}

// === Test Functions ===

#[test_only]
public(package) fun create_test_oracle(
    expiry: u64, num_outcomes: u8, fair_prices: vector<u64>, timestamp: u64, ctx: &mut TxContext,
): OracleCategorical {
    OracleCategorical {
        id: object::new(ctx), oracle_cap_id: object::id_from_address(@0x0),
        expiry, active: true, num_outcomes, fair_prices, timestamp,
        winning_outcome: option::none(),
    }
}

#[test_only]
public(package) fun resolve_test_oracle(oracle: &mut OracleCategorical, winning_outcome: u8) {
    oracle.winning_outcome = option::some(winning_outcome);
    oracle.active = false;
}
