// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Cqt, Exploit, Proxy} from "./42307-h-01-usage-of-an-incorrect-version-of-ownbale-library-can-po.sol";

/// OwnableUpgradeable shape: initialize writes the owner into proxy storage.
contract FixedStaking {
    address private _owner;
    uint8 private _initialized;
    Cqt public immutable cqt;
    uint128 public validatorMinStakedRequired;
    uint128 public rewardsLocked;

    constructor(Cqt _cqt) {
        cqt = _cqt;
    }

    function owner() public view returns (address) {
        return _owner;
    }

    function initialize(uint128 minStakedRequired) public {
        require(_initialized == 0, "init");
        _initialized = 1;
        _owner = msg.sender;
        validatorMinStakedRequired = minStakedRequired;
        rewardsLocked = minStakedRequired;
    }

    function takeOutRewardTokens(uint128 amount) public {
        require(msg.sender == _owner, "Ownable: caller is not the owner");
        require(amount > 0, "Amount is 0");
        require(rewardsLocked >= amount, "Amount is greater than available");
        rewardsLocked -= amount;
        cqt.transfer(_owner, uint256(amount));
    }
}

contract Finding42307Test is Test {
    function test_exploit_owner_takeout_reverts_and_1000_stuck() public {
        Exploit e = new Exploit();
        e.run();
        uint256 stuck = e.cqt().balanceOf(address(e.proxy()));
        console.log("stuck CQT", stuck);
        console.log("impl owner", e.impl().owner());
        assertEq(stuck, 1000 ether, "1000 CQT stuck on the proxy");
        assertEq(e.impl().owner(), address(e), "constructor owner is the implementation");
        assertEq(e.cqt().balanceOf(address(e)), 0, "deployer received nothing");
    }

    function test_control_ownable_init_releases_1000() public {
        Cqt cqt = new Cqt();
        FixedStaking impl = new FixedStaking(cqt);
        Proxy proxy = new Proxy(address(impl));
        cqt.mint(address(proxy), 1000 ether);

        FixedStaking staking = FixedStaking(address(proxy));
        staking.initialize(uint128(1000 ether));
        assertEq(staking.owner(), address(this), "proxy owner is the caller");

        staking.takeOutRewardTokens(uint128(1000 ether));
        assertEq(cqt.balanceOf(address(this)), 1000 ether, "owner received 1000");
        assertEq(cqt.balanceOf(address(proxy)), 0, "proxy emptied");
        assertEq(staking.rewardsLocked(), 0);
    }
}
