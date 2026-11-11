// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    LoanToken,
    UniPool,
    UniFactory,
    PositionManager,
    INonfungiblePositionManager,
    IUniswapV3Factory,
    IUniswapV3Pool,
    LiquidityAmounts,
    TickMath
} from "./53325-h-07-omooracle-wrong-use-of-uniswap-interface-to-get-pool-ad.sol";

/// @dev Auditor fix: factory().getPool(token0, token1, fee), then slot0 on that pool.
contract OracleFixed {
    address public positionManager;
    LoanToken public loan;

    constructor(address _manager, LoanToken _loan) {
        positionManager = _manager;
        loan = _loan;
    }

    function borrow(uint256 tokenId, uint128 liquidity) external returns (uint256 quoted, uint256 debt) {
        INonfungiblePositionManager nftManager = INonfungiblePositionManager(positionManager);
        (
            ,
            ,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            ,
            ,
            ,
            ,
        ) = nftManager.positions(tokenId);
        address poolAddress = IUniswapV3Factory(nftManager.factory()).getPool(token0, token1, fee);
        IUniswapV3Pool pool = IUniswapV3Pool(poolAddress);
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        (, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            liquidity
        );
        quoted = amount1 * 1e18 / uint256(liquidity);
        debt = amount1;
        loan.transfer(msg.sender, debt);
    }
}

contract Finding53325Test is Test {
    function test_exploit_borrows_off_the_factory_price() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.quoted(), 100 ether, "factory price is 100");
        assertEq(e.borrowed(), 100 ether, "borrow is 100");
        assertEq(e.fair(), 1 ether, "real pool price is 1");
        assertEq(e.loan().balanceOf(address(e)), 100 ether, "received 100 USD");
    }

    function test_control_reads_the_position_pool() public {
        LoanToken loan = new LoanToken();
        UniPool pool = new UniPool(uint160(1) << 96);
        UniFactory factory = new UniFactory(address(pool), uint160(10) << 96);
        PositionManager manager = new PositionManager(address(factory));
        OracleFixed fixedOracle = new OracleFixed(address(manager), loan);
        loan.mint(address(fixedOracle), 100 ether);

        (uint256 quoted, uint256 debt) = fixedOracle.borrow(1, uint128(1 ether));
        assertEq(quoted, 1 ether, "correct pool price is 1");
        assertEq(debt, 1 ether, "borrow is 1, not 100");
        assertEq(loan.balanceOf(address(this)), 1 ether, "paid 1 USD");
        assertEq(loan.balanceOf(address(fixedOracle)), 99 ether, "the other 99 stayed");
    }
}
