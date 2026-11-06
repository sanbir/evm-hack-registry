// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, MiniToken} from "./19137-h-8-lack-of-access-control-for-mintrebalancer-and-burnrebala.sol";

contract USSDFixed {
    MiniToken public token;
    address public balancer;
    uint256 public collateral;

    error NotBalancer();

    constructor(address _token, uint256 _collateral, address _balancer) {
        token = MiniToken(_token);
        collateral = _collateral;
        balancer = _balancer;
    }

    function mintRebalancer(uint256 amount) public {
        if (msg.sender != balancer) revert NotBalancer();
        token.mint(address(this), amount);
    }

    function collateralFactor() public view returns (uint256) {
        return (collateral * 1e6) / token.totalSupply();
    }
}

contract Finding19137Test is Test {
    function test_exploit_inflates_supply_and_collapses_collateral_factor() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.cfBefore(), 1e6, "started at peg");
        assertEq(e.cfAfter(), 1e5, "10x collapse");
        assertEq(e.token().balanceOf(address(e.ussd())), e.UNBACKED(), "unbacked");
        assertEq(e.token().totalSupply(), e.START_SUPPLY() + e.UNBACKED(), "supply");
    }

    function test_control_only_balancer_can_mint() public {
        MiniToken token = new MiniToken("USSD", "USSD");
        token.mint(address(0xBEEF), 1000e18);
        USSDFixed fixedUssd = new USSDFixed(address(token), 1000e18, address(0xB0BA));
        vm.expectRevert(USSDFixed.NotBalancer.selector);
        fixedUssd.mintRebalancer(9000e18);
        assertEq(fixedUssd.collateralFactor(), 1e6, "peg holds");
        assertEq(token.totalSupply(), 1000e18, "no unbacked mint");
    }
}
