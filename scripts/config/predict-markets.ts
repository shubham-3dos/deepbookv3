// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

export interface OutcomeEntry {
  name: string;
  moduleName: string;
  coinType: string;
  poolId: string;
}

export interface MarketEntry {
  name: string;
  packageId: string;
  marketStateId: string;
  oracleId: string;
  marketType: "threshold" | "categorical";
  outcomes: OutcomeEntry[];
}

export const predictMarkets: Record<string, MarketEntry[]> = {
  testnet: [],
  mainnet: [],
};
