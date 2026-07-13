// Compile a verified contract with its EXACT settings (solc version, optimizer,
// runs, evmVersion, libraries) and confirm the produced runtime bytecode matches
// the on-chain deployed code. On a match, solc's deployedBytecode.sourceMap is a
// valid source map for the on-chain code, so we can highlight that contract's
// real Solidity line-by-line while stepping through it.
//
// Matching is exact modulo three never-executed regions:
//   1. the trailing CBOR metadata (differs by IPFS/bzzr hash; all solc eras),
//   2. immutable slots (zeroed in compiled output, filled on-chain) — masked
//      using solc's immutableReferences,
//   3. embedded CBOR metadata inside another contract's creation bytecode that
//      THIS contract copies as literal CREATE2 init-code data (e.g. Gnosis
//      Safe's ProxyFactory embedding `type(Proxy).creationCode`) — masked only
//      when both sides independently parse as a well-formed CBOR map at the
//      same offset, see maskEmbeddedMetadata.
//
// solc versions are downloaded on demand via loadRemoteVersion (build-time only;
// not part of the Netlify build — the produced JSON is committed).

import solcMod from "solc";

const versionCache = new Map();

function loadSolc(version) {
  if (versionCache.has(version)) return versionCache.get(version);
  const p = new Promise((resolve, reject) => {
    solcMod.loadRemoteVersion(version, (err, solc) => (err ? reject(err) : resolve(solc)));
  });
  versionCache.set(version, p);
  return p;
}

// Strip the trailing CBOR metadata using its 2-byte big-endian length suffix
// (works across all solc eras: bzzr0/bzzr1/ipfs). Only strips when the byte
// preceding the metadata is a CBOR map header (0xa1/0xa2/0xa3) — otherwise
// leaves the code untouched. 0xa3 (map-of-3) appears when a contract uses
// `pragma experimental ABIEncoderV2;` — solc ~0.5.x adds an extra
// `"experimental": true` key alongside the usual hash + compiler-version keys
// (e.g. the legacy iEarn/yearn yTokens: yUSDT/yDAI/yUSDC/yTUSD).
function stripMetadata(hex) {
  if (hex.length < 6) return hex;
  const metaLen = parseInt(hex.slice(-4), 16); // bytes
  if (!Number.isFinite(metaLen) || metaLen <= 0) return hex;
  const totalHex = (metaLen + 2) * 2;
  if (totalHex >= hex.length) return hex;
  const start = hex.length - totalHex;
  const head = hex.slice(start, start + 2);
  if (head === "a1" || head === "a2" || head === "a3") return hex.slice(0, start);
  return hex;
}

// Detect embedded, never-executed CBOR metadata blobs. Some factory contracts
// (e.g. Gnosis Safe's ProxyFactory, which embeds `type(Proxy).creationCode` as
// literal CREATE2 init-code data) copy ANOTHER contract's full creation
// bytecode into their own runtime code as inert data. That embedded blob
// carries its OWN CBOR metadata (source hash), which — unlike the outer
// trailing metadata `stripMetadata` already removes — sits INSIDE the code
// region at a byte offset, not at the very end. It is still never executed
// (copied as data, never run as opcodes), so a hash mismatch there doesn't
// reflect a real functional difference. `findEmbeddedMetadataSpans` locates
// candidate spans by parsing the same CBOR map shape solc emits (byte-string
// values for the hash, text-string keys for "bzzr0"/"bzzr1"/"ipfs"/"solc").
function tryParseCborMetadataAt(bytes, start, mapLen) {
  if (mapLen === 0) return null;
  let i = start + 1;
  for (let entry = 0; entry < mapLen; entry++) {
    if (i >= bytes.length) return null;
    const keyHeader = bytes[i];
    if (keyHeader < 0x60 || keyHeader > 0x77) return null; // CBOR text string, len 0-23
    i += 1 + (keyHeader - 0x60);
    if (i >= bytes.length) return null;
    const valHeader = bytes[i];
    if (valHeader >= 0x40 && valHeader <= 0x57) {
      i += 1 + (valHeader - 0x40); // CBOR byte string, single-byte length header
    } else if (valHeader === 0x58) {
      if (i + 1 >= bytes.length) return null;
      i += 2 + bytes[i + 1]; // CBOR byte string, 1-byte length follows
    } else {
      return null; // not a value shape solc's metadata encoder emits
    }
    if (i > bytes.length) return null;
  }
  return [start, i];
}

function findEmbeddedMetadataSpans(hexOrBytes) {
  const bytes = Buffer.isBuffer(hexOrBytes) ? hexOrBytes : Buffer.from(hexOrBytes, "hex");
  const spans = [];
  let i = 0;
  while (i < bytes.length) {
    const b0 = bytes[i];
    if (b0 === 0xa1 || b0 === 0xa2 || b0 === 0xa3) {
      const span = tryParseCborMetadataAt(bytes, i, b0 & 0x0f);
      if (span) {
        spans.push(span);
        i = span[1];
        continue;
      }
    }
    i++;
  }
  return spans;
}

// Mask any embedded metadata spans that BOTH sides independently parse as a
// well-formed CBOR map at the SAME offset+length — never based on one side
// alone, so a genuine functional difference elsewhere can't be masked away.
function maskEmbeddedMetadata(aHex, bHex) {
  if (aHex.length !== bHex.length) return [aHex, bHex];
  const aSpans = findEmbeddedMetadataSpans(aHex);
  if (!aSpans.length) return [aHex, bHex];
  const aBytes = Buffer.from(aHex, "hex");
  const bBytes = Buffer.from(bHex, "hex");
  for (const [s, e] of aSpans) {
    if (bBytes[s] !== aBytes[s]) continue;
    const bSpan = tryParseCborMetadataAt(bBytes, s, aBytes[s] & 0x0f);
    if (bSpan && bSpan[1] === e) {
      for (let k = s; k < e; k++) {
        aBytes[k] = 0;
        bBytes[k] = 0;
      }
    }
  }
  return [aBytes.toString("hex"), bBytes.toString("hex")];
}

// Zero out immutable byte ranges so compiled (zeros) and on-chain (real values)
// compare equal. immutableReferences: { "<astId>": [{start, length}, ...] }.
function maskImmutables(hex, immutableReferences) {
  if (!immutableReferences || Object.keys(immutableReferences).length === 0) return hex;
  const bytes = Buffer.from(hex, "hex");
  for (const refs of Object.values(immutableReferences)) {
    for (const { start, length } of refs) {
      for (let i = start; i < start + length && i < bytes.length; i++) bytes[i] = 0;
    }
  }
  return bytes.toString("hex");
}

function versionTuple(v) {
  const m = /v?(\d+)\.(\d+)\.(\d+)/.exec(v);
  return m ? [+m[1], +m[2], +m[3]] : [0, 0, 0];
}

// evmVersion candidates to try, given the declared one (or null = "Default").
// evmVersion selection only exists since solc 0.4.21; older versions must omit it.
function evmVersionCandidates(declared, version) {
  const [maj, min, patch] = versionTuple(version);
  const supportsEvmVersion = maj > 0 || min > 4 || (min === 4 && patch >= 21);
  if (!supportsEvmVersion) return [undefined];
  if (declared) return [declared, undefined];
  // "Default": try omitting first (solc picks its per-version default), then a
  // spread of historical defaults in case the on-chain build pinned one.
  return [undefined, "istanbul", "petersburg", "constantinople", "byzantium", "berlin", "london", "paris", "shanghai"];
}

// viaIR candidates to try. Etherscan's flat getsourcecode response has no viaIR
// field, so it's usually unknown; 0.8.13+ single-file verifications frequently
// used the IR pipeline, which produces entirely different bytecode. Try the
// non-IR path first (most common), then IR. If a standard-json verification told
// us the real value, honor it first.
function viaIRCandidates(declaredViaIR, version) {
  const [maj, min, patch] = versionTuple(version);
  const supportsViaIR = maj > 0 || min > 8 || (min === 8 && patch >= 13);
  if (!supportsViaIR) return [false];
  if (declaredViaIR === true) return [true, false];
  if (declaredViaIR === false) return [false, true];
  return [false, true];
}

function buildIdToPath(outputSources) {
  const map = {};
  let anyId = false;
  for (const [p, v] of Object.entries(outputSources || {})) {
    if (typeof v?.id === "number") {
      map[v.id] = p;
      anyId = true;
    }
  }
  // solc < 0.5 (e.g. 0.4.9) does not emit `sources[path].id` in standard-JSON
  // output, yet the source map still references file indices. Fall back to
  // positional ids (0,1,2,... in sources-object order = solc's file index).
  // Only engaged when no source carried an id, so newer solc is unaffected.
  if (!anyId) {
    let idx = 0;
    for (const p of Object.keys(outputSources || {})) map[idx++] = p;
  }
  return (id) => map[id];
}

/**
 * @param {object} opts
 * @param {string} opts.version
 * @param {boolean} opts.optimizer
 * @param {number} opts.runs
 * @param {string|null} opts.evmVersion
 * @param {object|undefined} opts.libraries  standard-json libraries or flat {name:addr}
 * @param {string[]|undefined} opts.remappings  standard-json import remappings ("prefix=path")
 * @param {object|undefined} opts.metadata  standard-json metadata settings (bytecodeHash/appendCBOR)
 * @param {object|undefined} opts.debug  standard-json debug settings (e.g. revertStrings)
 * @param {Record<string,string>} opts.sources  path -> content
 * @param {string} opts.contractName
 * @param {string} opts.onchainCodeHex  deployed runtime code (with/without 0x)
 * @returns {Promise<{deployedObject, sourceMap, idToPath, sources, evmVersion} | null>}
 */
export async function compileAndMatch(opts) {
  const { version, optimizer, runs, evmVersion, viaIR, libraries, remappings, metadata, debug, sources, contractName, onchainCodeHex } = opts;
  const solc = await loadSolc(version);
  const onchain = onchainCodeHex.replace(/^0x/, "");

  const srcInput = {};
  for (const [p, content] of Object.entries(sources)) srcInput[p] = { content };

  for (const evm of evmVersionCandidates(evmVersion, version)) {
    for (const ir of viaIRCandidates(viaIR, version)) {
      const settings = {
        // `runs: 0` is a valid, real optimizer setting (compiled with
        // `--optimize-runs 0`) — `??` (not `||`) preserves it instead of
        // silently coercing it to 200, which would break bytecode matching.
        optimizer: { enabled: !!optimizer, runs: runs ?? 200 },
        outputSelection: {
          "*": { "*": ["evm.deployedBytecode.object", "evm.deployedBytecode.sourceMap", "evm.deployedBytecode.immutableReferences"] }
        }
      };
      if (evm) settings.evmVersion = evm;
      if (ir) settings.viaIR = true;
      // Import remappings ("@openzeppelin/=lib/openzeppelin-contracts/", ...) let
      // solc resolve alias imports in the source to the resolved-path keys in the
      // sources map. Without them, Foundry-verified contracts fail every remapped
      // import ("File import callback not supported").
      if (Array.isArray(remappings) && remappings.length) settings.remappings = remappings;
      // Replay the declared metadata trailer policy. Contracts verified with
      // appendCBOR:false / bytecodeHash:none carry no CBOR trailer on-chain;
      // without this, solc appends its default IPFS hash and the stripped code
      // region no longer aligns with the deployed code.
      if (metadata && typeof metadata === "object") settings.metadata = metadata;
      // Replay the declared debug settings (e.g. revertStrings:"debug" emits extra
      // revert-reason strings), which shifts codegen length just like optimizer/IR.
      if (debug && typeof debug === "object") settings.debug = debug;
      if (libraries) {
        // solc standard-json wants { "<file>": { "<Lib>": "0x.." } }; a flat
        // { "<Lib>": "0x.." } is accepted under a wildcard-ish empty key too, but
        // to be safe apply the flat libs to every source file.
        const isNested = Object.values(libraries).some((v) => typeof v === "object");
        settings.libraries = isNested
          ? libraries
          : Object.fromEntries(Object.keys(sources).map((f) => [f, libraries]));
      }

      let out;
      try {
        out = JSON.parse(solc.compile(JSON.stringify({ language: "Solidity", sources: srcInput, settings })));
      } catch {
        continue;
      }
      if ((out.errors || []).some((e) => e.severity === "error")) continue;

      // find the target contract across files
      let target = null;
      for (const file of Object.keys(out.contracts || {})) {
        if (out.contracts[file][contractName]) {
          target = out.contracts[file][contractName];
          break;
        }
      }
      if (!target) continue;

      const deployedObject = target.evm.deployedBytecode.object;
      const sourceMap = target.evm.deployedBytecode.sourceMap;
      const immutableRefs = target.evm.deployedBytecode.immutableReferences;
      if (!deployedObject || !sourceMap) continue;

      // Compiled output reliably carries CBOR metadata; strip it to get the code
      // region, then compare the on-chain code's prefix of that same length. The
      // on-chain metadata may differ in size (different source hash) but sits
      // AFTER the code region, whose length is identical for the same compiler.
      const compiledCode = stripMetadata(deployedObject);
      const codeLen = compiledCode.length;
      if (onchain.length < codeLen) continue;
      let a = maskImmutables(compiledCode, immutableRefs);
      let b = maskImmutables(onchain.slice(0, codeLen), immutableRefs);
      if (a !== b) [a, b] = maskEmbeddedMetadata(a, b);
      if (a === b && a.length > 0) {
        return {
          deployedObject,
          sourceMap,
          idToPath: buildIdToPath(out.sources),
          sources, // path -> content
          evmVersion: evm || "default",
          viaIR: !!ir
        };
      }
    }
  }
  return null;
}
