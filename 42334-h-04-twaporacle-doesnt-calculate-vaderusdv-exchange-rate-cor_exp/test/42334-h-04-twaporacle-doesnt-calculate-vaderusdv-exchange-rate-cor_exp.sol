// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./42334-h-04-twaporacle-doesnt-calculate-vaderusdv-exchange-rate-cor.sol";

contract Vader42334Test is Test {
    function test_exploit_overMintsUSDVFromCollapsedTwapScale() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.badRate(), 18, "oracle uses the decimal count");
        assertEq(e.correctRate(), 1e18, "oracle should use decimal scale");
        assertEq(e.usdvMinted(), (uint256(1e18) * 1e18) / 18, "attacker mints against bad rate");
        assertGt(e.usdv().balanceOf(address(e)), 1e30, "one VADER becomes absurd USDV balance");
    }

    function test_control_correctScaleWouldMintOneToOne() public {
        MockERC20 vader = new MockERC20("Vader", "VADER", 18);
        TwapOracle oracle = new TwapOracle();
        uint256 goodRate = oracle.correctVaderUSDV(address(vader), 1e18, 1e18);
        assertEq((1e18 * 1e18) / goodRate, 1e18, "correct scale preserves 1:1 minting");
    }
}
