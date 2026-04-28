// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Simple price oracle for threshold prediction markets (YES/NO).
///
/// Settlement modes:
/// - At-expiry: settles on first price update after expiry
/// - Touch: settles when price crosses threshold N times
module prediction_markets::oracle_price;

use prediction_markets::constants;
use sui::{clock::Clock, event};

const EInvalidOracleCap: u64 = 0;
const EOracleStale: u64 = 1;
const EOracleAlreadyActive: u64 = 2;
const EOracleExpired: u64 = 3;
const EInvalidFairPrice: u64 = 4;
const EFairPriceDeltaExceeded: u64 = 5;
const EOraclePricesNotSet: u64 = 6;
const EInvalidTouchConfirmations: u64 = 7;
const EOverflow: u64 = 8;

/// Emitted when the oracle is activated for live pricing.
public struct OraclePriceActivated has copy, drop, store {
    oracle_id: ID,
    expiry: u64,
    threshold: u64,
    threshold_above: bool,
    is_touch_market: bool,
    timestamp_ms: u64,
}

/// Emitted on every successful operator price update prior to settlement.
public struct OraclePriceUpdated has copy, drop, store {
    oracle_id: ID,
    spot: u64,
    fair_price: u64,
    touch_count: u64,
    timestamp_ms: u64,
}

/// Emitted exactly once, when settlement state freezes.
/// `yes_wins` reflects the binary outcome; `settlement_price` records the
/// spot at the moment of settlement.
public struct OraclePriceSettled has copy, drop, store {
    oracle_id: ID,
    expiry: u64,
    settlement_price: u64,
    yes_wins: bool,
    timestamp_ms: u64,
}

/// Shared oracle for threshold prediction markets (YES/NO).
/// One oracle per market, parameterized by phantom Underlying asset type.
public struct OraclePrice<phantom Underlying> has key {
    id: UID,
    /// ID of the OracleCapPrice authorized to update this oracle
    oracle_cap_id: ID,
    /// Expiration time in milliseconds
    expiry: u64,
    /// Whether the oracle has been activated for trading
    active: bool,
    /// Current spot price of the underlying
    spot: u64,
    /// Fair probability of YES outcome (scaled by FLOAT_SCALING)
    fair_price: u64,
    /// Timestamp of last update in milliseconds
    timestamp_ms: u64,
    /// Settlement price, frozen on resolution
    settlement_price: Option<u64>,
    /// Price threshold for YES/NO determination
    threshold: u64,
    /// If true, YES wins when spot >= threshold; if false, YES wins when spot <= threshold
    threshold_above: bool,
    /// Number of times threshold has been crossed (touch markets only)
    touch_count: u64,
    /// How many threshold crosses required for touch settlement
    touch_confirmations_required: u64,
    /// Timestamp of last touch crossing (debounce timer)
    last_touch_timestamp_ms: u64,
    /// Maximum allowed fair_price change per update
    max_fair_price_delta: u64,
    /// Settlement mode: true = touch, false = at-expiry
    is_touch_market: bool,
    /// Whether YES outcome won (valid after settlement)
    yes_wins: bool,
}

/// Capability for oracle operator to create and update price oracles.
public struct OracleCapPrice has key, store {
    id: UID,
}

// === Public Functions ===

/// Operator-only: flip the oracle to active. Requires that prices have
/// been seeded (timestamp_ms > 0) and that current time is before expiry.
public fun activate<Underlying>(
    oracle: &mut OraclePrice<Underlying>,
    cap: &OracleCapPrice,
    clock: &Clock,
) {
    assert_authorized_cap(oracle, cap);
    assert!(!oracle.active, EOracleAlreadyActive);
    assert!(clock.timestamp_ms() < oracle.expiry, EOracleExpired);
    assert!(oracle.timestamp_ms > 0, EOraclePricesNotSet);
    oracle.active = true;
    event::emit(OraclePriceActivated {
        oracle_id: oracle.id.to_inner(),
        expiry: oracle.expiry,
        threshold: oracle.threshold,
        threshold_above: oracle.threshold_above,
        is_touch_market: oracle.is_touch_market,
        timestamp_ms: clock.timestamp_ms(),
    });
}

/// Operator-only: refresh spot and fair_price. While the oracle is active,
/// each update may trigger settlement (at-expiry or touch). After settlement
/// the function still accepts updates but only bumps `timestamp_ms` and
/// returns without emitting an update event.
public fun update_price<Underlying>(
    oracle: &mut OraclePrice<Underlying>,
    cap: &OracleCapPrice,
    spot: u64,
    fair_price: u64,
    clock: &Clock,
) {
    assert_authorized_cap(oracle, cap);
    assert!(fair_price <= constants::float_scaling!(), EInvalidFairPrice);
    let now = clock.timestamp_ms();

    // Validate fair price delta against previous update
    if (oracle.timestamp_ms > 0 && oracle.settlement_price.is_none()) {
        let delta = if (fair_price > oracle.fair_price) {
            fair_price - oracle.fair_price
        } else {
            oracle.fair_price - fair_price
        };
        assert!(delta <= oracle.max_fair_price_delta, EFairPriceDeltaExceeded);
    };

    // Try settlement if oracle is live
    if (oracle.settlement_price.is_none() && oracle.active) {
        if (oracle.is_touch_market) {
            try_settle_touch(oracle, spot, now);
        } else {
            try_settle_expiry(oracle, spot, now);
        };
    };

    // After settlement, only update timestamp_ms and return (no update event)
    if (oracle.settlement_price.is_some()) {
        oracle.timestamp_ms = now;
        return
    };

    // Update live prices
    oracle.spot = spot;
    oracle.fair_price = fair_price;
    oracle.timestamp_ms = now;

    event::emit(OraclePriceUpdated {
        oracle_id: oracle.id.to_inner(),
        spot,
        fair_price,
        touch_count: oracle.touch_count,
        timestamp_ms: now,
    });
}

/// On-chain ID of this shared oracle.
public fun id<Underlying>(oracle: &OraclePrice<Underlying>): ID { oracle.id.to_inner() }

/// Configured expiry (ms since epoch).
public fun expiry<Underlying>(oracle: &OraclePrice<Underlying>): u64 { oracle.expiry }

/// Configured price threshold for YES/NO determination.
public fun threshold<Underlying>(oracle: &OraclePrice<Underlying>): u64 { oracle.threshold }

/// True once a settlement price has been frozen.
public fun is_settled<Underlying>(oracle: &OraclePrice<Underlying>): bool {
    oracle.settlement_price.is_some()
}

/// True iff the YES outcome won (only meaningful after settlement).
public fun is_yes_winner<Underlying>(oracle: &OraclePrice<Underlying>): bool { oracle.yes_wins }

/// True while the oracle is accepting live updates (post-activate, pre-settle).
public fun is_active<Underlying>(oracle: &OraclePrice<Underlying>): bool { oracle.active }

/// Most-recently-pushed implied YES probability (scaled by `float_scaling`).
public fun fair_price<Underlying>(oracle: &OraclePrice<Underlying>): u64 { oracle.fair_price }

/// Most-recently-pushed underlying spot price.
public fun spot<Underlying>(oracle: &OraclePrice<Underlying>): u64 { oracle.spot }

/// True if the last operator update is older than `staleness_threshold_ms`.
public fun is_stale<Underlying>(oracle: &OraclePrice<Underlying>, clock: &Clock): bool {
    clock.timestamp_ms() > oracle.timestamp_ms + constants::staleness_threshold_ms!()
}

// === Public-Package Functions ===

/// Mint a new operator capability. Registry-only.
public(package) fun create_oracle_cap(ctx: &mut TxContext): OracleCapPrice {
    OracleCapPrice { id: object::new(ctx) }
}

/// Create and share a new threshold oracle. Registry-only.
public(package) fun create_oracle<Underlying>(
    cap: &OracleCapPrice,
    expiry: u64,
    threshold: u64,
    threshold_above: bool,
    is_touch_market: bool,
    touch_confirmations_required: u64,
    max_fair_price_delta: u64,
    ctx: &mut TxContext,
): ID {
    if (is_touch_market) {
        assert!(touch_confirmations_required >= 1, EInvalidTouchConfirmations);
    };
    let oracle_uid = object::new(ctx);
    let oracle_id = oracle_uid.to_inner();
    transfer::share_object(OraclePrice<Underlying> {
        id: oracle_uid,
        oracle_cap_id: cap.id.to_inner(),
        expiry,
        active: false,
        spot: 0,
        fair_price: 0,
        timestamp_ms: 0,
        settlement_price: option::none(),
        threshold,
        threshold_above,
        touch_count: 0,
        touch_confirmations_required,
        last_touch_timestamp_ms: 0,
        max_fair_price_delta,
        is_touch_market,
        yes_wins: false,
    });
    oracle_id
}

/// Abort with `EOracleStale` if the oracle has gone stale.
public(package) fun assert_not_stale<Underlying>(oracle: &OraclePrice<Underlying>, clock: &Clock) {
    assert!(!is_stale(oracle, clock), EOracleStale);
}

// === Private Functions ===

/// Touch market: settle YES if threshold crossed enough times, NO if expiry passes.
fun try_settle_touch<Underlying>(oracle: &mut OraclePrice<Underlying>, spot: u64, now: u64) {
    let threshold_crossed = if (oracle.threshold_above) {
        spot >= oracle.threshold
    } else {
        spot <= oracle.threshold
    };

    if (threshold_crossed) {
        let interval = constants::min_touch_interval_ms!();
        assert!(oracle.last_touch_timestamp_ms <= std::u64::max_value!() - interval, EOverflow);
        if (now >= oracle.last_touch_timestamp_ms + interval) {
            assert!(oracle.touch_count < std::u64::max_value!(), EOverflow);
            oracle.touch_count = oracle.touch_count + 1;
            oracle.last_touch_timestamp_ms = now;
            if (oracle.touch_count >= oracle.touch_confirmations_required) {
                settle(oracle, spot, true, now);
                return
            };
        };
    } else {
        oracle.touch_count = 0;
    };

    // Touch market past expiry without enough touches: NO wins
    if (now > oracle.expiry && oracle.settlement_price.is_none()) {
        settle(oracle, spot, false, now);
    };
}

/// At-expiry market: settle on first update after expiry.
fun try_settle_expiry<Underlying>(oracle: &mut OraclePrice<Underlying>, spot: u64, now: u64) {
    if (now > oracle.expiry) {
        let yes_wins = if (oracle.threshold_above) {
            spot >= oracle.threshold
        } else {
            spot <= oracle.threshold
        };
        settle(oracle, spot, yes_wins, now);
    };
}

/// Freeze settlement state and emit settled event.
fun settle<Underlying>(oracle: &mut OraclePrice<Underlying>, spot: u64, yes_wins: bool, now: u64) {
    oracle.settlement_price = option::some(spot);
    oracle.active = false;
    oracle.yes_wins = yes_wins;
    event::emit(OraclePriceSettled {
        oracle_id: oracle.id.to_inner(),
        expiry: oracle.expiry,
        settlement_price: spot,
        yes_wins,
        timestamp_ms: now,
    });
}

fun assert_authorized_cap<Underlying>(oracle: &OraclePrice<Underlying>, cap: &OracleCapPrice) {
    assert!(oracle.oracle_cap_id == cap.id.to_inner(), EInvalidOracleCap);
}

// === Test-Only Functions ===

#[test_only]
public(package) fun create_test_oracle<Underlying>(
    expiry: u64,
    threshold: u64,
    threshold_above: bool,
    is_touch_market: bool,
    touch_confirmations_required: u64,
    max_fair_price_delta: u64,
    fair_price: u64,
    spot: u64,
    timestamp_ms: u64,
    ctx: &mut TxContext,
): OraclePrice<Underlying> {
    OraclePrice<Underlying> {
        id: object::new(ctx),
        oracle_cap_id: object::id_from_address(@0x0),
        expiry,
        active: true,
        spot,
        fair_price,
        timestamp_ms,
        settlement_price: option::none(),
        threshold,
        threshold_above,
        touch_count: 0,
        touch_confirmations_required,
        last_touch_timestamp_ms: 0,
        max_fair_price_delta,
        is_touch_market,
        yes_wins: false,
    }
}

#[test_only]
/// Create a test oracle AND a matching cap for testing update_price flows.
public(package) fun create_test_oracle_with_cap<Underlying>(
    expiry: u64,
    threshold: u64,
    threshold_above: bool,
    is_touch_market: bool,
    touch_confirmations_required: u64,
    max_fair_price_delta: u64,
    fair_price: u64,
    spot: u64,
    timestamp_ms: u64,
    ctx: &mut TxContext,
): (OraclePrice<Underlying>, OracleCapPrice) {
    let cap = OracleCapPrice { id: object::new(ctx) };
    let oracle = OraclePrice<Underlying> {
        id: object::new(ctx),
        oracle_cap_id: cap.id.to_inner(),
        expiry,
        active: true,
        spot,
        fair_price,
        timestamp_ms,
        settlement_price: option::none(),
        threshold,
        threshold_above,
        touch_count: 0,
        touch_confirmations_required,
        last_touch_timestamp_ms: 0,
        max_fair_price_delta,
        is_touch_market,
        yes_wins: false,
    };
    (oracle, cap)
}

#[test_only]
public(package) fun settle_test_oracle<Underlying>(
    oracle: &mut OraclePrice<Underlying>,
    price: u64,
    yes_wins: bool,
) {
    oracle.settlement_price = option::some(price);
    oracle.active = false;
    oracle.yes_wins = yes_wins;
}
