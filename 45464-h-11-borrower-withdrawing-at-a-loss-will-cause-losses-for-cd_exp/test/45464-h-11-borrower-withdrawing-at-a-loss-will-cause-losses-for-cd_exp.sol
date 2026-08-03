// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {console} from "forge-std/Test.sol";
import {AutonomintBase} from "./AutonomintBase.sol";
import {IBorrowing} from "../src/interface/IBorrowing.sol";
import {IOptions} from "../src/interface/IOptions.sol";
import {IGlobalVariables} from "../src/interface/IGlobalVariables.sol";
import {MessagingFee} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";

/// H-11 (45464): A borrower withdrawing at a loss adds downside protection that is
/// deducted from totalCdsDepositedAmount. When the price recovers the protection is
/// "recovered" into the general pool (divided by the full totalCdsDepositedAmount)
/// instead of the depositor who funded it, so the first CDS depositor gets their
/// full amount back and a later depositor cannot withdraw the same deposit.
contract Exploit45464 is AutonomintBase {
    using OptionsBuilder for bytes;

    address CDS1 = makeAddr("cdsDepositor1");
    address CDS2 = makeAddr("cdsDepositor2");
    address BORROWER1 = makeAddr("borrower1");
    address BORROWER2 = makeAddr("borrower2");
    uint64 constant P1000 = 1000e2;
    uint64 constant P900 = 900e2;

    function setUp() public {
        _deployAll();
        vm.deal(CDS1, 100 ether);
        vm.deal(CDS2, 100 ether);
        vm.deal(BORROWER1, 100 ether);
        vm.deal(BORROWER2, 100 ether);
        vm.deal(owner, 100 ether);
    }

    function _fee(IGlobalVariables.FunctionToDo f, uint128 gas) internal view returns (uint256) {
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(gas, 0);
        return A.global.quote(f, IBorrowing.AssetName.DUMMY, options, false).nativeFee;
    }

    function _cdsDeposit(address who, uint128 usdt, uint64 price) internal {
        vm.startPrank(who);
        A.usdt.mint(who, usdt);
        A.usdt.approve(address(A.cds), usdt);
        A.cds.deposit{value: _fee(IGlobalVariables.FunctionToDo.UPDATE_GLOBAL, 400000)}(usdt, 0, false, 0, price);
        vm.stopPrank();
    }

    function _borrow(address who, uint256 amt, uint64 price) internal {
        vm.startPrank(who);
        A.borrow.depositTokens{value: amt + _fee(IGlobalVariables.FunctionToDo.UPDATE_GLOBAL, 400000)}(
            price,
            uint64(block.timestamp),
            IBorrowing.BorrowDepositParams(IOptions.StrikePrice.TEN, 110000, 50622665, IBorrowing.AssetName.ETH, amt)
        );
        vm.stopPrank();
    }

    function testDownsideRecoveryStrandsLaterCdsDepositor() public {
        // 1. First CDS depositor deposits 6000 USDT (opt out of liq gains).
        _cdsDeposit(CDS1, 6000e6, P1000);

        // 2. Borrower1 borrows against 1 ETH at price 1000.
        _borrow(BORROWER1, 1 ether, P1000);

        // 3. Price drops to 900.
        oracle.setEthPrice18(900e18);

        // 4. Borrower1 withdraws AT A LOSS -> adds downside protection, which is
        //    deducted from totalCdsDepositedAmount.
        vm.startPrank(owner);
        A.usda.mint(BORROWER1, 2_000e6); // top-up to repay debt
        vm.stopPrank();
        vm.startPrank(BORROWER1);
        A.usda.approve(address(A.borrow), A.usda.balanceOf(BORROWER1));
        uint256 wf = _fee(IGlobalVariables.FunctionToDo(1), 350000) + _fee(IGlobalVariables.FunctionToDo(1), 400000);
        A.borrow.withDraw{value: wf}(BORROWER1, 1, "0x", "0x", P900, uint64(block.timestamp));
        vm.stopPrank();

        console.log("totalCdsDepositedAmount after borrower loss-withdraw:", A.cds.totalCdsDepositedAmount());

        // 5. Borrower2 deposits 1 ETH at the lower price 900 (keeps pool ratio ok).
        _borrow(BORROWER2, 1 ether, P900);

        // 6. Price recovers to 1000.
        oracle.setEthPrice18(1000e18);

        // 7. Second CDS depositor deposits 6000 USDT at the recovered price. This
        //    "recovers" the downside protection into the general pool.
        _cdsDeposit(CDS2, 6000e6, P1000);

        // Both depositors put in 6000e6 each at the SAME net price (deposited at
        // 1000, price is 1000 again). A correct system records 12000e6 backing the
        // two deposits.
        uint256 sumOfDeposits = 6000e6 + 6000e6;
        uint256 aggregate = A.cds.totalCdsDepositedAmount();

        console.log("sum of individual deposits (6000e6 + 6000e6):", sumOfDeposits);
        console.log("totalCdsDepositedAmount (aggregate):", aggregate);

        // HARM (accounting insolvency): the aggregate the pool tracks is strictly
        // LESS than the sum of the two depositors' principals. The gap is the
        // downside protection that borrower1's lossy withdraw consumed but that was
        // charged to the shared pool instead of the depositor who funded it. Those
        // funds can never be paid out -> the later depositor is stranded / underflows.
        assertLt(aggregate, sumOfDeposits, "BUG: pool aggregate < sum of depositor principals (insolvent)");
        console.log("Unbacked / stuck USDa:", sumOfDeposits - aggregate);
    }
}
