// Market package code generator.
// Reads from template_threshold/ or template_categorical/ and produces
// a market-specific Move package with unique coin types.
//
// Usage:
//   pnpm tsx transactions/predict/generateMarket.ts \
//     --market-name sui_dec25 \
//     --market-type threshold \
//     --num-outcomes 2

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import { execFileSync } from "child_process";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PACKAGES_DIR = path.resolve(__dirname, "../../../packages/markets");
const SUI = process.env.SUI_BINARY ?? "sui";

// Parse CLI args
function parseArgs() {
  const args: Record<string, string> = {};
  for (let i = 2; i < process.argv.length; i += 2) {
    const key = process.argv[i]?.replace(/^--/, "");
    const val = process.argv[i + 1];
    if (key && val) args[key] = val;
  }
  return args;
}

const cliArgs = parseArgs();
const MARKET_NAME = cliArgs["market-name"] ?? process.env.MARKET_NAME;
const MARKET_TYPE =
  (cliArgs["market-type"] ?? process.env.MARKET_TYPE ?? "threshold") as
    | "threshold"
    | "categorical";
const NUM_OUTCOMES = parseInt(
  cliArgs["num-outcomes"] ?? process.env.NUM_OUTCOMES ?? "2",
  10,
);

if (!MARKET_NAME) {
  console.error("Usage: --market-name <name> [--market-type threshold|categorical] [--num-outcomes N]");
  process.exit(1);
}

const PKG_NAME = `prediction_market_${MARKET_NAME}`;
const OUTPUT_DIR = path.join(PACKAGES_DIR, `market_${MARKET_NAME}`);

console.log("=".repeat(60));
console.log("Market Package Generator");
console.log("=".repeat(60));
console.log(`  Name:       ${MARKET_NAME}`);
console.log(`  Type:       ${MARKET_TYPE}`);
console.log(`  Outcomes:   ${NUM_OUTCOMES}`);
console.log(`  Package:    ${PKG_NAME}`);
console.log(`  Output:     ${OUTPUT_DIR}`);
console.log("");

if (fs.existsSync(OUTPUT_DIR)) {
  console.error(`Output directory already exists: ${OUTPUT_DIR}`);
  console.error("Delete it first or choose a different name.");
  process.exit(1);
}

// ---- Template reading ----

function readTemplate(templateType: string, relPath: string): string {
  const templateDir = path.join(PACKAGES_DIR, `template_${templateType}`);
  return fs.readFileSync(path.join(templateDir, relPath), "utf-8");
}

// ---- Threshold generator ----

function generateThreshold() {
  const templateType = "threshold";
  const templatePkg = "prediction_market_threshold";

  fs.mkdirSync(path.join(OUTPUT_DIR, "sources"), { recursive: true });

  // Move.toml
  const moveToml = readTemplate(templateType, "Move.toml").replaceAll(
    templatePkg,
    PKG_NAME,
  );
  fs.writeFileSync(path.join(OUTPUT_DIR, "Move.toml"), moveToml);

  // yes.move
  let yesMod = readTemplate(templateType, "sources/yes.move").replaceAll(
    templatePkg,
    PKG_NAME,
  );
  yesMod = yesMod.replaceAll(
    'b"YES".to_string()',
    `b"${MARKET_NAME.toUpperCase()}_YES".to_string()`,
  );
  yesMod = yesMod.replaceAll(
    'b"Prediction YES".to_string()',
    `b"${MARKET_NAME} YES".to_string()`,
  );
  fs.writeFileSync(path.join(OUTPUT_DIR, "sources/yes.move"), yesMod);

  // no.move
  let noMod = readTemplate(templateType, "sources/no.move").replaceAll(
    templatePkg,
    PKG_NAME,
  );
  noMod = noMod.replaceAll(
    'b"NO".to_string()',
    `b"${MARKET_NAME.toUpperCase()}_NO".to_string()`,
  );
  noMod = noMod.replaceAll(
    'b"Prediction NO".to_string()',
    `b"${MARKET_NAME} NO".to_string()`,
  );
  fs.writeFileSync(path.join(OUTPUT_DIR, "sources/no.move"), noMod);

  // market.move
  const marketMod = readTemplate(templateType, "sources/market.move").replaceAll(
    templatePkg,
    PKG_NAME,
  );
  fs.writeFileSync(path.join(OUTPUT_DIR, "sources/market.move"), marketMod);

  console.log("Generated threshold market with YES/NO outcomes");
}

// ---- Categorical generator ----

function generateCategorical() {
  const templateType = "categorical";
  const templatePkg = "prediction_market_categorical";

  fs.mkdirSync(path.join(OUTPUT_DIR, "sources"), { recursive: true });

  // Move.toml
  const moveToml = readTemplate(templateType, "Move.toml").replaceAll(
    templatePkg,
    PKG_NAME,
  );
  fs.writeFileSync(path.join(OUTPUT_DIR, "Move.toml"), moveToml);

  // Outcome modules — generate exactly NUM_OUTCOMES
  const outcomeTemplate = readTemplate(templateType, "sources/outcome_0.move");
  for (let i = 0; i < NUM_OUTCOMES; i++) {
    let mod = outcomeTemplate
      .replaceAll(templatePkg, PKG_NAME)
      .replaceAll("outcome_0", `outcome_${i}`)
      .replaceAll("OUTCOME_0", `OUTCOME_${i}`)
      .replaceAll("OUT_0", `OUT_${i}`)
      .replaceAll("Outcome 0", `Outcome ${i}`);
    fs.writeFileSync(path.join(OUTPUT_DIR, `sources/outcome_${i}.move`), mod);
  }

  // market.move — need to generate for exactly NUM_OUTCOMES
  // Read template (4 outcomes), then regenerate for N
  generateCategoricalMarketModule();

  console.log(`Generated categorical market with ${NUM_OUTCOMES} outcomes`);
}

function generateCategoricalMarketModule() {
  const imports = Array.from({ length: NUM_OUTCOMES }, (_, i) =>
    `    outcome_${i}::OUTCOME_${i}`,
  ).join(",\n");

  const treasuryFields = Array.from({ length: NUM_OUTCOMES }, (_, i) =>
    `    treasury_${i}: TreasuryCap<OUTCOME_${i}>,`,
  ).join("\n");

  const treasuryParams = Array.from({ length: NUM_OUTCOMES }, (_, i) =>
    `    treasury_${i}: TreasuryCap<OUTCOME_${i}>,`,
  ).join("\n");

  const treasuryAssigns = Array.from({ length: NUM_OUTCOMES }, (_, i) =>
    `        treasury_${i},`,
  ).join("\n");

  const mintFunctions = Array.from({ length: NUM_OUTCOMES }, (_, i) => `
/// Mint outcome ${i} tokens.
public fun mint_outcome_${i}<Quote>(
    state: &mut MarketState,
    predict: &mut Predict<Quote>,
    oracle: &OracleCategorical,
    quantity: u64,
    max_cost: u64,
    payment: Coin<Quote>,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<OUTCOME_${i}>, Coin<Quote>) {
    let (cost, refund) = predict.tokenized_mint_categorical(
        &state.cap, oracle, ${i}, quantity, payment, clock,
    );
    assert!(cost <= max_cost, ESlippageExceeded);

    event::emit(CategoricalPositionMinted {
        market_id: object::id(state),
        oracle_id: state.cap.oracle_id(),
        trader: ctx.sender(),
        outcome_index: ${i},
        quantity,
        cost,
    });

    (coin::mint(&mut state.treasury_${i}, quantity, ctx), refund.into_coin(ctx))
}`).join("\n");

  const redeemFunctions = Array.from({ length: NUM_OUTCOMES }, (_, i) => `
/// Redeem outcome ${i} tokens for USDC.
public fun redeem_outcome_${i}<Quote>(
    state: &mut MarketState,
    predict: &mut Predict<Quote>,
    oracle: &OracleCategorical,
    position_coin: Coin<OUTCOME_${i}>,
    min_payout: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Quote> {
    let quantity = position_coin.value();
    coin::burn(&mut state.treasury_${i}, position_coin);

    let payout_balance = predict.tokenized_redeem_categorical(
        &state.cap, oracle, ${i}, quantity, clock,
    );
    let payout = payout_balance.value();
    assert!(payout >= min_payout, ESlippageExceeded);

    event::emit(CategoricalPositionRedeemed {
        market_id: object::id(state),
        oracle_id: state.cap.oracle_id(),
        trader: ctx.sender(),
        outcome_index: ${i},
        quantity,
        payout,
    });

    payout_balance.into_coin(ctx)
}`).join("\n");

  const source = `module ${PKG_NAME}::market;

use deepbook_predict::{
    market_cap::MarketCap,
    oracle_categorical::OracleCategorical,
    predict::Predict
};
use ${PKG_NAME}::{
${imports}
};
use sui::{clock::Clock, coin::{Self, Coin, TreasuryCap}, event};

const ESlippageExceeded: u64 = 0;

public struct CategoricalPositionMinted has copy, drop, store {
    market_id: ID,
    oracle_id: ID,
    trader: address,
    outcome_index: u8,
    quantity: u64,
    cost: u64,
}

public struct CategoricalPositionRedeemed has copy, drop, store {
    market_id: ID,
    oracle_id: ID,
    trader: address,
    outcome_index: u8,
    quantity: u64,
    payout: u64,
}

public struct MarketState has key {
    id: UID,
    cap: MarketCap,
${treasuryFields}
}

public fun initialize(
    cap: MarketCap,
${treasuryParams}
    ctx: &mut TxContext,
) {
    let state = MarketState {
        id: object::new(ctx),
        cap,
${treasuryAssigns}
    };
    transfer::share_object(state);
}
${mintFunctions}
${redeemFunctions}
`;

  fs.writeFileSync(path.join(OUTPUT_DIR, "sources/market.move"), source);
}

// ---- Main ----

if (MARKET_TYPE === "threshold") {
  generateThreshold();
} else {
  generateCategorical();
}

// Validate build
console.log("\nValidating build...");
try {
  execFileSync(SUI, ["move", "build", "--path", OUTPUT_DIR], {
    encoding: "utf-8",
    stdio: "pipe",
  });
  console.log("Build OK");
} catch (e: any) {
  console.error("Build FAILED:");
  console.error(e.stderr || e.stdout || e.message);
  process.exit(1);
}

console.log(`\nMarket package generated at: ${OUTPUT_DIR}`);
