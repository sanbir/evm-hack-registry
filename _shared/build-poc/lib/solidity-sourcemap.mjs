// Solidity source-map utilities (build-time, Node ESM).
//
// Turns a Foundry-compiled contract's `deployedBytecode.sourceMap` +
// `source_id_to_path` (from build-info) into a pc -> {file, startLine, endLine}
// map, so the browser debugger can highlight the Solidity line that corresponds
// to the currently executing opcode (source-map based, like a real debugger).
//
// Source-map format reference:
//   https://docs.soliditylang.org/en/latest/internals/source_mappings.html
// Entries are ';'-separated, one per INSTRUCTION (an opcode + its PUSH data is
// one instruction). Each entry is `s:l:f:j:m` (start, length, fileId, jumpType,
// modifierDepth); empty fields inherit the previous entry's value.

const PUSH1 = 0x60;
const PUSH32 = 0x7f;

// Disassemble bytecode into a list of instruction start PCs (each opcode is one
// instruction; PUSHn consumes n data bytes but is still one instruction).
export function instructionStartPcs(codeHex) {
  const hex = codeHex.startsWith("0x") ? codeHex.slice(2) : codeHex;
  const bytes = Buffer.from(hex, "hex");
  const pcs = [];
  let i = 0;
  while (i < bytes.length) {
    pcs.push(i);
    const op = bytes[i];
    i += PUSH1 <= op && op <= PUSH32 ? 1 + (op - PUSH1 + 1) : 1;
  }
  return pcs;
}

// Parse a Solidity source map into an array of {s, l, f} per instruction.
export function parseSourceMap(sourceMap) {
  const out = [];
  let prev = { s: -1, l: -1, f: -1 };
  for (const part of sourceMap.split(";")) {
    const fields = part.split(":");
    const cur = { ...prev };
    if (fields[0] !== undefined && fields[0] !== "") cur.s = parseInt(fields[0], 10);
    if (fields[1] !== undefined && fields[1] !== "") cur.l = parseInt(fields[1], 10);
    if (fields[2] !== undefined && fields[2] !== "") cur.f = parseInt(fields[2], 10);
    out.push(cur);
    prev = cur;
  }
  return out;
}

// Build a byte-offset -> line-number lookup for a source string (1-based lines).
function makeLineLookup(content) {
  // lineStarts[k] = byte offset where line (k+1) begins
  const lineStarts = [0];
  for (let i = 0; i < content.length; i++) {
    if (content[i] === "\n") lineStarts.push(i + 1);
  }
  return (offset) => {
    // binary search for the greatest lineStart <= offset
    let lo = 0;
    let hi = lineStarts.length - 1;
    while (lo < hi) {
      const mid = (lo + hi + 1) >> 1;
      if (lineStarts[mid] <= offset) lo = mid;
      else hi = mid - 1;
    }
    return lo + 1; // 1-based
  };
}

/**
 * Build a pc -> {file, startLine, endLine} map for a contract's runtime code.
 *
 * @param {string} deployedObjectHex  deployedBytecode.object
 * @param {string} deployedSourceMap  deployedBytecode.sourceMap
 * @param {(id:number)=>string|undefined} idToPath  source id -> file path
 * @param {(path:string)=>string|undefined} readSource  path -> file content
 * @returns {{ files: Record<string,string>, pcToLine: Record<string,{file:string,startLine:number,endLine:number}> }}
 */
export function buildPcToLine(deployedObjectHex, deployedSourceMap, idToPath, readSource) {
  const entries = parseSourceMap(deployedSourceMap);
  const pcs = instructionStartPcs(deployedObjectHex);

  const files = {};
  const lineLookups = new Map(); // path -> lookup fn
  const pcToLine = {};

  for (let instrIndex = 0; instrIndex < pcs.length; instrIndex++) {
    const entry = entries[instrIndex];
    if (!entry || entry.f < 0 || entry.s < 0) continue; // metadata tail / unmapped
    const filePath = idToPath(entry.f);
    if (!filePath) continue; // compiler-generated (e.g. #utility.yul) — no user source
    let content = files[filePath];
    if (content === undefined) {
      const src = readSource(filePath);
      if (src === undefined) continue; // source not available on disk
      content = src;
      files[filePath] = content;
      lineLookups.set(filePath, makeLineLookup(content));
    }
    const lookup = lineLookups.get(filePath);
    const startLine = lookup(entry.s);
    const endLine = lookup(entry.s + Math.max(0, entry.l - 1));
    // s/e = source byte range of the statement this instruction belongs to.
    // Used for line-level step-over/step-back (offset ranges are robust against
    // constant/declaration "detours" that share a statement).
    pcToLine[pcs[instrIndex]] = { file: filePath, startLine, endLine, s: entry.s, e: entry.s + entry.l };
  }

  return { files, pcToLine };
}
