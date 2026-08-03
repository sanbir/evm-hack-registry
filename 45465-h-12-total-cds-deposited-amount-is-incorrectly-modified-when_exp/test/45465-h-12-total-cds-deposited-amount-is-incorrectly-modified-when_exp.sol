// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {console} from "forge-std/Test.sol";
import {AutonomintBase} from "./AutonomintBase.sol";
import {IBorrowing} from "../src/interface/IBorrowing.sol";
import {IOptions} from "../src/interface/IOptions.sol";
import {IGlobalVariables} from "../src/interface/IGlobalVariables.sol";
import {MessagingFee} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";

/// H-12 (45465): When a CDS depositor withdraws at a loss, CDSLib decrements
/// totalCdsDepositedAmount by the loss-adjusted return amount instead of the
/// original deposited amount, leaving the aggregate too high and desynchronised
/// from the sum of remaining individual deposits -> stuck / mis-accounted USDa.
contract Exploit45465 is AutonomintBase {
    using OptionsBuilder for bytes;

    address CDS1 = makeAddr("cdsDepositor1");
    address CDS2 = makeAddr("cdsDepositor2");
    address BORROWER = makeAddr("borrower");
    uint64 constant P1000 = 1000e2;
    uint64 constant P900 = 900e2;

    function setUp() public {
        _deployAll();
        vm.deal(CDS1, 100 ether);
        vm.deal(CDS2, 100 ether);
        vm.deal(BORROWER, 100 ether);
    }

    function _fee(uint32 chain, IGlobalVariables.FunctionToDo f, uint128 gas) internal view returns (uint256) {
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(gas, 0);
        MessagingFee memory fe = (chain == eidA ? A.global : B.global).quote(f, IBorrowing.AssetName.DUMMY, options, false);
        return fe.nativeFee;
    }

    function _cdsDeposit(address who, uint128 usdt) internal {
        vm.startPrank(who);
        A.usdt.mint(who, usdt);
        A.usdt.approve(address(A.cds), usdt);
        A.cds.deposit{value: _fee(eidA, IGlobalVariables.FunctionToDo.UPDATE_GLOBAL, 400000)}(usdt, 0, false, 0, P1000);
        vm.stopPrank();
    }

    function testTotalCdsDepositedDesyncOnLossyWithdraw() public {
        // 1. Two CDS depositors: 4000 and 6000 USDT (opt OUT of liquidation gains)
        _cdsDeposit(CDS1, 4000e6);
        _cdsDeposit(CDS2, 6000e6);

        uint256 totalAfterDeposits = A.cds.totalCdsDepositedAmount();
        console.log("totalCdsDepositedAmount after 2 deposits (expect 10000e6):", totalAfterDeposits);

        // 2. Borrower deposits 3 ETH at price 1000 on the SAME chain (creates
        //    borrower volume so a price drop produces a CDS loss). CDS pool
        //    10000 >= 2x borrower 3000.
        vm.startPrank(BORROWER);
        A.borrow.depositTokens{value: 3 ether + _fee(eidA, IGlobalVariables.FunctionToDo.UPDATE_GLOBAL, 400000)}(
            P1000,
            uint64(block.timestamp),
            IBorrowing.BorrowDepositParams(IOptions.StrikePrice.TEN, 110000, 50622665, IBorrowing.AssetName.ETH, 3 ether)
        );
        vm.stopPrank();

        // 3. ETH price drops 10% (1000 -> 900). CDS now covers borrower downside.
        oracle.setEthPrice18(900e18);

        // 4. CDS depositor 1 withdraws at the lower price -> takes a loss.
        vm.startPrank(CDS1);
        uint256 wfee = _fee(eidA, IGlobalVariables.FunctionToDo(2), 400000);
        uint256 usdaBefore = A.usda.balanceOf(CDS1);
        A.cds.withdraw{value: wfee}(1, P900, 0, 0, "0x");
        uint256 got = A.usda.balanceOf(CDS1) - usdaBefore;
        vm.stopPrank();

        uint256 totalAfterWithdraw = A.cds.totalCdsDepositedAmount();
        console.log("CDS1 deposited (USDT):            4000e6");
        console.log("CDS1 received on withdraw (USDa): ", got);
        console.log("totalCdsDepositedAmount after CDS1 lossy withdraw:", totalAfterWithdraw);
        console.log("CDS2 still owns (deposit):        6000e6");

        // HARM: the aggregate was decremented by the loss-adjusted return (< 4000),
        // so it remains ABOVE the 6000e6 that the only remaining depositor owns.
        // A correct implementation would leave exactly 6000e6.
        assertLt(got, 4000e6, "CDS1 must have taken a loss (returned < deposit)");
        assertGt(totalAfterWithdraw, 6000e6, "BUG: aggregate exceeds sum of remaining real deposits");
        console.log("Desync (stuck/over-counted USDa):", totalAfterWithdraw - 6000e6);
    }
}
