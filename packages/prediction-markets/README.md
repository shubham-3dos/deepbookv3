# Prediction Markets (CTF Model)

Polymarket-style prediction market protocol on Sui using the Conditional Token Framework.

## How It Works

```
Split:  1 USDC  →  1 YES + 1 NO    (paired minting, 100% collateral-backed)
Merge:  1 YES + 1 NO  →  1 USDC    (paired burning, inverse of split)
Settle: Oracle resolves  →  Winner burns for $1, Loser burns for $0
Trade:  Users trade Coin<YES>/Coin<NO> on DeepBook pools (protocol not involved)
```

Zero protocol risk. The collateral pool is mathematically guaranteed solvent.

## Architecture

```
packages/prediction-markets/
  sources/
    predict.move            — CTF collateral pool (split/merge/settle)
    market_cap.move         — MarketCap authorization capability
    registry.move           — Admin, oracle management, market registration
    oracle_price.move       — Threshold oracle (YES/NO, touch + at-expiry)
    oracle_categorical.move — Categorical oracle (N outcomes)
  tests/
    ctf_tests.move          — 14 tests: split, merge, settle, solvency, security
  markets/
    template_threshold/     — Market template for YES/NO markets
    template_categorical/   — Market template for N-outcome markets
```

## Key Concepts

- **Predict<Quote>**: Shared collateral pool holding USDC. One per deployment.
- **MarketCap**: Admin-issued capability authorizing a market package to split/merge/settle.
- **Market Package**: Per-market Move package with Coin<YES>/Coin<NO> (deployed lazily).
- **Oracle**: Settles the market. Threshold oracle for YES/NO, categorical for multi-outcome.

## User Flow

1. **Split**: User deposits 100 USDC → receives 100 YES + 100 NO coins
2. **Trade**: User sells NO on DeepBook `Pool<NO, USDC>` at $0.40 → gets 40 USDC back
3. **Wait**: Oracle resolves (YES wins)
4. **Settle**: User burns 100 YES → receives 100 USDC

Net: Paid 60 USDC effective, received 100 USDC. Profit: 40 USDC.

## Build & Test

```bash
# Core package
cd packages/prediction-markets
sui move build
sui move test --gas-limit 100000000000

# Market templates
cd markets/template_threshold && sui move build
cd markets/template_categorical && sui move build
```

## Deploy

```bash
cd scripts

# 1. Publish prediction-markets package
pnpm tsx transactions/predict/publish.ts

# 2. Initialize collateral pool
pnpm tsx transactions/predict/init.ts

# 3. Generate a market package from template
pnpm tsx transactions/predict/generateMarket.ts --market-name my_market --market-type threshold

# 4. Deploy market + create DeepBook pools
pnpm tsx transactions/predict/deployMarket.ts --market-name my_market --oracle-id 0x...

# 5. Deploy own DeepBook instance (optional, for zero-fee pools)
pnpm tsx transactions/predict/deployOwnDeepBook.ts
```

## Security

- **Oracle substitution prevention**: Every `settle` function validates `oracle.id() == state.cap.oracle_id()` — cannot use a different oracle to claim false winnings.
- **MarketCap authorization**: Only admin-issued MarketCaps can interact with the collateral pool.
- **Pause mechanism**: Admin can pause splits; merges and settlements always work (users can always exit).
- **Collateral invariant**: `pool.balance = Σ(splits) - Σ(merges) - Σ(winner_payouts)`. Mathematically guaranteed solvent.
