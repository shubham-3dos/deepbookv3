// On-chain stress test: 50 categorical markets, 1-5 outcomes each.
// Phase 1: Create all 50 oracles + activate + split USDC
// Phase 2: Wait for expiry
// Phase 3: Resolve all + settle winners/losers
//
// Usage: pnpm tsx transactions/predict/stressTest50Markets.ts

import { Transaction } from "@mysten/sui/transactions";
import { getClient, getSigner } from "../../utils/utils";
import {
  predictPackageID, predictObjectID, predictAdminCapID,
  predictRegistryID, dusdcPackageID, dusdcTreasuryCapID,
} from "../../config/constants";

const network = "testnet" as const;
const client = getClient(network);
const signer = getSigner();
const address = signer.toSuiAddress();

const PKG = predictPackageID[network];
const PREDICT = predictObjectID[network];
const ADMIN_CAP = predictAdminCapID[network];
const REGISTRY = predictRegistryID[network];
const DUSDC_TYPE = `${dusdcPackageID[network]}::dusdc::DUSDC`;
const DUSDC_TREASURY = dusdcTreasuryCapID[network];
const CLOCK = "0x6";

const NUM_MARKETS = 50;
const SPLIT_AMOUNT = 10_000_000; // 10 USDC
const EXPIRY_DELAY_MS = 600_000; // 10 minutes from now

let passed = 0;
let failed = 0;

function seededRandom(seed: number): () => number {
  let s = seed;
  return () => { s = (s * 1103515245 + 12345) & 0x7fffffff; return s / 0x7fffffff; };
}
const rand = seededRandom(42);

console.log("=".repeat(70));
console.log(`ON-CHAIN STRESS TEST: ${NUM_MARKETS} Markets`);
console.log("=".repeat(70));

async function run(name: string, tx: Transaction, debug = false): Promise<any> {
  try {
    const result = await client.signAndExecuteTransaction({
      transaction: tx, signer,
      options: { showEffects: true, showObjectChanges: true },
    });
    if (result.effects?.status.status !== "success") {
      if (debug) console.log(`  [FAIL] ${name}:`, result.effects?.status);
      failed++;
      return null;
    }
    await client.waitForTransaction({ digest: result.digest });
    passed++;
    return result;
  } catch (e: any) {
    if (debug) console.log(`  [ERROR] ${name}: ${e.message?.slice(0, 150)}`);
    failed++;
    return null;
  }
}

// === Setup ===
console.log("Phase 0: Setup");

const txCap = new Transaction();
const cap = txCap.moveCall({
  target: `${PKG}::registry::create_oracle_cap_categorical`,
  arguments: [txCap.object(ADMIN_CAP)],
});
txCap.transferObjects([cap], txCap.pure.address(address));
const resCap = await run("cap", txCap, true);
if (!resCap) { console.error("Failed to create oracle cap"); process.exit(1); }
let oracleCapId = "";
for (const obj of resCap.objectChanges ?? []) {
  if (obj.type === "created" && obj.objectType.includes("OracleCapCategorical"))
    oracleCapId = obj.objectId;
}
if (!oracleCapId) {
  // Might be transferred, not created — check for mutated objects
  for (const obj of resCap.objectChanges ?? []) {
    if (obj.type === "created" && obj.objectType.includes("oracle_categorical"))
      oracleCapId = obj.objectId;
  }
}
if (!oracleCapId) {
  console.error("Could not find OracleCapCategorical in object changes:");
  console.log(JSON.stringify(resCap.objectChanges?.map((o: any) => ({ type: o.type, objectType: o.objectType?.slice(0, 80), objectId: o.objectId })), null, 2));
  process.exit(1);
}
console.log(`  OracleCapCategorical: ${oracleCapId}`);

const txFund = new Transaction();
const fundCoin = txFund.moveCall({
  target: "0x2::coin::mint", typeArguments: [DUSDC_TYPE],
  arguments: [txFund.object(DUSDC_TREASURY), txFund.pure.u64(10_000_000_000_000)],
});
txFund.moveCall({
  target: `${PKG}::registry::admin_deposit`, typeArguments: [DUSDC_TYPE],
  arguments: [txFund.object(PREDICT), txFund.object(ADMIN_CAP), fundCoin],
});
await run("fund", txFund);
console.log("  Pool funded with 10M USDC\n");

// === Phase 1: Create markets, activate, split ===
console.log("Phase 1: Create 50 markets + split");
const expiryMs = Date.now() + EXPIRY_DELAY_MS;

interface MarketInfo {
  oracleId: string;
  marketCapId: string;
  numOutcomes: number;
  winner: number;
  splitCount: number;
}
const markets: MarketInfo[] = [];

for (let m = 0; m < NUM_MARKETS; m++) {
  const numOutcomes = Math.max(Math.floor(rand() * 5) + 1, 2);
  const winner = Math.floor(rand() * numOutcomes);

  // Create oracle + push prices + activate + register cap + split — all in one PTB!
  const tx = new Transaction();

  // Create oracle
  tx.moveCall({
    target: `${PKG}::registry::create_categorical_oracle`,
    arguments: [
      tx.object(REGISTRY), tx.object(ADMIN_CAP), tx.object(oracleCapId),
      tx.pure.u64(expiryMs), tx.pure.u8(numOutcomes),
    ],
  });

  const res = await run(`market_${m}`, tx);
  if (!res) { process.stdout.write("x"); continue; }

  let oracleId = "";
  for (const obj of res.objectChanges ?? [])
    if (obj.type === "created" && obj.objectType.includes("OracleCategorical"))
      oracleId = obj.objectId;

  // Activate: push prices then activate
  const fairPrices: number[] = [];
  let remaining = 1_000_000_000;
  for (let i = 0; i < numOutcomes - 1; i++) {
    const share = Math.floor(remaining / (numOutcomes - i) * (0.5 + rand()));
    fairPrices.push(Math.max(Math.min(share, remaining - (numOutcomes - i - 1) * 50_000_000), 50_000_000));
    remaining -= fairPrices[fairPrices.length - 1];
  }
  fairPrices.push(remaining);

  const txAct = new Transaction();
  txAct.moveCall({
    target: `${PKG}::oracle_categorical::update_prices`,
    arguments: [txAct.object(oracleId), txAct.object(oracleCapId), txAct.pure.vector("u64", fairPrices), txAct.object(CLOCK)],
  });
  txAct.moveCall({
    target: `${PKG}::oracle_categorical::activate`,
    arguments: [txAct.object(oracleId), txAct.object(oracleCapId), txAct.object(CLOCK)],
  });
  const resAct = await run(`activate_${m}`, txAct);
  if (!resAct) { process.stdout.write("a"); continue; }

  // Register market cap
  const txReg = new Transaction();
  const mCap = txReg.moveCall({
    target: `${PKG}::registry::register_categorical_market`, typeArguments: [DUSDC_TYPE],
    arguments: [txReg.object(ADMIN_CAP), txReg.object(PREDICT), txReg.pure.id(oracleId), txReg.pure.u8(numOutcomes)],
  });
  txReg.transferObjects([mCap], txReg.pure.address(address));
  const resReg = await run(`register_${m}`, txReg);
  if (!resReg) { process.stdout.write("r"); continue; }

  let marketCapId = "";
  for (const obj of resReg.objectChanges ?? [])
    if (obj.type === "created" && obj.objectType.includes("MarketCap"))
      marketCapId = obj.objectId;

  // Split USDC
  const txSplit = new Transaction();
  const payment = txSplit.moveCall({
    target: "0x2::coin::mint", typeArguments: [DUSDC_TYPE],
    arguments: [txSplit.object(DUSDC_TREASURY), txSplit.pure.u64(SPLIT_AMOUNT)],
  });
  txSplit.moveCall({
    target: `${PKG}::predict::split_collateral`, typeArguments: [DUSDC_TYPE],
    arguments: [txSplit.object(PREDICT), txSplit.object(marketCapId), payment],
  });
  await run(`split_${m}`, txSplit);

  markets.push({ oracleId, marketCapId, numOutcomes, winner, splitCount: 1 });
  process.stdout.write(".");
}
console.log(`\n  Created ${markets.length} markets\n`);

// === Phase 2: Wait for expiry ===
const waitMs = Math.max(0, expiryMs - Date.now() + 2000);
console.log(`Phase 2: Waiting ${Math.ceil(waitMs / 1000)}s for oracles to expire...`);
await new Promise(r => setTimeout(r, waitMs));
console.log("  Expired!\n");

// === Phase 3: Resolve + Settle ===
console.log("Phase 3: Resolve + settle all markets");
let totalWinnerPayout = 0;
let totalLoserSettle = 0;

for (let m = 0; m < markets.length; m++) {
  const mkt = markets[m];

  // Resolve
  const txRes = new Transaction();
  txRes.moveCall({
    target: `${PKG}::registry::resolve_categorical_oracle`,
    arguments: [
      txRes.object(mkt.oracleId), txRes.object(ADMIN_CAP),
      txRes.object(oracleCapId), txRes.pure.u8(mkt.winner), txRes.object(CLOCK),
    ],
  });
  const resResolve = await run(`resolve_${m}`, txRes, true);
  if (!resResolve) { process.stdout.write("x"); continue; }

  // Settle winner — must consume the returned Balance
  const txWin = new Transaction();
  const winBalance = txWin.moveCall({
    target: `${PKG}::predict::settle_collateral`, typeArguments: [DUSDC_TYPE],
    arguments: [txWin.object(PREDICT), txWin.object(mkt.marketCapId), txWin.pure.u64(SPLIT_AMOUNT), txWin.pure.bool(true)],
  });
  const winCoin = txWin.moveCall({
    target: "0x2::coin::from_balance", typeArguments: [DUSDC_TYPE],
    arguments: [winBalance],
  });
  txWin.transferObjects([winCoin], txWin.pure.address(address));
  const resWin = await run(`settle_win_${m}`, txWin, true);
  if (resWin) totalWinnerPayout += SPLIT_AMOUNT;

  // Settle losers
  for (let o = 0; o < mkt.numOutcomes; o++) {
    if (o === mkt.winner) continue;
    const txLose = new Transaction();
    const loseBalance = txLose.moveCall({
      target: `${PKG}::predict::settle_collateral`, typeArguments: [DUSDC_TYPE],
      arguments: [txLose.object(PREDICT), txLose.object(mkt.marketCapId), txLose.pure.u64(SPLIT_AMOUNT), txLose.pure.bool(false)],
    });
    const loseCoin = txLose.moveCall({
      target: "0x2::coin::from_balance", typeArguments: [DUSDC_TYPE],
      arguments: [loseBalance],
    });
    txLose.transferObjects([loseCoin], txLose.pure.address(address));
    const resLose = await run(`settle_lose_${m}_${o}`, txLose);
    if (resLose) totalLoserSettle++;
  }
  process.stdout.write(".");
}

console.log("\n");
console.log("=".repeat(70));
console.log("STRESS TEST RESULTS");
console.log("=".repeat(70));
console.log(`  Markets created:     ${markets.length}`);
console.log(`  Total splits:        ${markets.length} (${(markets.length * SPLIT_AMOUNT / 1_000_000).toFixed(0)} USDC deposited)`);
console.log(`  Winner payouts:      ${(totalWinnerPayout / 1_000_000).toFixed(0)} USDC`);
console.log(`  Loser settlements:   ${totalLoserSettle} (each got $0)`);
console.log(`  Vault profit:        ${((markets.length * SPLIT_AMOUNT - totalWinnerPayout) / 1_000_000).toFixed(0)} USDC (loser collateral retained)`);
console.log(`  Transactions passed: ${passed}`);
console.log(`  Transactions failed: ${failed}`);
console.log("=".repeat(70));

if (failed > 0) process.exit(1);
