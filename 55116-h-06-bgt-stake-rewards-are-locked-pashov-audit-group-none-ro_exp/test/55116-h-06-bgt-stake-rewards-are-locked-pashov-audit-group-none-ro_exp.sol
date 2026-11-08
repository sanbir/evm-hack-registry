// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    Honey,
    BGTStaker,
    BGT,
    RootsStakerFixed
} from "./55116-h-06-bgt-stake-rewards-are-locked-pashov-audit-group-none-ro.sol";

contract Finding55116Test is Test {
    function test_exploit_honey_stuck_user_claim_pays_zero() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.N(), 1000 ether, "N");
        assertEq(e.paidToUser(), 0, "claim pays 0");
        assertEq(e.stuck(), 1000 ether, "1000 HONEY stuck");
        assertEq(e.honey().balanceOf(address(e.vault())), 1000 ether, "vault holds N");
        assertEq(e.honey().balanceOf(address(e.user())), 0, "user holds 0");

        emit log_named_uint("HARM honey stuck", e.stuck());
        emit log_named_uint("HARM paid to user", e.paidToUser());
    }

    function test_control_claim_interface_pays_N() public {
        Honey honey = new Honey();
        BGTStaker vault = new BGTStaker(honey);
        BGT bgt = new BGT(address(vault));
        RootsStakerFixed staker = new RootsStakerFixed(bgt);

        staker.queueBoost(1 ether, hex"01");
        staker.pokeBoost();

        uint256 n = 1000 ether;
        honey.mint(address(this), n);
        honey.approve(address(vault), n);
        vault.fundReward(address(staker), n);
        assertEq(honey.balanceOf(address(vault)), n, "funded");

        uint256 paid = staker.claimBoostRewards(address(this));
        assertEq(paid, n, "control pays N");
        assertEq(honey.balanceOf(address(this)), n, "caller received N");
        assertEq(honey.balanceOf(address(vault)), 0, "vault emptied");

        emit log_named_uint("CONTROL honey paid", paid);
    }
}
