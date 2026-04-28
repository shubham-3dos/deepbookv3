// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Oracle for categorical (N-outcome) prediction markets.
///
/// One oracle per market, holding a vector of implied probabilities (scaled
/// by `float_scaling`) that sum to ~1.0 within `fair_price_sum_tolerance`.
/// Settlement is admin-driven via `resolve` after expiry; the operator is
/// responsible for keeping prices fresh until then.
module prediction_markets::oracle_categorical;

use prediction_markets::constants;
use sui::{clock::Clock, event};

const EInvalidOracleCap: u64 = 0;
const EOracleStale: u64 = 1;
const EOracleAlreadyActive: u64 = 2;
const EOracleExpired: u64 = 3;
const EAlreadyResolved: u64 = 4;
const EInvalidOutcome: u64 = 5;
const EInvalidNumOutcomes: u64 = 6;
const EInvalidFairPrices: u64 = 7;
const EPricesSumInvalid: u64 = 8;
const EOraclePricesNotSet: u64 = 9;
const EOracleNotExpired: u64 = 10;
const EFairPricesDeltaExceeded: u64 = 11;

/// Emitted when the oracle is activated for live pricing.
public struct OracleCategoricalActivated has copy, drop, store {
    oracle_id: ID,
    num_outcomes: u8,
    expiry: u64,
    timestamp_ms: u64,
}

/// Emitted on every successful operator price update prior to resolution.
public struct OracleCategoricalUpdated has copy, drop, store {
    oracle_id: ID,
    fair_prices: vector<u64>,
    timestamp_ms: u64,
}

/// Emitted exactly once, when the admin resolves to a winning outcome.
public struct OracleCategoricalResolved has copy, drop, store {
    oracle_id: ID,
    winning_outcome: u8,
    timestamp_ms: u64,
}

/// Shared oracle for categorical prediction markets (2+ outcomes).
public struct OracleCategorical has key {
    id: UID,
    /// ID of the OracleCapCategorical authorized to update this oracle
    oracle_cap_id: ID,
    /// Expiration time in milliseconds
    expiry: u64,
    /// Whether the oracle has been activated
    active: bool,
    /// Number of possible outcomes (2-255)
    num_outcomes: u8,
    /// Implied probability for each outcome (scaled by FLOAT_SCALING, sum ~= 1.0)
    fair_prices: vector<u64>,
    /// Timestamp of last update in milliseconds
    timestamp_ms: u64,
    /// Maximum allowed L1 distance between consecutive fair_prices vectors,
    /// in scaled units. Caps how far prices can move between updates.
    max_fair_prices_delta: u64,
    /// Winning outcome index (0-indexed), set on resolution
    winning_outcome: Option<u8>,
}

/// Capability for oracle operator to create and update categorical oracles.
public struct OracleCapCategorical has key, store {
    id: UID,
}

// === Public Functions ===

/// Operator-only: flip the oracle to active. Requires that prices have
/// been seeded (timestamp_ms > 0) and that current time is before expiry.
public fun activate(oracle: &mut OracleCategorical, cap: &OracleCapCategorical, clock: &Clock) {
    assert_authorized_cap(oracle, cap);
    assert!(!oracle.active, EOracleAlreadyActive);
    assert!(clock.timestamp_ms() < oracle.expiry, EOracleExpired);
    assert!(oracle.timestamp_ms > 0, EOraclePricesNotSet);
    oracle.active = true;
    event::emit(OracleCategoricalActivated {
        oracle_id: oracle.id.to_inner(),
        num_outcomes: oracle.num_outcomes,
        expiry: oracle.expiry,
        timestamp_ms: clock.timestamp_ms(),
    });
}

/// Operator-only: refresh the implied-probability vector. Asserts the new
/// vector has the right length, sums to ~1.0 within tolerance, and (after
/// the first update) moves no more than `max_fair_prices_delta` in L1
/// distance from the previous vector.
public fun update_prices(
    oracle: &mut OracleCategorical,
    cap: &OracleCapCategorical,
    fair_prices: vector<u64>,
    clock: &Clock,
) {
    assert_authorized_cap(oracle, cap);
    assert!(clock.timestamp_ms() < oracle.expiry, EOracleExpired);
    assert!(oracle.winning_outcome.is_none(), EAlreadyResolved);
    assert!(fair_prices.length() == (oracle.num_outcomes as u64), EInvalidFairPrices);

    let mut sum = 0u64;
    fair_prices.do_ref!(|p| { sum = sum + *p; });
    assert!(
        sum >= constants::float_scaling!() - constants::fair_price_sum_tolerance!()
            && sum <= constants::float_scaling!() + constants::fair_price_sum_tolerance!(),
        EPricesSumInvalid,
    );

    // Rate-of-change circuit breaker: skip on the seeding update (when
    // timestamp_ms == 0 the existing vector is the all-zeros initialization).
    if (oracle.timestamp_ms > 0) {
        let n = (oracle.num_outcomes as u64);
        let mut l1 = 0u64;
        let mut i = 0u64;
        while (i < n) {
            let old = oracle.fair_prices[i];
            let new = fair_prices[i];
            let diff = if (new > old) new - old else old - new;
            l1 = l1 + diff;
            i = i + 1;
        };
        assert!(l1 <= oracle.max_fair_prices_delta, EFairPricesDeltaExceeded);
    };

    oracle.fair_prices = fair_prices;
    oracle.timestamp_ms = clock.timestamp_ms();
    event::emit(OracleCategoricalUpdated {
        oracle_id: oracle.id.to_inner(),
        fair_prices: oracle.fair_prices,
        timestamp_ms: oracle.timestamp_ms,
    });
}

/// Operator-only: freeze the oracle on a winning outcome. Only callable
/// after expiry and only once.
public fun resolve(
    oracle: &mut OracleCategorical,
    cap: &OracleCapCategorical,
    winning_outcome: u8,
    clock: &Clock,
) {
    assert_authorized_cap(oracle, cap);
    assert!(clock.timestamp_ms() >= oracle.expiry, EOracleNotExpired);
    assert!(oracle.winning_outcome.is_none(), EAlreadyResolved);
    assert!(winning_outcome < oracle.num_outcomes, EInvalidOutcome);
    oracle.winning_outcome = option::some(winning_outcome);
    oracle.active = false;
    event::emit(OracleCategoricalResolved {
        oracle_id: oracle.id.to_inner(),
        winning_outcome,
        timestamp_ms: clock.timestamp_ms(),
    });
}

/// On-chain ID of this shared oracle.
public fun id(oracle: &OracleCategorical): ID { oracle.id.to_inner() }

/// Configured expiry (ms since epoch).
public fun expiry(oracle: &OracleCategorical): u64 { oracle.expiry }

/// Number of outcomes for this oracle (always >= 2).
public fun num_outcomes(oracle: &OracleCategorical): u8 { oracle.num_outcomes }

/// Snapshot of the implied-probability vector.
public fun fair_prices(oracle: &OracleCategorical): vector<u64> { oracle.fair_prices }

/// Implied probability for a single outcome index.
public fun fair_price(oracle: &OracleCategorical, index: u8): u64 {
    oracle.fair_prices[index as u64]
}

/// True once the oracle has resolved.
public fun is_resolved(oracle: &OracleCategorical): bool { oracle.winning_outcome.is_some() }

/// Winning outcome index (None pre-resolution).
public fun winning_outcome(oracle: &OracleCategorical): Option<u8> { oracle.winning_outcome }

/// True while the oracle is accepting live updates (post-activate, pre-resolve).
public fun is_active(oracle: &OracleCategorical): bool { oracle.active }

/// True if the last operator update is older than `staleness_threshold_ms`.
public fun is_stale(oracle: &OracleCategorical, clock: &Clock): bool {
    clock.timestamp_ms() > oracle.timestamp_ms + constants::staleness_threshold_ms!()
}

// === Public-Package Functions ===

/// Mint a new operator capability. Registry-only.
public(package) fun create_oracle_cap(ctx: &mut TxContext): OracleCapCategorical {
    OracleCapCategorical { id: object::new(ctx) }
}

/// Create and share a new categorical oracle. Registry-only.
public(package) fun create_oracle(
    cap: &OracleCapCategorical,
    expiry: u64,
    num_outcomes: u8,
    max_fair_prices_delta: u64,
    ctx: &mut TxContext,
): ID {
    assert!(num_outcomes >= 2, EInvalidNumOutcomes);
    let oracle_uid = object::new(ctx);
    let oracle_id = oracle_uid.to_inner();
    let mut fair_prices = vector[];
    let mut i = 0u8;
    while (i < num_outcomes) { fair_prices.push_back(0); i = i + 1; };
    transfer::share_object(OracleCategorical {
        id: oracle_uid,
        oracle_cap_id: cap.id.to_inner(),
        expiry,
        active: false,
        num_outcomes,
        fair_prices,
        timestamp_ms: 0,
        max_fair_prices_delta,
        winning_outcome: option::none(),
    });
    oracle_id
}

/// Abort with `EOracleStale` if the oracle has gone stale.
public(package) fun assert_not_stale(oracle: &OracleCategorical, clock: &Clock) {
    assert!(!is_stale(oracle, clock), EOracleStale);
}

// === Private Functions ===

fun assert_authorized_cap(oracle: &OracleCategorical, cap: &OracleCapCategorical) {
    assert!(oracle.oracle_cap_id == cap.id.to_inner(), EInvalidOracleCap);
}

// === Test-Only Functions ===

#[test_only]
public(package) fun create_test_oracle(
    expiry: u64,
    num_outcomes: u8,
    fair_prices: vector<u64>,
    timestamp_ms: u64,
    max_fair_prices_delta: u64,
    ctx: &mut TxContext,
): OracleCategorical {
    OracleCategorical {
        id: object::new(ctx),
        oracle_cap_id: object::id_from_address(@0x0),
        expiry,
        active: true,
        num_outcomes,
        fair_prices,
        timestamp_ms,
        max_fair_prices_delta,
        winning_outcome: option::none(),
    }
}

#[test_only]
/// Create a test oracle AND a matching cap for testing update/resolve flows.
public(package) fun create_test_oracle_with_cap(
    expiry: u64,
    num_outcomes: u8,
    fair_prices: vector<u64>,
    timestamp_ms: u64,
    max_fair_prices_delta: u64,
    ctx: &mut TxContext,
): (OracleCategorical, OracleCapCategorical) {
    let cap = OracleCapCategorical { id: object::new(ctx) };
    let oracle = OracleCategorical {
        id: object::new(ctx),
        oracle_cap_id: cap.id.to_inner(),
        expiry,
        active: true,
        num_outcomes,
        fair_prices,
        timestamp_ms,
        max_fair_prices_delta,
        winning_outcome: option::none(),
    };
    (oracle, cap)
}

#[test_only]
public(package) fun resolve_test_oracle(oracle: &mut OracleCategorical, winning_outcome: u8) {
    oracle.winning_outcome = option::some(winning_outcome);
    oracle.active = false;
}
