// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import "forge-std/Test.sol";
import {BorrowLiquidation} from "../src/Core_logic/borrowLiquidation.sol";
import {IBorrowing} from "../src/interface/IBorrowing.sol";
import {ITreasury} from "../src/interface/ITreasury.sol";

contract AutonomintTreasuryDouble {
    ITreasury.DepositDetails internal detail;
    bool public updated;

    function configure(address user, uint64 index, uint128 ethPrice, uint128 depositedEth) external {
        user; index;
        detail.ethPriceAtDeposit = ethPrice;
        detail.depositedAmountInETH = depositedEth;
        detail.liquidated = false;
        detail.assetName = IBorrowing.AssetName.ETH;
    }

    function getBorrowing(address, uint64) external view returns (ITreasury.GetBorrowingResult memory result) {
        result.totalIndex = 1;
        result.depositDetails = detail;
    }

    function updateDepositDetails(address, uint64, ITreasury.DepositDetails memory newDetail) external {
        updated = true;
        detail = newDetail;
    }

    function liquidated() external view returns (bool) { return detail.liquidated; }
}

contract AutonomintWETHDouble {
    uint256 public deposited;
    address public approvedSpender;
    uint256 public approvedAmount;

    receive() external payable {}
    function deposit() external payable { deposited += msg.value; }
    function approve(address spender, uint amount) external returns (bool) {
        approvedSpender = spender;
        approvedAmount = amount;
        return true;
    }
}

contract AutonomintWrapperDouble {
    uint256 public minted;
    function mint(uint amount) external { minted += amount; }
}

contract AutonomintSynthetixDouble {
    uint256 public exchanged;
    function exchange(bytes32, uint sourceAmount, bytes32) external returns (uint) {
        exchanged += sourceAmount;
        return sourceAmount;
    }
}

contract AutonomintPerpsDouble {
    int256 public margin;
    int256 public orderSize;
    uint256 public orderPrice;

    function transferMargin(int marginDelta) external { margin += marginDelta; }
    function submitOffchainDelayedOrder(int sizeDelta, uint desiredFillPrice) external {
        orderSize = sizeDelta;
        orderPrice = desiredFillPrice;
    }
}

contract AutonomintBorrowingCaller {
    function trigger(
        BorrowLiquidation liquidation,
        address user,
        uint64 index,
        uint64 currentPrice
    ) external payable {
        liquidation.liquidateBorrowPosition{value: msg.value}(
            user,
            index,
            currentPrice,
            IBorrowing.LiquidationType.TWO,
            0
        );
    }
}

contract PoC_45463_Type2LiquidationState is Test {
    function testType2LiquidationLeavesPositionWithdrawable() public {
        AutonomintTreasuryDouble treasury = new AutonomintTreasuryDouble();
        AutonomintWETHDouble weth = new AutonomintWETHDouble();
        AutonomintWrapperDouble wrapper = new AutonomintWrapperDouble();
        AutonomintSynthetixDouble synthetix = new AutonomintSynthetixDouble();
        AutonomintPerpsDouble perps = new AutonomintPerpsDouble();
        AutonomintBorrowingCaller borrowing = new AutonomintBorrowingCaller();

        address borrower = address(0xB0B);
        treasury.configure(borrower, 0, 1_000, 2 ether);

        BorrowLiquidation liquidation = new BorrowLiquidation();
        liquidation.initialize(
            address(borrowing),
            address(0),
            address(0),
            address(0),
            address(weth),
            address(wrapper),
            address(perps),
            address(synthetix)
        );
        liquidation.setTreasury(address(treasury));

        vm.deal(address(borrowing), 1 ether);
        borrowing.trigger{value: 1 ether}(liquidation, borrower, 0, 800);

        // The real liquidationType2 path opened the short-side hedge, but it
        // never persists depositDetail.liquidated = true. A later withdrawal
        // therefore still observes the position as active.
        assertFalse(treasury.liquidated(), "type-2 liquidation unexpectedly persisted state");
        assertFalse(treasury.updated(), "type-2 path should not update the deposit record");
        assertEq(weth.deposited(), 1 ether);
        assertEq(wrapper.minted(), 1 ether);
        assertEq(synthetix.exchanged(), 1 ether);
        assertGt(perps.margin(), 0);
        assertLt(perps.orderSize(), 0);
    }
}
