// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./35126-h-13-kelp-finalizecooldown-cannot-claim-the-withdrawal-if-ad.sol";

contract KelpDustWithdrawalFreezeTest is Test {
    receive() external payable {}

    function test_dustRequestFreezesTheRealWithdrawal() public {
        Exploit e = new Exploit();
        vm.deal(address(this), 10.0001 ether);
        e.run{value: 10.0001 ether}();

        MockLidoWithdraw lido = e.lido();
        (uint256 realAmount, bool realFinalized, bool realClaimed) = lido.statuses(2);
        assertEq(realAmount, 10 ether);
        assertTrue(realFinalized, "the real withdrawal did finalize on Lido's side");
        assertFalse(realClaimed, "but it was NEVER claimed - permanently stuck");

        // The dust request (#1) is the only one that was ever claimed.
        (, , bool dustClaimed) = lido.statuses(1);
        assertTrue(dustClaimed);
    }

    /// @notice Control: with no adversary dust request, the real withdrawal lands
    /// at index 0 and finalizeCooldown() claims it correctly.
    function test_control_noAdversary_realWithdrawalClaimedCorrectly() public {
        MockLidoWithdraw lido = new MockLidoWithdraw();
        KelpCooldownHolder holder = new KelpCooldownHolder(address(this), lido);
        (bool ok,) = address(lido).call{value: 10 ether}("");
        require(ok);

        holder.triggerExtraStep(10 ether); // lands at index 0 (request id 1) this time
        lido.finalize(1);

        (uint256 tokensClaimed, bool finalized) = holder.finalizeCooldown();
        assertTrue(finalized);
        assertEq(tokensClaimed, 10 ether, "control: the real withdrawal is claimed in full");
    }
}
