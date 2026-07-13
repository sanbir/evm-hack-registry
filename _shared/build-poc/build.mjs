#!/usr/bin/env node
// Config-free PoC JSON builder for any registry slug folder.
//
// Reads ONLY data under <registry>/<folder>/ (anvil_state, sources, test/md)
// and emits a native evm-hack-analyzer POC JSON next to anvil_state.json.
//
// No per-hack configs. No vulnerability/story (mark those later in the analyzer
// UI). No hardcoded secrets. RPC is optional (only to resolve the attack-tx
// envelope when attack_tx.json is not already cached in the folder).
//
// Usage:
//   node build.mjs 2017-07-Parity_first_hack_exp
//   node build.mjs 2017-07-Parity_first_hack          # resolves to *_exp folder
//   HACKS_REGISTRY_DIR=/path/to/clone node build.mjs <folder>
//   ETH_RPC_URL=https://… node build.mjs <folder>    # only if attack_tx.json missing
//
// Output: <folder>/<slug>.json
//   slug = folder name with trailing _exp stripped (e.g. 2017-07-Parity_first_hack)

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { buildPcToLine } from "./lib/solidity-sourcemap.mjs";
import { compileAndMatch } from "./lib/compile-verified.mjs";
import { fetchVerifiedSource } from "./lib/source.mjs";

const POC_KIND = "evm-hack-analyzer-poc";
const POC_VERSION = 1;

const __filename = fileURLToPath(import.meta.url);
const HERE = path.dirname(__filename);
const REGISTRY_DIR = process.env.HACKS_REGISTRY_DIR || path.resolve(HERE, "../..");
const CHAINS_CONF = path.join(HERE, "..", "chains.conf");

function fail(msg) {
  throw new Error(msg);
}

function loadChains() {
  const map = {}; // chainName -> { port, chainId }
  if (!fs.existsSync(CHAINS_CONF)) return map;
  for (const line of fs.readFileSync(CHAINS_CONF, "utf8").split("\n")) {
    const t = line.trim();
    if (!t || t.startsWith("#")) continue;
    const [name, port, chainId] = t.split(/\s+/);
    if (name && chainId) map[name] = { port: parseInt(port, 10), chainId: parseInt(chainId, 10) };
  }
  return map;
}

function resolveFolder(arg) {
  const candidates = [
    arg,
    arg.endsWith("_exp") ? arg : `${arg}_exp`,
    arg.replace(/_exp$/, "")
  ];
  for (const c of candidates) {
    const p = path.join(REGISTRY_DIR, c);
    if (fs.existsSync(path.join(p, "anvil_state.json"))) return c;
  }
  fail(`no registry folder with anvil_state.json for "${arg}" under ${REGISTRY_DIR}`);
}

function folderToSlug(folder) {
  return folder.replace(/_exp$/, "");
}

/** Collect text from test/*.sol, root *.sol, and *.md for metadata extraction. */
function collectFolderText(hackDir) {
  let text = "";
  const roots = [hackDir, path.join(hackDir, "test")];
  for (const root of roots) {
    if (!fs.existsSync(root)) continue;
    for (const f of fs.readdirSync(root)) {
      if (!/\.(sol|md)$/i.test(f)) continue;
      try {
        text += "\n" + fs.readFileSync(path.join(root, f), "utf8");
      } catch {
        /* ignore */
      }
    }
  }
  return text;
}

function extractAttackTxHash(text) {
  const patterns = [
    /etherscan\.[^\s"'`)]+\/tx\/(0x[a-fA-F0-9]{64})/i,
    /bscscan\.[^\s"'`)]+\/tx\/(0x[a-fA-F0-9]{64})/i,
    /arbiscan\.[^\s"'`)]+\/tx\/(0x[a-fA-F0-9]{64})/i,
    /basescan\.[^\s"'`)]+\/tx\/(0x[a-fA-F0-9]{64})/i,
    /polygonscan\.[^\s"'`)]+\/tx\/(0x[a-fA-F0-9]{64})/i,
    /snowtrace\.[^\s"'`)]+\/tx\/(0x[a-fA-F0-9]{64})/i,
    /Attack\s*[Tt]x[^\n]{0,80}?(0x[a-fA-F0-9]{64})/,
    /attack.?tx[^\n]{0,80}?(0x[a-fA-F0-9]{64})/i,
    /txHash\s*[:=]\s*(0x[a-fA-F0-9]{64})/i
  ];
  for (const re of patterns) {
    const m = text.match(re);
    if (m) return m[1].toLowerCase();
  }
  // bytes32 constant TX = 0x… (first 64-hex const often is the attack tx)
  const c = text.match(/bytes32\s+(?:internal\s+|private\s+|public\s+)?(?:constant\s+)?\w*[Tt][Xx]\w*\s*=\s*(0x[a-fA-F0-9]{64})/);
  if (c) return c[1].toLowerCase();
  return null;
}

function detectChain(text, chains) {
  // createSelectFork("mainnet") / createSelectFork("http://127.0.0.1:8545")
  const fork = text.match(/create(?:Select)?Fork\(\s*"([^"]+)"/);
  if (fork) {
    const arg = fork[1];
    if (chains[arg]) return arg;
    const portM = arg.match(/127\.0\.0\.1:(\d+)/);
    if (portM) {
      const port = parseInt(portM[1], 10);
      for (const [name, c] of Object.entries(chains)) if (c.port === port) return name;
    }
  }
  if (/bscscan/i.test(text)) return "bsc";
  if (/arbiscan/i.test(text)) return "arbitrum";
  if (/basescan/i.test(text)) return "base";
  if (/polygonscan/i.test(text)) return "polygon";
  if (/optimistic\.etherscan|ops\.can/i.test(text)) return "optimism";
  if (/snowtrace|avascan|avax/i.test(text)) return "avalanche";
  return "mainnet";
}

function rpcUrlForChain(chainName) {
  // Prefer explicit env, then chain-specific, never hardcode keys into source.
  if (process.env.ETH_RPC_URL) return process.env.ETH_RPC_URL;
  if (process.env.RPC_URL) return process.env.RPC_URL;
  const key = `${chainName.toUpperCase()}_RPC_URL`;
  if (process.env[key]) return process.env[key];
  if (chainName === "mainnet" && process.env.MAINNET_RPC_URL) return process.env.MAINNET_RPC_URL;
  if (chainName === "bsc" && process.env.BSC_RPC_URL) return process.env.BSC_RPC_URL;
  return null;
}

async function rpcCall(rpcUrl, method, params) {
  const res = await fetch(rpcUrl, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params })
  });
  const json = await res.json();
  if (json.error) throw new Error(`RPC ${method}: ${json.error.message || JSON.stringify(json.error)}`);
  return json.result;
}

/**
 * Resolve attack-tx envelope: local cache first, then optional RPC.
 * Caches result as attack_tx.json in the hack folder for fully offline rebuilds.
 */
async function resolveAttackTx(hackDir, txHash, chainName) {
  const cachePaths = [
    path.join(hackDir, "attack_tx.json"),
    path.join(hackDir, "tx.json")
  ];
  for (const p of cachePaths) {
    if (!fs.existsSync(p)) continue;
    const j = JSON.parse(fs.readFileSync(p, "utf8"));
    if (j && (j.hash || j.txHash) && (j.from || j.result?.from)) {
      console.log(`[build-poc] using cached tx envelope ${p}`);
      return normalizeTxJson(j, txHash);
    }
  }

  const rpc = rpcUrlForChain(chainName);
  if (!rpc) {
    fail(
      `attack-tx envelope missing for ${txHash}.\n` +
        `  Add ${path.join(hackDir, "attack_tx.json")} (eth_getTransactionByHash result),\n` +
        `  or set ETH_RPC_URL / ${chainName.toUpperCase()}_RPC_URL to fetch it once\n` +
        `  (it will be cached as attack_tx.json for offline rebuilds).`
    );
  }

  console.log(`[build-poc] fetching tx ${txHash.slice(0, 12)}… via RPC`);
  const raw = await rpcCall(rpc, "eth_getTransactionByHash", [txHash]);
  if (!raw) fail(`RPC returned null for eth_getTransactionByHash(${txHash})`);
  const block = await rpcCall(rpc, "eth_getBlockByNumber", [raw.blockNumber, false]);
  const envelope = {
    hash: raw.hash,
    from: raw.from,
    to: raw.to,
    input: raw.input,
    value: raw.value,
    gas: raw.gas,
    gasPrice: raw.gasPrice || raw.maxFeePerGas,
    blockNumber: raw.blockNumber,
    blockTimestamp: block?.timestamp
  };
  const outPath = path.join(hackDir, "attack_tx.json");
  fs.writeFileSync(outPath, JSON.stringify(envelope, null, 2) + "\n");
  console.log(`[build-poc] cached tx envelope → ${outPath}`);
  return normalizeTxJson(envelope, txHash);
}

function normalizeTxJson(j, fallbackHash) {
  // Accept raw eth_getTransactionByHash result or our slim envelope.
  const r = j.result && typeof j.result === "object" ? j.result : j;
  return {
    hash: (r.hash || r.txHash || fallbackHash || "").toLowerCase(),
    from: (r.from || "").toLowerCase(),
    to: r.to ? r.to.toLowerCase() : null,
    input: r.input || r.data || "0x",
    value: r.value || "0x0",
    gas: r.gas,
    gasPrice: r.gasPrice || r.maxFeePerGas,
    blockNumber: r.blockNumber,
    blockTimestamp: r.blockTimestamp || r.timestamp
  };
}

function anvilAccountsToPoc(anvilState) {
  const accounts = {};
  for (const [addr, acc] of Object.entries(anvilState.accounts || {})) {
    accounts[addr.toLowerCase()] = {
      nonce: typeof acc.nonce === "number" ? acc.nonce : parseInt(acc.nonce, 10) || 0,
      balance: acc.balance,
      // Normalize anvil EOA sentinel 0x00 → empty code (analyzer/putCode contract trap).
      code: acc.code === "0x00" ? "0x" : acc.code || "0x",
      storage: acc.storage || {}
    };
  }
  return accounts;
}

function labelsFromSources(hackDir) {
  const labels = {};
  const sourcesRoot = path.join(hackDir, "sources");
  if (!fs.existsSync(sourcesRoot)) return labels;
  for (const dir of fs.readdirSync(sourcesRoot)) {
    const metaPath = path.join(sourcesRoot, dir, "_meta.json");
    if (!fs.existsSync(metaPath)) continue;
    try {
      const meta = JSON.parse(fs.readFileSync(metaPath, "utf8"));
      if (meta.address && meta.name) labels[String(meta.address).toLowerCase()] = meta.name;
    } catch {
      /* ignore */
    }
  }
  return labels;
}

async function buildContractSources(hackDir, chainId, accounts) {
  const contractSources = {};
  const addresses = Object.keys(accounts).filter((a) => (accounts[a].code || "0x").length > 200);
  const cap = parseInt(process.env.MAX_CONTRACT_SOURCE_BYTES || "10000000", 10);
  let usedBytes = 0;

  for (const address of addresses) {
    const onchain = accounts[address].code;
    let src;
    try {
      src = await fetchVerifiedSource(chainId, address, hackDir);
    } catch (e) {
      console.warn(`[build-poc] ${address}: source load failed — ${e.message?.slice(0, 100)}`);
      continue;
    }
    if (!src) {
      console.warn(`[build-poc] ${address}: no local/verified source — bytecode-only`);
      continue;
    }
    if (src.proxy) {
      console.warn(`[build-poc] ${src.contractName} @ ${address}: proxy — bytecode-only`);
      continue;
    }
    if (!src.compilerVersion || String(src.compilerVersion).startsWith("vyper:")) {
      console.warn(`[build-poc] ${src.contractName || address}: unsupported compiler — bytecode-only`);
      continue;
    }

    let matched;
    try {
      matched = await compileAndMatch({
        version: src.compilerVersion,
        optimizer: src.optimizer,
        runs: src.runs,
        evmVersion: src.evmVersion,
        libraries: src.libraries,
        remappings: src.remappings,
        metadata: src.metadata,
        debug: src.debug,
        sources: src.sources,
        contractName: src.contractName,
        onchainCodeHex: onchain
      });
    } catch (e) {
      console.warn(`[build-poc] ${src.contractName} @ ${address}: compile failed — ${e.message?.slice(0, 100)}`);
      continue;
    }
    if (!matched) {
      console.warn(`[build-poc] ${src.contractName} @ ${address}: bytecode did not match — bytecode-only`);
      continue;
    }

    const { files, pcToLine } = buildPcToLine(
      matched.deployedObject,
      matched.sourceMap,
      matched.idToPath,
      (p) => matched.sources[p]
    );
    const mapped = Object.keys(pcToLine).length;
    if (mapped === 0) continue;
    const primaryFile =
      Object.keys(files).find((f) => new RegExp(`contract\\s+${src.contractName}\\b`).test(files[f])) ||
      Object.keys(files)[0];
    const viewBytes = JSON.stringify({ files, pcToLine }).length;
    if (usedBytes + viewBytes > cap) {
      console.warn(`[build-poc] ${src.contractName} @ ${address}: source budget exceeded — bytecode-only`);
      continue;
    }
    usedBytes += viewBytes;
    contractSources[address] = {
      contractName: src.contractName,
      primaryFile,
      files,
      pcToLine,
      compiler: src.compilerVersion,
      evmVersion: matched.evmVersion,
      viaIR: matched.viaIR
    };
    console.log(`[build-poc] source view: ${src.contractName} @ ${address} — ${mapped} pcs`);
  }
  return contractSources;
}

async function buildOne(folderArg) {
  const folder = resolveFolder(folderArg);
  const slug = folderToSlug(folder);
  const hackDir = path.join(REGISTRY_DIR, folder);
  console.log(`[build-poc] folder=${folder} slug=${slug}`);
  console.log(`[build-poc] registry=${REGISTRY_DIR}`);

  const anvilPath = path.join(hackDir, "anvil_state.json");
  const anvilState = JSON.parse(fs.readFileSync(anvilPath, "utf8"));
  const accounts = anvilAccountsToPoc(anvilState);

  const text = collectFolderText(hackDir);
  const chains = loadChains();
  const chainName = detectChain(text, chains);
  const chainId = chains[chainName]?.chainId ?? 1;
  console.log(`[build-poc] chain=${chainName} chainId=${chainId}`);

  const txHash = extractAttackTxHash(text);
  if (!txHash) {
    fail(
      `could not find an attack tx hash in ${folder} (test/*.sol or *.md).\n` +
        `  Add a comment like: // Attack tx: https://etherscan.io/tx/0x…\n` +
        `  or place attack_tx.json with a full eth_getTransactionByHash result.`
    );
  }
  console.log(`[build-poc] attack tx=${txHash}`);

  const tx = await resolveAttackTx(hackDir, txHash, chainName);

  // Block: prefer anvil dump (the offline fork state the replay uses). Number /
  // timestamp as decimal strings, matching the analyzer native format.
  const anvilBlockNum = BigInt(anvilState.block.number).toString();
  const anvilTs = BigInt(anvilState.block.timestamp).toString();
  const block = {
    number: anvilBlockNum,
    timestamp: anvilTs
  };
  if (anvilState.block.basefee != null && anvilState.block.basefee !== 0) {
    block.baseFeePerGas =
      typeof anvilState.block.basefee === "string"
        ? anvilState.block.basefee
        : "0x" + BigInt(anvilState.block.basefee).toString(16);
  }

  const labels = labelsFromSources(hackDir);
  const contractSources = await buildContractSources(hackDir, chainId, accounts);

  const poc = {
    kind: POC_KIND,
    version: POC_VERSION,
    meta: {
      title: slug,
      txHash: tx.hash,
      chainId,
      network: chainName,
      createdAt: new Date().toISOString(),
      generatedBy: "evm-hack-registry/_shared/build-poc"
    },
    chainId,
    tx: {
      hash: tx.hash,
      from: tx.from,
      to: tx.to,
      input: tx.input,
      value: tx.value || "0x0",
      gas: tx.gas,
      gasPrice: tx.gasPrice
    },
    block,
    accounts,
    labels,
    contractSources,
    vulnerability: null,
    story: []
  };

  const outPath = path.join(hackDir, `${slug}.json`);
  fs.writeFileSync(outPath, JSON.stringify(poc));
  const sizeKb = (fs.statSync(outPath).size / 1024).toFixed(1);
  console.log(
    `[build-poc] wrote ${outPath} (${sizeKb} KB, ${Object.keys(accounts).length} accounts, ${Object.keys(contractSources).length} contractSources)`
  );
  console.log(`[build-poc] vulnerability/story left empty — mark them in the analyzer UI`);
  return outPath;
}

function parseArgs(argv) {
  const folders = [];
  for (const a of argv) {
    if (a === "--help" || a === "-h") {
      console.log(`Usage: node build.mjs <folder-or-slug> [...]

Build a native evm-hack-analyzer POC JSON from a registry slug folder.
No per-hack configs. Works for any folder that has anvil_state.json.

Arguments:
  folder-or-slug   e.g. 2017-07-Parity_first_hack_exp  or  2017-07-Parity_first_hack

Environment:
  HACKS_REGISTRY_DIR   Registry root (default: two levels above this script)
  ETH_RPC_URL          Optional JSON-RPC URL to fetch attack_tx when not cached
  <CHAIN>_RPC_URL      e.g. MAINNET_RPC_URL, BSC_RPC_URL
  SOURCE_CACHE_DIR     Optional Etherscan response cache for source maps
  ETHERSCAN_API_KEY    Optional online source fetch when local sources incomplete
  MAX_CONTRACT_SOURCE_BYTES  Cap embedded source maps (default 10_000_000)

Output:
  <registry>/<folder>/<slug>.json
  <registry>/<folder>/attack_tx.json   (created on first RPC fetch)

The JSON is a native analyzer POC (kind=evm-hack-analyzer-poc) with empty
vulnerability/story. Open it in the analyzer UI to mark those, then re-export.
`);
      process.exit(0);
    }
    if (!a.startsWith("-")) folders.push(a);
  }
  return folders;
}

const folders = parseArgs(process.argv.slice(2));
if (!folders.length) {
  console.error("[build-poc] pass at least one folder/slug (see --help)");
  process.exit(1);
}

let failed = 0;
for (const f of folders) {
  try {
    console.log(`\n[build-poc] ===== ${f} =====`);
    await buildOne(f);
  } catch (e) {
    failed++;
    console.error(`[build-poc] ${f}: FAILED — ${e.message || e}`);
  }
}
console.log(`[build-poc] done: ${folders.length - failed}/${folders.length} succeeded`);
if (failed) process.exit(1);
