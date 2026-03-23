// Deploy our own DeepBook instance on testnet.
// This gives us full control: our own DEEP token, AdminCap, Registry.
//
// Pipeline:
//   1. Publish token package → get DEEP coin + ProtectedTreasury
//   2. Publish deepbook package → get Registry + DeepbookAdminCap
//   3. Create Pool<YES, DUSDC> for a threshold market
//   4. Create Pool<NO, DUSDC> for the same market
//
// Usage: pnpm tsx transactions/predict/deployOwnDeepBook.ts

import { Transaction } from "@mysten/sui/transactions";
import { getClient, getSigner, publishPackage } from "../../utils/utils";
import {
  predictPackageID,
  predictObjectID,
  predictAdminCapID,
  dusdcPackageID,
} from "../../config/constants";
import { predictMarkets } from "../../config/predict-markets";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const TOKEN_PATH = path.resolve(__dirname, "../../../packages/token");
const DEEPBOOK_PATH = path.resolve(__dirname, "../../../packages/deepbook");

const network = "testnet" as const;
const client = getClient(network);
const signer = getSigner();
const address = signer.toSuiAddress();

const DUSDC_TYPE = `${dusdcPackageID[network]}::dusdc::DUSDC`;

console.log("=".repeat(60));
console.log("Deploy Own DeepBook Instance");
console.log("=".repeat(60));
console.log(`Deployer: ${address}`);
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

// === Step 1: Publish token package ===
console.log("--- Step 1: Publish token package (DEEP) ---");
const tx1 = new Transaction();
publishPackage(tx1, TOKEN_PATH);
const res1 = await run("publish_token", tx1);

let tokenPkgId = "";
let deepCoinId = "";
let protectedTreasuryId = "";

for (const obj of res1.objectChanges ?? []) {
  if (obj.type === "published") tokenPkgId = obj.packageId;
  if (obj.type === "created") {
    if (obj.objectType.includes("Coin<") && obj.objectType.includes("DEEP"))
      deepCoinId = obj.objectId;
    if (obj.objectType.includes("ProtectedTreasury"))
      protectedTreasuryId = obj.objectId;
  }
}
console.log(`  Token Package: ${tokenPkgId}`);
console.log(`  DEEP Coin:     ${deepCoinId}`);
console.log(`  Treasury:      ${protectedTreasuryId}`);
const DEEP_TYPE = `${tokenPkgId}::deep::DEEP`;
console.log(`  DEEP Type:     ${DEEP_TYPE}`);
console.log("");

// === Step 2: Publish deepbook package ===
console.log("--- Step 2: Publish deepbook package ---");
const tx2 = new Transaction();
publishPackage(tx2, DEEPBOOK_PATH);
const res2 = await run("publish_deepbook", tx2);

let deepbookPkgId = "";
let registryId = "";
let adminCapId = "";

for (const obj of res2.objectChanges ?? []) {
  if (obj.type === "published") deepbookPkgId = obj.packageId;
  if (obj.type === "created") {
    if (obj.objectType.includes("Registry")) registryId = obj.objectId;
    if (obj.objectType.includes("DeepbookAdminCap")) adminCapId = obj.objectId;
  }
}
console.log(`  DeepBook Package: ${deepbookPkgId}`);
console.log(`  Registry:         ${registryId}`);
console.log(`  AdminCap:         ${adminCapId}`);
console.log("");

// === Step 3: Create pools for the first deployed market ===
const markets = predictMarkets[network] ?? [];
const market = markets[markets.length - 1]; // most recent market

if (!market) {
  console.log("No deployed markets found. Skipping pool creation.");
  console.log("Deploy a market first with deployMarket.ts, then re-run.");
} else {
  console.log(`--- Step 3: Create pools for market "${market.name}" ---`);

  for (const outcome of market.outcomes) {
    console.log(`  Creating Pool<${outcome.name}, DUSDC>...`);
    const tx = new Transaction();
    tx.moveCall({
      target: `${deepbookPkgId}::pool::create_pool_admin`,
      typeArguments: [outcome.coinType, DUSDC_TYPE],
      arguments: [
        tx.object(registryId),
        tx.pure.u64(1_000_000),   // tick_size: 0.1%
        tx.pure.u64(1_000_000),   // lot_size: 1 contract
        tx.pure.u64(1_000_000),   // min_size: 1 contract
        tx.pure.bool(true),       // whitelisted (zero fees, no DEEP price feed needed)
        tx.pure.bool(false),      // stable
        tx.object(adminCapId),
      ],
    });
    const res = await run(`create_pool_${outcome.name}`, tx);

    let poolId = "";
    for (const obj of res.objectChanges ?? []) {
      if (obj.type === "created" && obj.objectType.includes("Pool")) {
        poolId = obj.objectId;
      }
    }
    outcome.poolId = poolId;
    console.log(`  Pool ID: ${poolId}`);
  }

  // Update market config with pool IDs
  const configPath = path.resolve(__dirname, "../../config/predict-markets.ts");
  let config = fs.readFileSync(configPath, "utf-8");
  // Simple: rewrite the full markets array
  const marketsJson = JSON.stringify(markets, null, 4).split("\n").join("\n    ");
  config = config.replace(
    /testnet: \[[\s\S]*?\n  \]/,
    `testnet: [\n    ${marketsJson}\n  ]`,
  );
  fs.writeFileSync(configPath, config);
  console.log("  Updated predict-markets.ts with pool IDs");
}

console.log("");
console.log("=".repeat(60));
console.log("DEPLOYMENT COMPLETE");
console.log("=".repeat(60));
console.log(`  Token Package:    ${tokenPkgId}`);
console.log(`  DEEP Type:        ${DEEP_TYPE}`);
console.log(`  DEEP Coin:        ${deepCoinId} (10B DEEP)`);
console.log(`  DeepBook Package: ${deepbookPkgId}`);
console.log(`  Registry:         ${registryId}`);
console.log(`  AdminCap:         ${adminCapId}`);
if (market) {
  console.log(`  Market:           ${market.name}`);
  for (const o of market.outcomes) {
    console.log(`    Pool<${o.name}, DUSDC>: ${o.poolId}`);
  }
}
console.log("=".repeat(60));

// Save IDs for other scripts
const idsPath = path.resolve(__dirname, "../../config/deepbook-own.ts");
const idsContent = `// Our own DeepBook instance on testnet
export const ownDeepBook = {
  tokenPackageId: "${tokenPkgId}",
  deepType: "${DEEP_TYPE}",
  deepCoinId: "${deepCoinId}",
  protectedTreasuryId: "${protectedTreasuryId}",
  deepbookPackageId: "${deepbookPkgId}",
  registryId: "${registryId}",
  adminCapId: "${adminCapId}",
};
`;
fs.writeFileSync(idsPath, idsContent);
console.log(`\nSaved IDs to config/deepbook-own.ts`);
