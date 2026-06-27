#!/usr/bin/env python3
"""Convert a Foundry RPC cache file into an anvil --load-state JSON.

Usage:
    cache2anvil.py <foundry_cache_json> <output_anvil_state.json>

The Foundry cache lives at ~/.foundry/cache/rpc/<chain>/<block> and contains, in JSON:
  - meta.block_env   -> block header fields (number, timestamp, beneficiary, ...)
  - accounts         -> { addr: { balance, nonce, code: {<Variant>: {bytecode: "0x..."}} } }
  - storage          -> { addr: { slot: value } }

anvil --load-state requires (top-level):
  block, accounts, best_block_number, blocks, transactions, historical_states
where accounts[addr] = { nonce:int, balance:"0x..", code:"0x..", storage:{slot:val} }
and blocks[0].header is a full block header whose number == best_block_number.

At runtime, anvil serves EVERY RPC call (eth_getCode, eth_getBalance,
eth_getStorageAt, eth_getBlockByNumber, ...) from this in-memory state, so `forge
test` forks from anvil fully offline with no separate RPC cache needed.

NOTE: this script runs at BUILD time only (on a machine with python3). The emitted
anvil state JSON is plain data that travels with the repo; at RUN time no python is
required — only `anvil --load-state` (shipped with Foundry).
"""
import json
import sys

Z32 = "0x" + "00" * 32
BLOOM = "0x" + "00" * 256
EMPTY_TRIE = "0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421"
UNCLE_HASH = "0x1dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347"


def extract_code(code_field):
    """Foundry stores code as { "<Variant>": { bytecode: "0x..." } } or a raw 0x-string."""
    if isinstance(code_field, str) and code_field.startswith("0x"):
        return code_field
    if isinstance(code_field, dict):
        for v in code_field.values():
            if isinstance(v, dict) and "bytecode" in v and isinstance(v["bytecode"], str):
                return v["bytecode"]
            if isinstance(v, str) and v.startswith("0x"):
                return v
    return "0x"


def convert(src_path, dst_path):
    d = json.load(open(src_path))
    be = d["meta"]["block_env"]

    accounts = {}
    for addr, acc in d.get("accounts", {}).items():
        a = addr.lower()
        accounts[a] = {
            "nonce": int(acc.get("nonce", 0)),
            "balance": acc.get("balance", "0x0"),
            "code": extract_code(acc.get("code")),
            "storage": {},
        }
    for addr, slots in d.get("storage", {}).items():
        a = addr.lower()
        accounts.setdefault(a, {"nonce": 0, "balance": "0x0", "code": "0x", "storage": {}})
        if isinstance(slots, dict):
            accounts[a]["storage"] = dict(slots)

    blocknum_hex = be["number"]
    blocknum = int(blocknum_hex, 16)

    block = {
        "number": blocknum_hex,
        "beneficiary": be["beneficiary"],
        "timestamp": be["timestamp"],
        "gas_limit": be["gas_limit"],
        "basefee": be.get("basefee", 0),
        "difficulty": be.get("difficulty", "0x0"),
        "prevrandao": be.get("prevrandao", Z32),
    }
    if "blob_excess_gas_and_price" in be:
        block["blob_excess_gas_and_price"] = be["blob_excess_gas_and_price"]

    header = {
        "parentHash": Z32,
        "sha3Uncles": UNCLE_HASH,
        "miner": be["beneficiary"],
        "stateRoot": EMPTY_TRIE,
        "transactionsRoot": EMPTY_TRIE,
        "receiptsRoot": EMPTY_TRIE,
        "logsBloom": BLOOM,
        "difficulty": be.get("difficulty", "0x0"),
        "number": blocknum_hex,
        "gasLimit": hex(be["gas_limit"]),
        "gasUsed": "0x0",
        "timestamp": be["timestamp"],
        "extraData": "0x",
        "mixHash": be.get("prevrandao", Z32),
        "nonce": "0x0000000000000000",
        "baseFeePerGas": hex(be.get("basefee", 0)),
        "withdrawalsRoot": Z32,
        "blobGasUsed": "0x0",
        "excessBlobGas": "0x0",
        "parentBeaconBlockRoot": Z32,
        "requestsHash": Z32,
    }

    out = {
        "block": block,
        "accounts": accounts,
        "best_block_number": blocknum,
        "blocks": [{"header": header, "transactions": [], "ommers": []}],
        "transactions": [],
        "historical_states": None,
    }
    with open(dst_path, "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print(f"wrote {dst_path}: {len(accounts)} accounts, block {blocknum}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)
    convert(sys.argv[1], sys.argv[2])
