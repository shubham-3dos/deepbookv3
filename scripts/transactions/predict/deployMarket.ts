// Deploy a generated market package to testnet.
// Pipeline: publish → register MarketCap → initialize MarketState
//
// Usage:
//   pnpm tsx transactions/predict/deployMarket.ts \
//     --market-name sui_test_1 \
//     --oracle-id 0xbf5f... \
//     --market-type threshold

import { Transaction } from "@mysten/sui/transactions";
import { getClient, getSigner, publishPackage } from "../../utils/utils";
import {
  predictPackageID,
  predictObjectID,
  predictAdminCapID,
  dusdcPackageID,
} from "../../config/constants";
import type { MarketEntry, OutcomeEntry } from "../../config/predict-markets";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const MARKETS_CONFIG = path.resolve(__dirname, "../../config/predict-markets.ts");

const network = "testnet" as const;
const client = getClient(network);
const signer = getSigner();
const address = signer.toSuiAddress();

const PKG = predictPackageID[network];
const PREDICT = predictObjectID[network];
const ADMIN_CAP = predictAdminCapID[network];
const DUSDC_TYPE = `${dusdcPackageID[network]}::dusdc::DUSDC`;

function parseArgs(): Record<string, string> {
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
const ORACLE_ID = cliArgs["oracle-id"] ?? process.env.ORACLE_ID;
const MARKET_TYPE = (cliArgs["market-type"] ?? process.env.MARKET_TYPE ?? "threshold") as "threshold" | "categorical";

if (!MARKET_NAME || !ORACLE_ID) {
  console.error("Usage: --market-name <name> --oracle-id <id> [--market-type threshold|categorical]");
  process.exit(1);
}

const PACKAGE_PATH = path.resolve(__dirname, `../../../packages/markets/market_${MARKET_NAME}`);

if (!fs.existsSync(PACKAGE_PATH)) {
  console.error(`Market package not found: ${PACKAGE_PATH}`);
  console.error("Run generateMarket.ts first.");
  process.exit(1);
}

console.log("=".repeat(60));
console.log("Deploy Market Package");
console.log("=".repeat(60));
console.log(`  Market:   ${MARKET_NAME}`);
console.log(`  Type:     ${MARKET_TYPE}`);
console.log(`  Oracle:   ${ORACLE_ID}`);
console.log(`  Deployer: ${address}`);
console.log("");

async function run(name: string, tx: Transaction) {
  console.log(`[${name}] Executing...`);
  const result = await client.signAndExecuteTransaction({
    transaction: tx,
    signer,
    options: { showEffects: true, showObjectChanges: true },
  });
  if (result.effects?.status.status !== "success") {
    console.error(`  FAILED:`, result.effects?.status);
    process.exit(1);
  }
  await client.waitForTransaction({ digest: result.digest });
  console.log(`  OK (${result.digest})`);
  return result;
}

// Step 1: Publish
console.log("--- Step 1: Publish market package ---");
const tx1 = new Transaction();
publishPackage(tx1, PACKAGE_PATH);
const res1 = await run("publish", tx1);

let marketPkgId = "";
const treasuryCaps: Record<string, string> = {};

for (const obj of res1.objectChanges ?? []) {
  if (obj.type === "published") {
    marketPkgId = obj.packageId;
  }
  if (obj.type === "created" && obj.objectType.includes("TreasuryCap")) {
    const match = obj.objectType.match(/::(\w+)::\w+>/);
    if (match) treasuryCaps[match[1]] = obj.objectId;
  }
}
console.log(`  Package: ${marketPkgId}`);
console.log(`  Caps:`, treasuryCaps);
console.log("");

// Step 2: Register market
console.log("--- Step 2: Register market ---");
const tx2 = new Transaction();
const registerTarget = MARKET_TYPE === "threshold"
  ? `${PKG}::registry::register_threshold_market`
  : `${PKG}::registry::register_categorical_market`;

const registerArgs: any[] = [
  tx2.object(ADMIN_CAP),
  tx2.object(PREDICT),
  tx2.pure.id(ORACLE_ID),
];
if (MARKET_TYPE === "categorical") {
  registerArgs.push(tx2.pure.u8(Object.keys(treasuryCaps).length));
}

const marketCap = tx2.moveCall({
  target: registerTarget,
  typeArguments: [DUSDC_TYPE],
  arguments: registerArgs,
});
tx2.transferObjects([marketCap], tx2.pure.address(address));
const res2 = await run("register", tx2);

let marketCapId = "";
for (const obj of res2.objectChanges ?? []) {
  if (obj.type === "created" && obj.objectType.includes("MarketCap")) {
    marketCapId = obj.objectId;
  }
}
console.log(`  MarketCap: ${marketCapId}`);
console.log("");

// Step 3: Initialize MarketState
console.log("--- Step 3: Initialize MarketState ---");
const tx3 = new Transaction();
if (MARKET_TYPE === "threshold") {
  tx3.moveCall({
    target: `${marketPkgId}::market::initialize`,
    arguments: [
      tx3.object(marketCapId),
      tx3.object(treasuryCaps["yes"]),
      tx3.object(treasuryCaps["no"]),
    ],
  });
} else {
  const capArgs: any[] = [tx3.object(marketCapId)];
  const n = Object.keys(treasuryCaps).filter(k => k.startsWith("outcome_")).length;
  for (let i = 0; i < n; i++) capArgs.push(tx3.object(treasuryCaps[`outcome_${i}`]));
  tx3.moveCall({ target: `${marketPkgId}::market::initialize`, arguments: capArgs });
}
const res3 = await run("initialize", tx3);

let marketStateId = "";
for (const obj of res3.objectChanges ?? []) {
  if (obj.type === "created" && obj.objectType.includes("MarketState")) {
    marketStateId = obj.objectId;
  }
}
console.log(`  MarketState: ${marketStateId}`);
console.log("");

// Build outcomes
const outcomes: OutcomeEntry[] = [];
if (MARKET_TYPE === "threshold") {
  outcomes.push(
    { name: "YES", moduleName: "yes", coinType: `${marketPkgId}::yes::YES`, poolId: "" },
    { name: "NO", moduleName: "no", coinType: `${marketPkgId}::no::NO`, poolId: "" },
  );
} else {
  const n = Object.keys(treasuryCaps).filter(k => k.startsWith("outcome_")).length;
  for (let i = 0; i < n; i++) {
    outcomes.push({
      name: `OUTCOME_${i}`, moduleName: `outcome_${i}`,
      coinType: `${marketPkgId}::outcome_${i}::OUTCOME_${i}`, poolId: "",
    });
  }
}

// Persist config
const entry: MarketEntry = {
  name: MARKET_NAME, packageId: marketPkgId, marketStateId,
  oracleId: ORACLE_ID, marketType: MARKET_TYPE, outcomes,
};
let config = fs.readFileSync(MARKETS_CONFIG, "utf-8");
config = config.replace(
  /testnet: \[([^\]]*)\]/s,
  (_, inner) => {
    const existing = inner.trim() ? inner.trim() + ",\n    " : "\n    ";
    return `testnet: [${existing}${JSON.stringify(entry, null, 4).split("\n").join("\n    ")}\n  ]`;
  },
);
fs.writeFileSync(MARKETS_CONFIG, config);

console.log("=".repeat(60));
console.log("DEPLOYMENT COMPLETE");
console.log("=".repeat(60));
console.log(`  Package:     ${marketPkgId}`);
console.log(`  MarketState: ${marketStateId}`);
console.log(`  MarketCap:   ${marketCapId}`);
console.log(`  Oracle:      ${ORACLE_ID}`);
for (const o of outcomes) console.log(`  ${o.name}: ${o.coinType}`);
console.log("=".repeat(60));
