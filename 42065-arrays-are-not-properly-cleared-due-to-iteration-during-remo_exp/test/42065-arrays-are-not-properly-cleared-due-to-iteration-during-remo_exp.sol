// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    ISignerSet,
    SessionKey,
    SmartAccount,
    Usd
} from "./42065-arrays-are-not-properly-cleared-due-to-iteration-during-remo.sol";

/// PR 65 order: pop the tail each iteration so swap-and-pop cannot skip a signer.
contract FixedSessions is ISignerSet {
    mapping(address => bytes32[]) internal values;
    mapping(address => mapping(bytes32 => uint256)) internal positions;

    function add(address account, address signer) external {
        bytes32 value = bytes32(uint256(uint160(signer)));
        if (positions[account][value] != 0) return;
        values[account].push(value);
        positions[account][value] = values[account].length;
    }

    function lengthOf(address account) external view returns (uint256) {
        return values[account].length;
    }

    function contains(address account, address signer) external view returns (bool) {
        return positions[account][bytes32(uint256(uint160(signer)))] != 0;
    }

    function removeAll(address account) external {
        uint256 len = values[account].length;
        for (uint256 i = len; i > 0; i--) {
            _remove(account, values[account][i - 1]);
        }
    }

    function _remove(address account, bytes32 value) internal {
        uint256 position = positions[account][value];
        if (position == 0) return;
        uint256 valueIndex = position - 1;
        uint256 lastIndex = values[account].length - 1;
        if (valueIndex != lastIndex) {
            bytes32 lastValue = values[account][lastIndex];
            values[account][valueIndex] = lastValue;
            positions[account][lastValue] = position;
        }
        values[account].pop();
        delete positions[account][value];
    }
}

contract Finding42065Test is Test {
    address constant SIGNER_A = address(uint160(0xA1));
    address constant SIGNER_B = address(uint160(0xB2));

    function test_exploit_revoked_signer_moves_900() public {
        Exploit e = new Exploit();
        e.run();
        uint256 stolen = e.usd().balanceOf(address(e.sessionKey()));
        uint256 left = e.usd().balanceOf(address(e.account()));
        console.log("stolen USD", stolen);
        console.log("account USD", left);
        console.log("signers left", e.sessions().lengthOf(address(e.account())));
        assertEq(stolen, 900 ether, "revoked key moved 900 USD");
        assertEq(left, 0, "account emptied");
        assertEq(e.sessions().lengthOf(address(e.account())), 1, "one signer survived");
        assertTrue(e.sessions().contains(address(e.account()), address(e.sessionKey())));
    }

    function test_control_reverse_clear_reverts_pull() public {
        Usd usd = new Usd();
        FixedSessions fixedSessions = new FixedSessions();
        SessionKey key = new SessionKey();
        SmartAccount account = new SmartAccount(ISignerSet(address(fixedSessions)), usd);
        key.bind(account);
        usd.mint(address(account), 900 ether);
        account.addSigner(SIGNER_A);
        account.addSigner(SIGNER_B);
        account.addSigner(address(key));
        account.revokeAllSigners();

        assertEq(fixedSessions.lengthOf(address(account)), 0, "set cleared");
        assertEq(usd.balanceOf(address(account)), 900 ether, "900 still in the account");
        vm.expectRevert("revoked");
        key.pull();
        assertEq(usd.balanceOf(address(key)), 0, "key received nothing");
        assertEq(usd.balanceOf(address(account)), 900 ether, "900 stayed");
    }
}
