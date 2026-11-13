// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Eth, ValidatorDetailsFixed, BeaconDeposit} from
    "./30900-h-5-swapvalidatordetails-incorrectly-writes-keys-to-memory-r.sol";

contract Finding30900Test is Test {
    function test_exploit_corrupted_bls_keys_lock_64_eth() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.eth().balanceOf(address(e.beacon())), 64 ether, "beacon holds 64");
        assertEq(e.beacon().locked(), 64 ether, "locked 64");
        assertEq(e.withdrawn(), 0, "real key withdraws 0");
        assertTrue(e.middleZero(), "middle 16 bytes zero");
        assertTrue(e.keysDiffer(), "key is not the original");
    }

    function test_control_fixed_mstore_order_withdraws_64_eth() public {
        Eth eth = new Eth();
        ValidatorDetailsFixed fixedDetails = new ValidatorDetailsFixed();
        BeaconDeposit beacon = new BeaconDeposit(eth);

        fixedDetails.storeKey(1, 0, bytes32(uint256(0x95cfcb859956953f9834f8b14cdaa939e472a2b5d0471addbe490b97ed99c6eb)), bytes32(bytes16(0x8af94bc3ba4d4bfa93d087d522e4b78d)));
        fixedDetails.storeKey(1, 1, bytes32(uint256(0xaabbccddeeff00112233445566778899aabbccddeeff00112233445566778899)), bytes32(bytes16(0x0123456789abcdeffedcba9876543210)));
        fixedDetails.swapValidatorDetails(1, 0, 1);

        bytes memory intact = fixedDetails.loadedKey1();
        assertEq(intact.length, 48, "len");
        assertTrue(intact[16] != 0, "middle preserved");

        eth.mint(address(this), 64 ether);
        eth.approve(address(beacon), 64 ether);
        beacon.deposit(fixedDetails.loadedKey1());
        beacon.deposit(fixedDetails.loadedKey2());
        uint256 got = beacon.withdraw(intact);
        got += beacon.withdraw(fixedDetails.loadedKey2());

        assertEq(got, 64 ether, "control withdraws 64");
        assertEq(beacon.locked(), 0, "nothing left locked");
        assertEq(eth.balanceOf(address(beacon)), 0, "beacon empty");
        assertEq(eth.balanceOf(address(this)), 64 ether, "operator recovered 64");
    }
}
