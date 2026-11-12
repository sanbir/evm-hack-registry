// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Asset,
    Exploit,
    Oracle,
    OracleFixed,
    Vault
} from "./63079-lack-of-replay-protection-in-pps-oracle-spearbit-none-superf.sol";

contract Finding63079Test is Test {
    address internal constant SIGNER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address internal constant STRATEGY = 0x000000000000000000000000000000000000bEEF;
    uint8 internal constant CV = 27;
    bytes32 internal constant CR = 0xf0c1294d38bcd9d49c6affc898905a7d4144428d8110f9cc2921180ec08566ea;
    bytes32 internal constant CS = 0x015a4ad3bea99a0630381b34b867b98bee2490f04e8a0625500a497d83c97f91;

    function test_exploit_second_use_pays_the_stale_price() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.oracle().uses(), 2, "signature used twice");
        assertEq(e.oracle().pps(), 2 ether, "stale price stuck");
        assertEq(e.payout(), 200 ether, "paid");
        assertEq(e.fairPayout(), 100 ether, "fair");
        assertEq(e.offBy(), 100 ether, "off by N");
        assertEq(e.asset().balanceOf(address(e)), 200 ether, "recipient");
    }

    function test_control_nonce_rejects_the_second_use() public {
        Asset asset = new Asset();
        OracleFixed oracle = new OracleFixed(SIGNER);
        Vault vault = new Vault(asset, Oracle(address(oracle)));
        asset.mint(address(vault), 200 ether);
        vault.mintShares(address(this), 100 ether);

        oracle.update(STRATEGY, 2 ether, 0, SIGNER, 1, 1_700_000_000, CV, CR, CS);
        assertEq(oracle.nonce(), 1, "nonce consumed");
        oracle.postFresh(1 ether);

        vm.expectRevert(bytes("signer"));
        oracle.update(STRATEGY, 2 ether, 0, SIGNER, 1, 1_700_000_000, CV, CR, CS);

        assertEq(oracle.pps(), 1 ether, "fresh price stands");
        uint256 payout = vault.redeem(address(this));
        assertEq(payout, 100 ether, "fair payout");
        assertEq(asset.balanceOf(address(this)), 100 ether, "no overpay");
    }
}
