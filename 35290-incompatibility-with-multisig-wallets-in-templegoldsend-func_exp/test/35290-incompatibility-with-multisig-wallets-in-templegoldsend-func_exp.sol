// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./35290-incompatibility-with-multisig-wallets-in-templegoldsend-func.sol";

contract TempleGoldMultisigExpTest is Test {
    function test_multisig_cross_chain_send_permanently_reverts() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.selfSendWorked(), "same-address self-send should succeed (control)");
        assertTrue(e.multisigSendReverted(), "cross-chain send to user's own multisig must revert");
        assertEq(e.templeGold().balanceOf(address(e.multisigMainnet())), 99 ether);
    }

    /// @dev Control: if the recommended fix (drop or relax the address-equality
    ///      check) were applied, this exact call pattern would succeed instead
    ///      of reverting. We show that here directly against a patched clone.
    function test_control_fixed_version_allows_multisig_bridge() public {
        TempleGoldFixed tg = new TempleGoldFixed();
        Multisig mainnet = new Multisig();
        Multisig arb = new Multisig();
        tg.mint(address(mainnet), 100 ether);

        SendParam memory p = SendParam({
            dstEid: 30110,
            to: bytes32(uint256(uint160(address(arb)))),
            amountLD: 1 ether,
            minAmountLD: 1 ether
        });

        (bool ok,) = mainnet.bridge(TempleGold(address(tg)), p, MessagingFee(0), address(mainnet));
        assertTrue(ok, "with the fix, bridging to a different-address multisig must succeed");
        assertEq(tg.balanceOf(address(mainnet)), 99 ether);
    }
}

/// @dev Patched clone used only by the control test above: the `msg.sender == _to`
///      check is removed, matching the finding's recommended mitigation.
contract TempleGoldFixed is TempleGold {
    function send(SendParam calldata _sendParam, MessagingFee calldata _fee, address _refundAddress)
        external
        payable
        override
        returns (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt)
    {
        address _to = address(uint160(uint256(_sendParam.to)));
        // FIX applied: no address-equality check.
        uint256 amountSentLD = _sendParam.amountLD;
        uint256 amountReceivedLD = _sendParam.amountLD;
        balanceOf[msg.sender] -= amountSentLD;
        msgReceipt = MessagingReceipt(keccak256(abi.encode(msg.sender, _to, amountSentLD, block.number)));
        oftReceipt = OFTReceipt(amountSentLD, amountReceivedLD);
        emit OFTSent(msgReceipt.guid, _sendParam.dstEid, msg.sender, amountSentLD, amountReceivedLD);
        _refundAddress;
        _fee;
    }
}
