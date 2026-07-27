// SPDX-License-Identifier: MIT
pragma solidity 0.7.6;
pragma experimental ABIEncoderV2;

import "forge-std/Test.sol";
import {OpenLevV1Lib} from "../src/poc/OpenLevV1Lib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev A protocol-boundary WETH double.  The vulnerable code only relies on
/// the historical withdraw() callback and on the WETH contract holding ETH.
contract WETH42441 {
    receive() external payable {}

    function withdraw(uint256 amount) external {
        require(address(this).balance >= amount, "insufficient WETH backing");
        (bool sent, ) = msg.sender.call{value: amount}("");
        require(sent, "WETH send failed");
    }
}

/// @dev A contract recipient whose receive path cannot run inside Solidity's
/// 2300-gas transfer stipend.  This is the real class of recipient that the
/// audited OpenLevV1Lib.doTransferOut implementation rejects.
contract GasHungryRecipient42441 {
    uint256 public received;

    receive() external payable {
        require(gasleft() > 2300, "recipient needs more than transfer stipend");
        received += msg.value;
    }
}

contract PoC_42441_OpenLevTransferOut is Test {
    WETH42441 private weth;
    GasHungryRecipient42441 private recipient;

    function setUp() public {
        weth = new WETH42441();
        recipient = new GasHungryRecipient42441();
        vm.deal(address(weth), 1 ether);
    }

    function testDoTransferOutRevertsForContractRecipient() public {
        vm.expectRevert();
        OpenLevV1Lib.doTransferOut(
            address(recipient),
            IERC20(address(weth)),
            address(weth),
            1 ether
        );

        assertEq(address(recipient).balance, 0, "stipend failure must not deliver ETH");
        assertEq(recipient.received(), 0, "recipient fallback did not execute");
        assertEq(address(weth).balance, 1 ether, "reverted transfer restores WETH backing");
    }
}
