// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    Dai,
    GTokenVault,
    GnsDiamondFixed,
    ITradingStorage,
    ITradingCallbacks,
    IUpdatePositionSizeUtils
} from "./58130-h-03-decrease-positions-updatetradesuccess-will-use-wrong-av.sol";

contract Finding58130Test is Test {
    function test_exploit_wrong_available_collateral() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.token().balanceOf(e.TRADER()), 550e18, "trader credited 550 DAI");
        assertEq(e.diamond().vaultDebited(), 150e18, "vault debited 150");
        assertEq(e.diamond().fairVaultDebit(), 190e18, "fair vault debit is 190");
        assertEq(e.diamond().otherDebited(), 40e18, "other depositors debited 40");
        assertEq(e.vault().token().balanceOf(address(e.vault())), 850e18, "vault kept 40 it should have paid");
        assertEq(e.token().balanceOf(address(e.diamond())), 1560e18, "diamond is 40 short of 1600");
    }

    function test_control_subtracts_closing_fee() public {
        Dai token = new Dai();
        GTokenVault vault = new GTokenVault(token);
        GnsDiamondFixed fixedDiamond = new GnsDiamondFixed(token, vault);

        uint256 position = 1000e18;
        uint256 other = 1000e18;
        uint256 available = 400e18;
        uint256 sent = 550e18;
        uint256 fee = 40e18;
        uint256 vaultFund = 1000e18;
        address trader = address(0xBEEF);

        token.mint(address(this), position + other + vaultFund);
        token.transfer(address(vault), vaultFund);
        token.approve(address(fixedDiamond), position + other);
        fixedDiamond.fundPosition(position, other);

        ITradingStorage.Trade memory existingTrade = ITradingStorage.Trade({
            user: trader,
            index: 1,
            collateralIndex: 1,
            pairIndex: 0,
            collateralAmount: uint120(position),
            leverage: 5_000,
            openPrice: 1e10,
            long: true,
            isCounterTrade: false
        });
        IUpdatePositionSizeUtils.DecreasePositionSizeValues memory values;
        values.closingFeeCollateral = fee;
        values.newCollateralAmount = position - available;
        values.newLeverage = 5_000;
        values.existingPnlCollateral = int256(sent - available);
        values.availableCollateralInDiamond = available;
        values.collateralSentToTrader = int256(sent);
        ITradingCallbacks.AggregatorAnswer memory answer =
            ITradingCallbacks.AggregatorAnswer({orderId: 1, current: 1.1e10, price: 1.1e10});

        fixedDiamond.updateTradeSuccess(existingTrade, values, answer);

        assertEq(token.balanceOf(trader), 550e18, "control still credits the trader 550");
        assertEq(fixedDiamond.vaultDebited(), 190e18, "control debits the vault 190");
        assertEq(fixedDiamond.fairVaultDebit(), 190e18, "fair pull");
        assertEq(fixedDiamond.otherDebited(), 0, "other depositors debited 0");
        assertEq(fixedDiamond.availablePassed(), 360e18, "passed available minus fee");
        assertEq(token.balanceOf(address(vault)), 810e18, "vault paid the extra 40");
        assertEq(token.balanceOf(address(fixedDiamond)), 1600e18, "600 remaining + 1000 other");
    }
}
