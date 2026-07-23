// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./58555-h-03-mishandling-of-receiving-hype-in-the-stakingmanager-use.sol";

/*//////////////////////////////////////////////////////////////
    Kinetiq — receive() re-stakes Core HYPE (#58555)
//////////////////////////////////////////////////////////////*/
contract KinetiqHypeReceiveTest is Test {
    function test_exploit_coreReturnRestakes_confirmFails() public {
        Exploit e = new Exploit();
        e.run{value: 1 ether}();

        assertTrue(e.confirmFailed(), "confirmWithdrawal must fail");
        assertEq(e.managerBalAfterCoreReturn(), 0, "manager balance 0 after re-stake");
        assertEq(e.systemShares(), 1 ether, "system minted 1e18 spurious kHYPE");
        assertEq(e.manager().pendingWithdraw(address(e.user())), 1 ether, "user still pending");
        // Same ETH recirculates back to Core after the buggy re-stake.
        assertEq(address(e.system()).balance, 1 ether, "core re-holds the stake");
        // totalStaked inflated (original + re-stake) while user claim is stuck.
        assertEq(e.manager().totalStaked(), 2 ether, "totalStaked inflated");
    }

    function test_control_withoutReceiveStake_confirmSucceeds() public {
        // Control: fixed receive() does not re-stake Core returns → confirm works.
        SystemCore system = new SystemCore();
        FixedStakingManager mgr = new FixedStakingManager(address(system));
        uint256 balBefore = address(this).balance;
        mgr.stake{value: 1 ether}();
        mgr.queueWithdrawal(1 ether);
        system.pushTo(address(mgr), 1 ether);
        assertEq(address(mgr).balance, 1 ether, "HYPE sits on manager");
        mgr.confirmWithdrawal();
        assertEq(address(this).balance, balBefore, "user recovered the 1 ETH stake");
        assertEq(mgr.pendingWithdraw(address(this)), 0);
    }

    receive() external payable {}
}

/// @dev Fixed StakingManager for the control test — receive accepts HYPE only.
contract FixedStakingManager {
    mapping(address => uint256) public shares;
    mapping(address => uint256) public pendingWithdraw;
    uint256 public totalShares;
    uint256 public totalStaked;
    address public immutable systemAddress;

    constructor(address _system) {
        systemAddress = _system;
    }

    function stake() public payable {
        require(msg.value > 0, "zero");
        shares[msg.sender] += msg.value;
        totalShares += msg.value;
        totalStaked += msg.value;
        (bool ok,) = systemAddress.call{value: msg.value}("");
        require(ok, "forward");
    }

    function queueWithdrawal(uint256 amount) external {
        require(shares[msg.sender] >= amount, "shares");
        shares[msg.sender] -= amount;
        totalShares -= amount;
        pendingWithdraw[msg.sender] += amount;
    }

    function confirmWithdrawal() external {
        uint256 amt = pendingWithdraw[msg.sender];
        require(amt > 0, "none");
        require(address(this).balance >= amt, "insufficient HYPE");
        pendingWithdraw[msg.sender] = 0;
        totalStaked -= amt;
        (bool ok,) = msg.sender.call{value: amt}("");
        require(ok, "pay");
    }

    receive() external payable {
        // FIX applied: do not auto-stake Core returns.
        if (msg.sender != systemAddress) {
            // accidental ETH from non-system would be ignored here
        }
    }
}
