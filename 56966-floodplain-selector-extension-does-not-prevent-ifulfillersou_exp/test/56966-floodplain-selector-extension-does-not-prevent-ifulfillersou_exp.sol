// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, Asset, FloodPlain, Fulfiller} from "./56966-floodplain-selector-extension-does-not-prevent-ifulfillersou.sol";

contract FloodPlainFixed is FloodPlain {
    constructor(address permit2_) FloodPlain(permit2_) {}

    function execute(address target, bytes calldata data) external override {
        bytes28 extension;
        assembly {
            extension := shl(32, calldataload(data.offset))
        }
        lastExtension = extension;
        bytes28 singular = bytes28(keccak256("IFulfiller.sourceConsideration"));
        require(extension != SELECTOR_EXTENSION && extension != singular && target != permit2, "MALICIOUS_CALL");
        (bool ok,) = target.call(data);
        require(ok, "hook");
    }
}

contract Finding56966Test is Test {
    function test_exploit_takes_500_from_the_fulfiller() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.token().balanceOf(address(e)), 500, "attacker took 500");
        assertEq(e.token().balanceOf(address(e.victim())), 0, "victim drained");
    }

    function test_control_rejects_the_singular_source() public {
        Asset token = new Asset();
        FloodPlainFixed flood = new FloodPlainFixed(address(0xBEEF));
        Fulfiller victim = new Fulfiller(token, address(flood));
        token.mint(address(victim), 500);
        bytes28 singular = bytes28(keccak256("IFulfiller.sourceConsideration"));
        bytes memory data = abi.encodeWithSelector(
            Fulfiller.sourceConsideration.selector, singular, address(this), uint256(500)
        );
        (bool ok,) = address(flood).call(abi.encodeWithSelector(FloodPlain.execute.selector, address(victim), data));
        assertFalse(ok, "checked source must reject the singular extension");
        assertEq(token.balanceOf(address(this)), 0, "control pays 0");
        assertEq(token.balanceOf(address(victim)), 500, "victim keeps 500");
    }
}
