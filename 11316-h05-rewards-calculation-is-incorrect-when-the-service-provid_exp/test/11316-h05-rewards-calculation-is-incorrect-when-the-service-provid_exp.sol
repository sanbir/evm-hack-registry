// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Audio} from "./11316-h05-rewards-calculation-is-incorrect-when-the-service-provid.sol";

/// Control: totalRewards is the amount processClaim minted, not staking minus outside.
contract FixedClaim {
    Audio public token;
    address public delegator;
    uint256 public totalRewards;
    uint256 public delegatorCredit;

    constructor(Audio _token, address _delegator) {
        token = _token;
        delegator = _delegator;
    }

    function claimRewards() external {
        uint256 fair = 100 ether;
        token.mint(address(this), fair);
        totalRewards = fair;
        delegatorCredit = (1000 ether * totalRewards) / 2000 ether;
        token.transfer(delegator, delegatorCredit);
    }
}

contract Finding11316Test is Test {
    function test_exploit_pays_550_instead_of_50() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.mgr().totalRewards(), 1100 ether, "totalRewards");
        assertEq(e.mgr().delegatorCredit(), 550 ether, "paid");
        assertEq(e.mgr().fairDelegatorCredit(), 50 ether, "fair");
        assertEq(e.token().balanceOf(address(e)), 550 ether, "received");
    }

    function test_control_pays_fair_50() public {
        Audio token = new Audio();
        FixedClaim fixedClaim = new FixedClaim(token, address(this));
        token.mint(address(fixedClaim), 3000 ether);
        fixedClaim.claimRewards();
        assertEq(fixedClaim.totalRewards(), 100 ether, "fair total");
        assertEq(fixedClaim.delegatorCredit(), 50 ether, "fair credit");
        assertEq(token.balanceOf(address(this)), 50 ether, "received 50");
    }
}
