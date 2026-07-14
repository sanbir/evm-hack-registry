// Load verified contract source for offline (or optional online) compilation.
//
// Resolution order per (chainId, address):
//   1. SOURCE_CACHE_DIR / .source-cache  — full Etherscan getsourcecode JSON
//      (chainId-0xaddr.json), same shape as crypto-training's scripts/.source-cache
//   2. <hackDir>/sources/*/_etherscan.json — per-contract full response in the
//      registry folder
//   3. <hackDir>/sources/*/_meta.json + *.sol — reconstructed from fetch_sources.sh
//      offline dump (limited settings; matching may fail for complex contracts)
//   4. Etherscan V2 API — ONLY if ETHERSCAN_API_KEY (or ETHERSCAN_API_KEYS) is set
//
// No API keys or RPC URLs are hardcoded. Online fetch is optional.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const DEFAULT_CACHE_DIR = path.join(path.dirname(__filename), "..", ".source-cache");

const inFlight = new Map();

function cacheDir() {
  return process.env.SOURCE_CACHE_DIR || DEFAULT_CACHE_DIR;
}

function readJsonSafe(file) {
  if (!fs.existsSync(file)) return null;
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    try {
      fs.rmSync(file, { force: true });
    } catch {
      /* ignore */
    }
    return null;
  }
}

function writeCacheAtomic(cacheFile, data) {
  fs.mkdirSync(path.dirname(cacheFile), { recursive: true });
  const tmp = `${cacheFile}.tmp-${process.pid}-${Math.random().toString(36).slice(2)}`;
  fs.writeFileSync(tmp, data);
  fs.renameSync(tmp, cacheFile);
}

// Etherscan SourceCode field comes in three shapes.
function parseSources(sourceCode, contractName) {
  const trimmed = String(sourceCode || "").trim();
  if (!trimmed) return { sources: {}, settings: null };

  if (trimmed.startsWith("{{")) {
    const inner = JSON.parse(trimmed.slice(1, -1));
    const sources = {};
    for (const [p, v] of Object.entries(inner.sources || {})) {
      sources[p] = typeof v === "string" ? v : v.content;
    }
    return { sources, settings: inner.settings || null };
  }

  if (trimmed.startsWith("{")) {
    try {
      const obj = JSON.parse(trimmed);
      if (obj.sources && typeof obj.sources === "object") {
        const sources = {};
        for (const [p, v] of Object.entries(obj.sources)) {
          sources[p] = typeof v === "string" ? v : v.content;
        }
        return { sources, settings: obj.settings || null };
      }
      const sources = {};
      for (const [p, v] of Object.entries(obj)) {
        sources[p] = typeof v === "string" ? v : v.content;
      }
      if (Object.keys(sources).length > 0) return { sources, settings: null };
    } catch {
      /* fall through */
    }
  }

  return { sources: { [`${contractName || "Contract"}.sol`]: sourceCode }, settings: null };
}

function parseLibraries(libraryField, settingsFromJson) {
  if (settingsFromJson && settingsFromJson.libraries) return settingsFromJson.libraries;
  const libs = {};
  const flat = (libraryField || "").trim();
  if (flat) {
    for (const part of flat.split(";")) {
      const [name, addr] = part.split(":");
      if (name && addr) {
        const clean = addr.trim().toLowerCase();
        libs[name.trim()] = clean.startsWith("0x") ? clean : "0x" + clean;
      }
    }
  }
  return Object.keys(libs).length ? libs : undefined;
}

/** Normalize a full Etherscan getsourcecode result[0] into the compile descriptor. */
export function normalizeEtherscanResult(r, address) {
  if (!r || !r.SourceCode) return null;
  const { sources, settings } = parseSources(r.SourceCode, r.ContractName);
  const evmRaw = (r.EVMVersion || "").trim();
  const viaIR = settings && typeof settings.viaIR === "boolean" ? settings.viaIR : null;
  const remappings = settings && Array.isArray(settings.remappings) ? settings.remappings : undefined;
  const metadata = settings && settings.metadata && typeof settings.metadata === "object" ? settings.metadata : undefined;
  const debug = settings && settings.debug && typeof settings.debug === "object" ? settings.debug : undefined;
  const parsedRuns = parseInt(r.Runs, 10);
  return {
    address: address.toLowerCase(),
    contractName: r.ContractName,
    compilerVersion: r.CompilerVersion,
    optimizer: String(r.OptimizationUsed) === "1",
    runs: Number.isFinite(parsedRuns) ? parsedRuns : 200,
    evmVersion: !evmRaw || evmRaw.toLowerCase() === "default" ? null : evmRaw.toLowerCase(),
    viaIR,
    libraries: parseLibraries(r.Library, settings),
    remappings,
    metadata,
    debug,
    sources,
    proxy: String(r.Proxy) === "1",
    implementation: r.Implementation || ""
  };
}

/** Reverse fetch_sources.sh path flattening: contracts_Foo.sol → contracts/Foo.sol */
function unflattenPath(name) {
  // Keep extension; replace internal underscores that look like path seps.
  // Heuristic: only first segments before last underscore-group of identifier.
  // Safer approach used by fetch: name.replace("/", "_"). We reverse every `_`
  // that sits between alnum segments that look like directories.
  if (!name.endsWith(".sol") && !name.endsWith(".vy")) return name;
  // Common patterns: contracts_uniswapv2_libraries_SafeMath.sol
  // Prefer replacing `_` with `/` when both sides look like path components.
  const base = name;
  // Don't unflatten if it already has a slash.
  if (base.includes("/")) return base;
  // Split on `_` and rejoin as path when there are multiple parts.
  const parts = base.replace(/\.sol$/, "").replace(/\.vy$/, "").split("_");
  if (parts.length <= 1) return name;
  const ext = name.endsWith(".vy") ? ".vy" : ".sol";
  // Last part is the file stem; join prefixes as dirs.
  const file = parts[parts.length - 1] + ext;
  const dirs = parts.slice(0, -1);
  return dirs.length ? dirs.join("/") + "/" + file : file;
}

/**
 * Load from registry sources/<Name>_<addr6>/ offline dump.
 * Returns the same shape as normalizeEtherscanResult, or null.
 */
export function loadLocalRegistrySource(hackDir, address) {
  const sourcesRoot = path.join(hackDir, "sources");
  if (!fs.existsSync(sourcesRoot)) return null;
  const want = address.toLowerCase();
  const want6 = want.slice(2, 8);

  for (const dir of fs.readdirSync(sourcesRoot)) {
    const dirPath = path.join(sourcesRoot, dir);
    if (!fs.statSync(dirPath).isDirectory()) continue;

    // Full etherscan dump (preferred when present)
    const ethPath = path.join(dirPath, "_etherscan.json");
    const eth = readJsonSafe(ethPath);
    if (eth) {
      const addr = (eth.address || eth.Address || "").toLowerCase();
      if (addr === want || dir.toLowerCase().endsWith("_" + want6)) {
        // Either full getsourcecode result, or already-normalized
        if (eth.SourceCode !== undefined) {
          const n = normalizeEtherscanResult(eth, want);
          if (n) return n;
        }
        if (eth.sources && eth.compilerVersion) return { ...eth, address: want };
      }
    }

    const metaPath = path.join(dirPath, "_meta.json");
    const meta = readJsonSafe(metaPath);
    if (!meta) continue;
    const metaAddr = String(meta.address || "").toLowerCase();
    if (metaAddr !== want && !dir.toLowerCase().endsWith("_" + want6)) continue;

    // Reconstruct sources map from .sol/.vy files
    const sources = {};
    for (const f of fs.readdirSync(dirPath)) {
      if (f.startsWith("_")) continue;
      if (!f.endsWith(".sol") && !f.endsWith(".vy")) continue;
      const content = fs.readFileSync(path.join(dirPath, f), "utf8");
      sources[unflattenPath(f)] = content;
      // Also keep flat name so remapping-less compiles can find single-file layouts
      if (unflattenPath(f) !== f) sources[f] = content;
    }
    if (Object.keys(sources).length === 0) continue;

    const parsedRuns = parseInt(meta.runs, 10);
    return {
      address: want,
      contractName: meta.name || "Contract",
      compilerVersion: meta.compiler,
      optimizer: String(meta.optimizer) === "1",
      runs: Number.isFinite(parsedRuns) ? parsedRuns : 200,
      evmVersion: null,
      viaIR: null,
      libraries: undefined,
      remappings: undefined,
      metadata: undefined,
      debug: undefined,
      sources,
      proxy: String(meta.proxy) === "1",
      implementation: meta.implementation || ""
    };
  }
  return null;
}

function resolveApiKey() {
  if (process.env.ETHERSCAN_API_KEYS) {
    const keys = process.env.ETHERSCAN_API_KEYS.trim().split(/\s+/).filter(Boolean);
    if (keys.length) return keys[Math.floor(Math.random() * keys.length)];
  }
  if (process.env.ETHERSCAN_API_KEY) return process.env.ETHERSCAN_API_KEY.trim();
  return null;
}

async function fetchGetSourceCode(chainId, address, apiKey, attempts = 5) {
  const url =
    `https://api.etherscan.io/v2/api?chainid=${chainId}` +
    `&module=contract&action=getsourcecode&address=${address}&apikey=${apiKey}`;
  let lastErr;
  for (let i = 0; i < attempts; i++) {
    try {
      const res = await fetch(url);
      const json = await res.json();
      if (json.status === "1" && Array.isArray(json.result) && json.result[0]) {
        return json.result[0];
      }
      const note = `${json.message || ""} ${typeof json.result === "string" ? json.result : ""}`.toLowerCase();
      const rateLimited = note.includes("rate limit") || note.includes("max ") || note.includes("too many");
      if (!rateLimited) {
        throw new Error(`Etherscan getsourcecode failed for ${address}: ${json.message || "unknown"}`);
      }
      lastErr = new Error(`rate limited for ${address}: ${json.message || json.result}`);
    } catch (e) {
      lastErr = e;
      if (typeof e?.message === "string" && e.message.startsWith("Etherscan getsourcecode failed")) throw e;
    }
    await new Promise((r) => setTimeout(r, 400 * 2 ** i));
  }
  throw lastErr || new Error(`Etherscan fetch failed for ${address}`);
}

/**
 * Fetch verified source. Offline-first; online only when API key is set.
 * @returns {Promise<object|null>} compile descriptor or null if unverified/unavailable
 */
export async function fetchVerifiedSource(chainId, address, hackDir) {
  const addr = address.toLowerCase();
  const key = `${chainId}-${addr}`;
  const cDir = cacheDir();
  const cacheFile = path.join(cDir, `${key}.json`);

  // 1. Disk cache (full Etherscan response)
  const cached = readJsonSafe(cacheFile);
  if (cached) {
    const n = normalizeEtherscanResult(cached, addr);
    if (n) return n;
  }

  // 2–3. Local registry sources
  if (hackDir) {
    const local = loadLocalRegistrySource(hackDir, addr);
    if (local) return local;
  }

  // 4. Online (optional) — disabled when BUILD_POC_OFFLINE=1 (set by build.mjs)
  if (process.env.BUILD_POC_OFFLINE === "1") return null;
  const apiKey = resolveApiKey();
  if (!apiKey) return null;

  if (inFlight.has(key)) return inFlight.get(key);
  const p = (async () => {
    const again = readJsonSafe(cacheFile);
    if (again) {
      const n = normalizeEtherscanResult(again, addr);
      if (n) return n;
    }
    const result0 = await fetchGetSourceCode(chainId, addr, apiKey);
    writeCacheAtomic(cacheFile, JSON.stringify(result0));
    return normalizeEtherscanResult(result0, addr);
  })().finally(() => inFlight.delete(key));
  inFlight.set(key, p);
  return p;
}
