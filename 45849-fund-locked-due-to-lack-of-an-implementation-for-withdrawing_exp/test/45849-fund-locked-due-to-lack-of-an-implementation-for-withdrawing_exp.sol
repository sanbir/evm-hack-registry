// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    BandoFulfillableV1,
    BandoRouterFixed,
    FulFillmentRequest
} from "./45849-fund-locked-due-to-lack-of-an-implementation-for-withdrawing.sol";

contract OwnerWallet {
    receive() external payable {}

    function setFee(BandoRouterFixed router, uint256 fee) external {
        router.setService(1, fee, payable(address(0x2222222222222222222222222222222222222222)));
    }

    function takeFees(BandoRouterFixed router) external {
        router.withdrawServiceFees();
    }
}

contract Finding45849Test is Test {
    uint256 internal constant FEE = 1 ether;
    uint256 internal constant WEI_AMOUNT = 2 ether;

    function test_exploit_service_fee_stuck_in_router() public {
        Exploit e = new Exploit();
        vm.deal(address(this), 4 ether);
        e.run{value: WEI_AMOUNT + FEE}();

        assertEq(e.stuckFees(), FEE, "N fees recorded stuck");
        assertEq(address(e.router()).balance, FEE, "router still holds the fee");
        assertEq(address(e.escrow()).balance, WEI_AMOUNT, "escrow holds only weiAmount");
        assertFalse(e.withdrawExisted(), "fee withdraw does not exist");
    }

    function test_control_added_withdraw_pays_owner_the_fee() public {
        vm.deal(address(this), 4 ether);
        BandoFulfillableV1 escrow = new BandoFulfillableV1();
        OwnerWallet owner = new OwnerWallet();
        BandoRouterFixed router = new BandoRouterFixed(payable(address(escrow)), address(owner));
        owner.setFee(router, FEE);

        FulFillmentRequest memory request = FulFillmentRequest({
            payer: payable(address(this)),
            weiAmount: WEI_AMOUNT,
            fiatAmount: 100,
            serviceRef: "gift"
        });
        router.requestService{value: WEI_AMOUNT + FEE}(1, request);
        assertEq(address(router).balance, FEE, "precondition: N fees sitting");

        owner.takeFees(router);
        assertEq(address(owner).balance, FEE, "control pays the owner N");
        assertEq(address(router).balance, 0, "router emptied");
        assertEq(address(escrow).balance, WEI_AMOUNT, "principal stays escrowed");
    }
}
