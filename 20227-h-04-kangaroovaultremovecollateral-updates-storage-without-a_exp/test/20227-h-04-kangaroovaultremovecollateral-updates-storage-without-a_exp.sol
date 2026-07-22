// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./20227-h-04-kangaroovaultremovecollateral-updates-storage-without-a.sol";

/// @dev forge-std driver for the reduced Polynomial H-04 PoC.
contract RemoveCollateralNoOpTest is Test {
    Exploit exploit;

    function setUp() public {
        exploit = new Exploit();
    }

    function test_removeCollateralLosesFunds() public {
        exploit.run();

        MockERC20 susd = exploit.susd();
        KangarooVault vault = exploit.vault();
        Exchange exchange = exploit.exchange();
        uint256 deposit = exploit.DEPOSIT();
        uint256 remove = exploit.REMOVE();

        uint256 recovered = susd.balanceOf(address(vault));
        uint256 stranded = susd.balanceOf(address(exchange));

        // The vault deposited `deposit`, "removed" `remove` (which returned
        // nothing), and on close recovered only `deposit - remove`.
        assertEq(recovered, deposit - remove, "vault should recover deposit - remove");
        assertLt(recovered, deposit, "vault must have lost funds");
        assertEq(deposit - recovered, remove, "loss should equal the removed amount");

        // The removed slice is stranded in the Exchange, unrecoverable.
        assertEq(stranded, remove, "stranded collateral should equal removed amount");
    }
}
