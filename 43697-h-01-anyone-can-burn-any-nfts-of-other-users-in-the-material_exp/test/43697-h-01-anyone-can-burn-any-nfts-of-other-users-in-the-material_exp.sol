// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    Holder,
    ObjectBase
} from "./43697-h-01-anyone-can-burn-any-nfts-of-other-users-in-the-material.sol";

contract MaterialObjectFixed is ObjectBase {
    function mintObject(address to, uint256 tokenid, uint256 amount) external {
        _mint(to, tokenid, amount);
    }

    function burnObject(address from, uint256 tokenid, uint256 amount) external {
        require(msg.sender == from, "owner");
        super._burn(from, tokenid, amount);
    }
}

contract Finding43697Test is Test {
    function test_exploit_stranger_burns_holders_object() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.material().ownerOf(7), address(0), "ownerOf cleared");
        assertEq(e.material().balanceOf(address(e.holder()), 7), 0, "balance 0");
        assertEq(e.marker().balanceOf(address(e)), 1, "one object burned");
        console.log("ownerOf(7)", e.material().ownerOf(7));
        console.log("holder balance", e.material().balanceOf(address(e.holder()), 7));
        console.log("burned", e.marker().balanceOf(address(e)));
    }

    function test_control_only_owner_can_burn() public {
        MaterialObjectFixed fixedObj = new MaterialObjectFixed();
        Holder holder = new Holder();
        fixedObj.mintObject(address(holder), 7, 1);
        vm.expectRevert(bytes("owner"));
        fixedObj.burnObject(address(holder), 7, 1);
        assertEq(fixedObj.ownerOf(7), address(holder), "holder still owns 7");
        assertEq(fixedObj.balanceOf(address(holder), 7), 1, "balance stays 1");
    }
}
