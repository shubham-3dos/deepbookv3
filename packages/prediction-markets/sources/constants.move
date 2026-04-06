// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Shared protocol constants for prediction markets.
module prediction_markets::constants;

/// Fixed-point scaling factor (1e9) for probabilities and prices.
/// 500_000_000 = 50%, 1_000_000_000 = 100%
public macro fun float_scaling(): u64 { 1_000_000_000 }

/// Oracle staleness threshold (30 seconds)
public macro fun staleness_threshold_ms(): u64 { 30_000 }

/// Minimum interval between touch confirmations (5 seconds)
public macro fun min_touch_interval_ms(): u64 { 5_000 }

/// Tolerance for categorical fair price sum (2% = 20_000_000)
public macro fun fair_price_sum_tolerance(): u64 { 20_000_000 }
