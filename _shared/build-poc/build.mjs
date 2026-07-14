#!/usr/bin/env node
// Config-free offline builder: registry slug folder → crypto.training-compatible
// poc-data JSON (same shape as crypto-training/public/poc-data/<slug>.json).
//
// How crypto-training produces those files (scripts/build-poc-runner-data.mjs):
//   config (attacker, callScript|exploitContract, labels, expected, editorial)
//   + anvil_state.json
//   + forge artifact (optional)
//   + verified sources (Etherscan) → contractSources
//   → public/poc-data/<slug>.json  (PocRunnerData)
//
// This script does the same WITHOUT configs / Etherscan / RPC:
//   run_poc.sh --json -vvv  → callScript (raw calldata of depth-1 CALLs)
//   anvil_state.json        → accounts + block
//   sources/*               → contractSources (offline compile-match)
//   sources/*/_meta.json    → labels
//   vulnerability/story     → empty (mark later in the analyzer UI)
//
// Usage:
//   node build.mjs 2021-08-PolyNetwork_exp
//   node build.mjs 2018-04-BEC
//   HACKS_REGISTRY_DIR=/path/to/clone node build.mjs <folder> [...]
//
// Output: <folder>/<slug>.json   (PocRunnerData — loadable by evm-hack-analyzer)

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { decodeFunctionData } from "viem";
import { buildPcToLine } from "./lib/solidity-sourcemap.mjs";
import { compileAndMatch } from "./lib/compile-verified.mjs";
import { fetchVerifiedSource } from "./lib/source.mjs";

// Hard-offline: never hit Etherscan even if a key is in the environment.
// (crypto-training's builder uses Etherscan for contractSources; we use sources/.)
delete process.env.ETHERSCAN_API_KEY;
delete process.env.ETHERSCAN_API_KEYS;
process.env.BUILD_POC_OFFLINE = "1";

const __filename = fileURLToPath(import.meta.url);
const HERE = path.dirname(__filename);
const REGISTRY_DIR = process.env.HACKS_REGISTRY_DIR || path.resolve(HERE, "../..");
const CHAINS_CONF = path.join(HERE, "..", "run-poc", "chains.conf");
const RUN_POC_SH = path.join(HERE, "..", "run-poc", "run_poc.sh");

// Foundry cheatcode / well-known addresses to skip when extracting attack calls.
const SKIP_ADDRS = new Set([
  "0x7109709ecfa91a80626ff3989d68f67f5b1dd12d", // HEVM / Vm
  "0x000000000000000000636f6e736f6c652e6c6f67", // console
  "0x4e59b44847b379578588920ca78fbf26c0b4956c" // CREATE2 factory
]);
const FOUNDRY_DEFAULT_SENDER = "0x1804c8ab1f12e6bbf3894d4083f33e07309d1f38";

function fail(msg) {
  throw new Error(msg);
}

function loadChains() {
  const map = {};
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
  const candidates = [arg, arg.endsWith("_exp") ? arg : `${arg}_exp`, arg.replace(/_exp$/, "")];
  for (const c of candidates) {
    const p = path.join(REGISTRY_DIR, c);
    if (fs.existsSync(path.join(p, "anvil_state.json"))) return c;
  }
  fail(`no registry folder with anvil_state.json for "${arg}" under ${REGISTRY_DIR}`);
}

function folderToSlug(folder) {
  return folder.replace(/_exp$/, "");
}

function collectFolderText(hackDir) {
  let text = "";
  for (const root of [hackDir, path.join(hackDir, "test")]) {
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

function detectChain(text, chains) {
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
  if (/optimistic\.etherscan/i.test(text)) return "optimism";
  if (/snowtrace|avascan|avax/i.test(text)) return "avalanche";
  return "mainnet";
}

function anvilAccountsToPoc(anvilState) {
  const accounts = {};
  for (const [addr, acc] of Object.entries(anvilState.accounts || {})) {
    accounts[addr.toLowerCase()] = {
      nonce: typeof acc.nonce === "number" ? acc.nonce : parseInt(acc.nonce, 10) || 0,
      balance: acc.balance,
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

/** Parse the first complete top-level JSON object from forge --json stdout. */
function parseFirstJsonObject(stdout) {
  const i = stdout.indexOf("{");
  if (i < 0) return null;
  let depth = 0;
  let inStr = false;
  let esc = false;
  for (let j = i; j < stdout.length; j++) {
    const ch = stdout[j];
    if (inStr) {
      if (esc) esc = false;
      else if (ch === "\\") esc = true;
      else if (ch === '"') inStr = false;
      continue;
    }
    if (ch === '"') {
      inStr = true;
      continue;
    }
    if (ch === "{") depth++;
    else if (ch === "}") {
      depth--;
      if (depth === 0) {
        try {
          return JSON.parse(stdout.slice(i, j + 1));
        } catch {
          return null;
        }
      }
    }
  }
  return null;
}

/**
 * Run the offline forge harness. Writes forge --json to `outJsonPath` on disk
 * (traces can be hundreds of MB — never buffer them in Node).
 */
function runForgeLocal(folder, outJsonPath) {
  if (!fs.existsSync(RUN_POC_SH)) fail(`run_poc.sh not found at ${RUN_POC_SH}`);
  const timeoutSec = parseInt(process.env.FORGE_TIMEOUT_SEC || "600", 10);
  // --json alone omits call arenas. -vvv is enough for CALL/data (depth 1);
  // -vvvvv also dumps storage diffs and can be 100s of MB — avoid it.
  console.log(`[build-poc] running offline forge: run_poc.sh ${folder} --json -vvv`);
  const outFd = fs.openSync(outJsonPath, "w");
  const errPath = outJsonPath + ".stderr";
  const errFd = fs.openSync(errPath, "w");
  try {
    const res = spawnSync(RUN_POC_SH, [folder, "--json", "-vvv"], {
      stdio: ["ignore", outFd, errFd],
      timeout: timeoutSec * 1000,
      env: process.env
    });
    const ok = res.status === 0;
    if (!ok) {
      console.warn(`[build-poc] forge exited ${res.status}${res.error ? ` (${res.error.message})` : ""}`);
      const errTail = fs.existsSync(errPath) ? fs.readFileSync(errPath, "utf8").slice(-2000) : "";
      if (errTail) console.warn(errTail);
    }
    // Parse JSON from the on-disk file (stream-friendly enough via read+brace scan).
    let forgeJson = null;
    if (fs.existsSync(outJsonPath) && fs.statSync(outJsonPath).size > 2) {
      // For huge files, only need the structure — read fully for now with high heap;
      // if OOM, fall back to a shell python parse later.
      try {
        const raw = fs.readFileSync(outJsonPath, "utf8");
        forgeJson = parseFirstJsonObject(raw);
      } catch (e) {
        console.warn(`[build-poc] reading forge JSON failed: ${e.message?.slice(0, 120)}`);
      }
    }
    return { ok, forgeJson, status: res.status };
  } finally {
    fs.closeSync(outFd);
    fs.closeSync(errFd);
  }
}

/** Collect every Execution-arena node across successful non-setUp tests. */
function iterExecutionNodes(forgeJson) {
  const out = [];
  if (!forgeJson || typeof forgeJson !== "object") return out;
  for (const suite of Object.values(forgeJson)) {
    if (!suite?.test_results) continue;
    for (const [testName, result] of Object.entries(suite.test_results)) {
      if (/setUp/i.test(testName)) continue;
      const status = String(result.status || "").toLowerCase();
      if (status && status !== "success" && status !== "pass") {
        // In best-effort mode (ALLOW_FORGE_FAIL) we still try to harvest whatever
        // CALLs were emitted before a revert/kill — many PoCs "fail" the test
        // assertion on purpose or get killed mid-Execution.
        if (process.env.ALLOW_FORGE_FAIL !== "1") continue;
      }
      for (const tr of result.traces || []) {
        const label = tr[0];
        if (label === "Deployment" || label === "Setup") continue;
        for (const node of tr[1]?.arena || []) {
          out.push({ label, trace: node.trace || {} });
        }
      }
    }
  }
  return out;
}

/** Test contract address from the Deployment CREATE (Foundry harness). */
function extractTestContract(forgeJson) {
  if (!forgeJson || typeof forgeJson !== "object") return null;
  for (const suite of Object.values(forgeJson)) {
    if (!suite?.test_results) continue;
    for (const result of Object.values(suite.test_results)) {
      for (const tr of result.traces || []) {
        if (tr[0] !== "Deployment") continue;
        for (const node of tr[1]?.arena || []) {
          const t = node.trace || {};
          if (t.kind === "CREATE" && t.address) return String(t.address).toLowerCase();
        }
      }
    }
  }
  return null;
}

/**
 * From forge --json, extract the attack the same way crypto-training configs do:
 *   - callScript: depth-1 CALLs to pre-existing addresses (raw `data`, CT-compatible)
 *   - creates: depth-1 CREATEs during Execution (candidate exploit/helper contracts)
 *
 * CT hand-writes sig+args; we emit raw `data` (also accepted by recordExploit).
 */
function extractAttackFromForge(forgeJson) {
  const empty = {
    callScript: [],
    creates: [],
    testContract: null,
    attacker: null
  };
  if (!forgeJson || typeof forgeJson !== "object") return empty;

  const testContract = extractTestContract(forgeJson);
  const callScript = [];
  const creates = [];
  let preferredAttacker = null;

  for (const { label, trace: t } of iterExecutionNodes(forgeJson)) {
    const kind = t.kind;
    const depth = Number(t.depth);
    const to = (t.address || "").toLowerCase();
    const from = (t.caller || "").toLowerCase();
    const data = t.data || "0x";
    const valueWei =
      t.value && t.value !== "0x0" && t.value !== "0x" ? BigInt(t.value).toString() : undefined;

    // Depth-1 CREATE under the test body = "new Exploit()" style helper.
    if ((kind === "CREATE" || kind === "CREATE2") && depth === 1 && to) {
      creates.push({
        address: to,
        caller: from,
        initCode: data.startsWith("0x") ? data : `0x${data}`,
        valueWei,
        note: `${kind} depth1 from forge ${label || "Execution"}`
      });
      if (!preferredAttacker) preferredAttacker = from;
      continue;
    }

    if (kind !== "CALL" && kind !== "DELEGATECALL") continue;
    if (depth !== 1) continue;
    if (!to || SKIP_ADDRS.has(to)) continue;
    // Skip harness entry: DefaultSender → TestContract (invoke test function).
    if (from === FOUNDRY_DEFAULT_SENDER && testContract && to === testContract) continue;
    if ((!data || data === "0x") && !valueWei) continue;

    if (!preferredAttacker) preferredAttacker = from;
    callScript.push({
      caller: from,
      to,
      data: data.startsWith("0x") ? data : `0x${data}`,
      valueWei,
      record: true,
      note: `${kind} depth1 from forge ${label || "Execution"}`
    });
  }

  // Dedup consecutive identical CALL steps.
  const deduped = [];
  for (const step of callScript) {
    const prev = deduped[deduped.length - 1];
    if (prev && prev.to === step.to && prev.data === step.data && prev.caller === step.caller) continue;
    deduped.push(step);
  }

  return {
    callScript: deduped,
    creates,
    testContract,
    attacker: preferredAttacker || FOUNDRY_DEFAULT_SENDER
  };
}

/** Walk out/ for Foundry artifacts; match CREATE initcode to bytecode.object. */
function findArtifactForInitCode(hackDir, initCode) {
  const outDir = path.join(hackDir, "out");
  if (!fs.existsSync(outDir)) return null;
  const want = (initCode || "").toLowerCase();
  if (want.length < 10) return null;

  let best = null;
  for (const ent of fs.readdirSync(outDir, { withFileTypes: true })) {
    if (!ent.isDirectory() || ent.name === "build-info") continue;
    const dir = path.join(outDir, ent.name);
    for (const f of fs.readdirSync(dir)) {
      if (!f.endsWith(".json")) continue;
      let art;
      try {
        art = JSON.parse(fs.readFileSync(path.join(dir, f), "utf8"));
      } catch {
        continue;
      }
      const bc = (art.bytecode?.object || "").toLowerCase();
      if (!bc || bc === "0x") continue;
      // CREATE data is bytecode (+ optional ABI-encoded constructor args).
      if (want === bc || want.startsWith(bc)) {
        const name = f.replace(/\.json$/, "");
        // Prefer longer bytecode matches (more specific).
        if (!best || bc.length > best.bcLen) {
          best = {
            name,
            file: ent.name,
            abi: art.abi || [],
            bytecode: art.bytecode.object,
            runtimeBytecode: art.deployedBytecode?.object,
            methodIdentifiers: art.methodIdentifiers || {},
            bcLen: bc.length,
            initCode
          };
        }
      }
    }
  }
  return best;
}

/**
 * CT exploitContract mode: deploy a helper then call attackFunction.
 * When forge does `new Helper(); helper.attack(...)`, emit that shape so the
 * browser redeploys at a fresh address (CREATE address from forge is ephemeral).
 */
function resolveExploitContract(hackDir, creates, callScript) {
  if (!creates.length) return { exploitContract: null, callScript, helperContracts: null };

  // Match each CREATE to a forge artifact.
  const matched = [];
  for (const c of creates) {
    const art = findArtifactForInitCode(hackDir, c.initCode);
    if (!art) {
      console.warn(`[build-poc] CREATE ${c.address}: no matching out/ artifact — skipped`);
      continue;
    }
    matched.push({ create: c, art });
    console.log(`[build-poc] CREATE ${c.address} → artifact ${art.file}/${art.name}`);
  }
  if (!matched.length) return { exploitContract: null, callScript, helperContracts: null };

  // Addresses created in-Execution (not in anvil dump) — calls to them must go
  // through exploitContract/helpers, not callScript (address won't match redeploy).
  const createdAddrs = new Set(matched.map((m) => m.create.address));
  const externalScript = callScript.filter((s) => !createdAddrs.has(s.to));
  const internalCalls = callScript.filter((s) => createdAddrs.has(s.to));

  // Primary exploit = first CREATE that receives a depth-1 CALL, else first CREATE.
  let primary = matched[0];
  for (const m of matched) {
    if (internalCalls.some((s) => s.to === m.create.address)) {
      primary = m;
      break;
    }
  }

  const firstCall = internalCalls.find((s) => s.to === primary.create.address);
  let attackFunction = null;
  let attackArgs = [];
  let attackValueWei = null;
  if (firstCall) {
    attackValueWei = firstCall.valueWei || null;
    try {
      const decoded = decodeFunctionData({
        abi: primary.art.abi,
        data: firstCall.data
      });
      attackFunction = decoded.functionName;
      // BigInt → decimal string for JSON / coerceArgs.
      attackArgs = (decoded.args || []).map((a) =>
        typeof a === "bigint" ? a.toString() : Array.isArray(a) ? a.map((x) => (typeof x === "bigint" ? x.toString() : x)) : a
      );
      console.log(`[build-poc] exploitContract.attackFunction=${attackFunction}(${attackArgs.length} arg(s))`);
    } catch (e) {
      // Fall back to methodIdentifiers selector map.
      const sel = firstCall.data.slice(0, 10).toLowerCase();
      const methods = primary.art.methodIdentifiers || {};
      for (const [sig, id] of Object.entries(methods)) {
        if (`0x${id}`.toLowerCase() === sel || String(id).toLowerCase() === sel.slice(2)) {
          attackFunction = sig.replace(/\(.*/, "");
          console.log(`[build-poc] exploitContract.attackFunction=${attackFunction} (from methodIdentifiers; args empty)`);
          break;
        }
      }
      if (!attackFunction) {
        console.warn(`[build-poc] could not decode attack calldata: ${e.message?.slice(0, 80)}`);
      }
    }
  }

  // Full CREATE initcode as bytecode (includes ctor args) so redeploy matches.
  const exploitContract = {
    name: primary.art.name,
    abi: primary.art.abi,
    bytecode: primary.create.initCode,
    runtimeBytecode: primary.art.runtimeBytecode,
    constructorArgTypes: [],
    constructorArgValues: [],
    attackFunction,
    attackArgs,
    etchAt: null,
    attackValueWei
  };

  // Other CREATEs → helperContracts deployed before the primary.
  const helpers = matched
    .filter((m) => m !== primary)
    .map((m) => ({
      name: m.art.name,
      abi: m.art.abi,
      bytecode: m.create.initCode,
      constructorArgTypes: [],
      constructorArgValues: []
    }));

  // If we have an attackFunction, the internal CALL is covered; drop it from script.
  // Keep external callScript steps (rare combo: deploy helper + call victim directly).
  return {
    exploitContract: attackFunction || matched.length ? exploitContract : null,
    callScript: externalScript,
    helperContracts: helpers.length ? helpers : null
  };
}

/** Ensure every caller / attacker has an account entry (gas money, empty code). */
function ensureCallerAccounts(accounts, addrs) {
  const FUND = "0x56bc75e2d63100000"; // 100 ETH
  for (const a of addrs) {
    if (!a) continue;
    const key = a.toLowerCase();
    if (accounts[key]) continue;
    accounts[key] = {
      nonce: 0,
      balance: FUND,
      code: "0x",
      storage: {}
    };
    console.log(`[build-poc] injected account ${key} (100 ETH) — forge caller not in anvil dump`);
  }
  return accounts;
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
    // Match crypto-training contractSources shape (no compiler/evmVersion extras).
    contractSources[address] = {
      contractName: src.contractName,
      primaryFile,
      files,
      pcToLine
    };
    console.log(`[build-poc] source view: ${src.contractName} @ ${address} — ${mapped} pcs`);
  }
  return contractSources;
}

/**
 * Emit crypto.training PocRunnerData (docs/poc-data-json-standard.md).
 * Same top-level fields as scripts/build-poc-runner-data.mjs `out` object.
 */
function buildPocRunnerData({
  slug,
  folder,
  chainId,
  anvilState,
  accounts,
  labels,
  attacker,
  exploitContract,
  helperContracts,
  callScript,
  setup,
  contractSources
}) {
  // Preserve anvil's hex block fields (same as crypto-training build).
  const block = {
    number: anvilState.block.number,
    timestamp: anvilState.block.timestamp
  };

  return {
    slug,
    source: {
      registryFolder: folder,
      githubFolder: `https://github.com/sanbir/evm-hack-registry/tree/main/${folder}`
    },
    chainId,
    block,
    accounts,
    labels,
    attacker: (attacker || FOUNDRY_DEFAULT_SENDER).toLowerCase(),
    exploitContract: exploitContract || null,
    helperContracts: helperContracts || null,
    callScript: callScript && callScript.length > 0 ? callScript : null,
    setup: setup || null,
    gasLimits: null,
    codeOverrides: null,
    profitToken: {
      address: "0x0000000000000000000000000000000000000000",
      symbol: "ETH",
      decimals: 18,
      native: true
    },
    profitReceiver: null,
    expected: {
      profitWei: "0",
      label: "forge-local (score not asserted — mark profit later if needed)"
    },
    exploitSource: null,
    contractSources,
    vulnerability: null,
    story: []
  };
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

  // ── Offline forge run (no RPC) ──────────────────────────────────────────
  const tracePath = path.join(hackDir, "forge_trace.json");
  const { ok: forgeOk, forgeJson, status: forgeStatus } = runForgeLocal(folder, tracePath);
  const traceSize = fs.existsSync(tracePath) ? fs.statSync(tracePath).size : 0;
  if (traceSize > 0) {
    console.log(
      `[build-poc] forge JSON → ${tracePath} (${(traceSize / 1024 / 1024).toFixed(2)} MB)`
    );
  } else {
    console.warn(`[build-poc] no/empty forge trace at ${tracePath}`);
  }
  if (!forgeOk) {
    const killed = forgeStatus == null; // node: null status + signal means killed
    console.warn(
      `[build-poc] forge did not exit cleanly for ${folder} (status=${forgeStatus}, killed=${killed}). ` +
      `Proceeding with best-effort extraction (callScript may be empty or partial).`
    );
  }

  const extracted = extractAttackFromForge(forgeJson);
  let { callScript, creates, testContract, attacker } = extracted;
  console.log(
    `[build-poc] forge Execution: ${callScript.length} depth-1 CALL(s), ${creates.length} CREATE(s)` +
      (testContract ? ` (test ${testContract})` : "") +
      (attacker ? ` attacker=${attacker}` : "")
  );

  // Prefer CT exploitContract mode when the test deploys a helper (new X(); x.f()).
  const resolved = resolveExploitContract(hackDir, creates, callScript);
  const exploitContract = resolved.exploitContract;
  const helperContracts = resolved.helperContracts;
  callScript = resolved.callScript;

  if (!exploitContract && callScript.length === 0) {
    console.warn(
      `[build-poc] no attack surface found in Execution trace — empty callScript/exploitContract`
    );
  }
  if (exploitContract) {
    console.log(
      `[build-poc] mode=exploitContract (${exploitContract.name}` +
        (exploitContract.attackFunction ? `.${exploitContract.attackFunction}` : " deploy-only") +
        `)${callScript.length ? ` + callScript[${callScript.length}]` : ""}`
    );
  } else {
    console.log(`[build-poc] mode=callScript (${callScript.length} step(s))`);
  }

  // Callers that aren't in the anvil dump (e.g. forge test contract) need gas.
  ensureCallerAccounts(accounts, [
    attacker,
    testContract,
    ...callScript.map((s) => s.caller),
    ...(exploitContract ? [attacker] : [])
  ]);

  // setup.fundAttackerWei when CREATE/attack needs ETH the dump doesn't fund.
  let setup = null;
  const needWei = [];
  for (const c of creates) if (c.valueWei) needWei.push(BigInt(c.valueWei));
  if (exploitContract?.attackValueWei) needWei.push(BigInt(exploitContract.attackValueWei));
  for (const s of callScript) if (s.valueWei) needWei.push(BigInt(s.valueWei));
  if (needWei.length) {
    const total = needWei.reduce((a, b) => a + b, 0n);
    // Fund attacker with 2x needed (+ 10 ETH gas buffer).
    const fund = (total * 2n + 10n * 10n ** 18n).toString();
    setup = { fundAttackerWei: fund, steps: [] };
    console.log(`[build-poc] setup.fundAttackerWei=${fund}`);
  }

  const labels = labelsFromSources(hackDir);
  if (testContract) labels[testContract] = labels[testContract] || "ContractTest (forge)";
  if (attacker) labels[attacker] = labels[attacker] || "Attacker / test caller";
  if (exploitContract) {
    // Placeholder label; runtime address assigned at replay.
    labels["exploit"] = labels["exploit"] || exploitContract.name;
  }

  // Offline sources only (Etherscan keys stripped at process start).
  const contractSources = await buildContractSources(hackDir, chainId, accounts);

  const out = buildPocRunnerData({
    slug,
    folder,
    chainId,
    anvilState,
    accounts,
    labels,
    attacker,
    exploitContract,
    helperContracts,
    callScript,
    setup,
    contractSources
  });

  // Best-effort diagnostic for offline runs that hit resource limits or PoC reverts.
  // Analyzers that only care about the standard PocRunnerData fields will ignore it.
  if (!forgeOk) {
    out._build = {
      forgeOk: false,
      note: "forge/anvil did not complete cleanly (often OOM kill on large state or PoC revert). callScript may be partial."
    };
  }

  const outPath = path.join(hackDir, `${slug}.json`);
  // Minified JSON — same as crypto-training build-poc-runner-data.mjs
  fs.writeFileSync(outPath, JSON.stringify(out));
  const sizeKb = (fs.statSync(outPath).size / 1024).toFixed(1);
  console.log(
    `[build-poc] wrote ${outPath} (${sizeKb} KB, ${Object.keys(accounts).length} accounts, ` +
      `${Object.keys(contractSources).length} contractSources, ` +
      `callScript=${callScript.length}, exploit=${exploitContract ? exploitContract.name : "null"}, forgeOk=${forgeOk})`
  );
  console.log(`[build-poc] format=PocRunnerData (crypto.training poc-data compatible); vulnerability/story empty`);
  return outPath;
}

function parseArgs(argv) {
  const folders = [];
  for (const a of argv) {
    if (a === "--help" || a === "-h") {
      console.log(`Usage: node build.mjs <folder-or-slug> [...]

Build a crypto.training-compatible poc-data JSON (PocRunnerData) from a registry
slug folder. Fully offline — same fields as crypto-training/public/poc-data/*.json.

Sources of data (mirrors crypto-training's build-poc-runner-data.mjs offline):
  anvil_state.json     → accounts, block
  run_poc.sh --json    → callScript OR exploitContract (from forge CREATE+CALL)
  sources/             → contractSources (offline compile-match; NO Etherscan)
  sources/*/_meta.json → labels
  vulnerability/story  → null / [] (mark later in the UI)

Arguments:
  folder-or-slug   e.g. 2021-08-PolyNetwork_exp  or  2018-04-BEC

Environment:
  HACKS_REGISTRY_DIR        Registry root (default: two levels above this script)
  FORGE_TIMEOUT_SEC         Per-slug forge timeout (default 600)
  ALLOW_FORGE_FAIL=1        Still emit JSON if forge exits non-zero
  MAX_CONTRACT_SOURCE_BYTES Cap embedded source maps (default 10_000_000)

Output:
  <registry>/<folder>/<slug>.json        PocRunnerData bundle
  <registry>/<folder>/forge_trace.json   forge --json dump
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
