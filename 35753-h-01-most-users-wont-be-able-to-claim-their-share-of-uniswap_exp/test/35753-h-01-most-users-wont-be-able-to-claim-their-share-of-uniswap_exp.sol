// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./35753-h-01-most-users-wont-be-able-to-claim-their-share-of-uniswap.sol";

contract VultisigFeeClaimExpTest is Test {
    function test_second_investor_permanently_unable_to_claim_fees() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.token0().balanceOf(e.investor1()), 100);
        assertEq(e.token0().balanceOf(e.feeTaker()), 100);
        assertEq(e.token0().balanceOf(e.investor2()), 0);
    }

    /// @dev Control: with the recommended fix (collect only THIS position's
    ///      own computed share, not `type(uint128).max`), the second
    ///      investor's claim succeeds.
    function test_control_fixed_version_both_investors_claim() public {
        MockToken token0 = new MockToken();
        MockToken token1 = new MockToken();
        MockUniV3Pool pool = new MockUniV3Pool(token0, token1);
        ILOPoolFixed iloPool = new ILOPoolFixed(pool, token0, token1, address(0xFEE7A2));

        address investor1 = address(0xA11CE1);
        address investor2 = address(0xA11CE2);
        iloPool.setPosition(1, investor1, 1024);
        iloPool.setPosition(2, investor2, 1024);

        pool.generateFees(200, 200, 2048);

        iloPool.claim(1);
        iloPool.claim(2); // must NOT revert with the fix applied

        assertEq(token0.balanceOf(investor1), 100);
        assertEq(token0.balanceOf(investor2), 100);
    }
}

/// @dev Patched clone used only by the control test: collects exactly this
///      position's own share (`fees0`/`fees1`), never `type(uint128).max`.
contract ILOPoolFixed is ILOPool {
    constructor(MockUniV3Pool _pool, IERC20 _token0, IERC20 _token1, address _feeTaker)
        ILOPool(_pool, _token0, _token1, _feeTaker)
    {}

    function claim(uint256 tokenId) external override returns (uint256 amount0, uint256 amount1) {
        Position storage position = _positions[tokenId];
        uint128 positionLiquidity = position.liquidity;

        (uint256 g0, uint256 g1) = pool.feeGrowthInside();
        uint256 fees0 = ((g0 - position.feeGrowthInside0LastX128) * positionLiquidity) / (2 ** 128);
        uint256 fees1 = ((g1 - position.feeGrowthInside1LastX128) * positionLiquidity) / (2 ** 128);
        amount0 = fees0;
        amount1 = fees1;

        position.feeGrowthInside0LastX128 = g0;
        position.feeGrowthInside1LastX128 = g1;

        // FIX applied: request only OWN share, not type(uint128).max.
        (uint128 amountCollected0, uint128 amountCollected1) =
            pool.collect(address(this), TICK_LOWER, TICK_UPPER, uint128(fees0), uint128(fees1));

        TransferHelper.safeTransfer(address(token0), ownerOf[tokenId], amount0);
        TransferHelper.safeTransfer(address(token1), ownerOf[tokenId], amount1);

        if (amountCollected0 > amount0) {
            TransferHelper.safeTransfer(address(token0), feeTaker, amountCollected0 - amount0);
        }
        if (amountCollected1 > amount1) {
            TransferHelper.safeTransfer(address(token1), feeTaker, amountCollected1 - amount1);
        }
    }
}
