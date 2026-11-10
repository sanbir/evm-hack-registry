// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    EywaToken,
    DistributionCreator,
    IDistributionCreator
} from "./44335-incorrect-logic-in-gaugev1notifyrewardamount-mixbytes-none-e.sol";

/// Pull amount_ in, then create the campaign for amount_ rather than the old balance.
contract GaugeV1Fixed {
    error UnauthorizedCaller();

    EywaToken public eywa;
    DistributionCreator public creator;
    address public manager;

    constructor(EywaToken _eywa, DistributionCreator _creator, address _manager) {
        eywa = _eywa;
        creator = _creator;
        manager = _manager;
    }

    function notifyRewardAmount(uint256 amount_) external {
        if (msg.sender != manager) revert UnauthorizedCaller();
        eywa.transferFrom(msg.sender, address(this), amount_);
        eywa.approve(address(creator), amount_);
        IDistributionCreator.CampaignParameters memory params;
        params.amount = amount_;
        creator.createCampaign(params);
    }
}

contract Finding44335Test is Test {
    address internal constant STAKER = 0x000000000000000000000000000000000000bEEF;

    function test_exploit_stakers_receive_200_instead_of_1000() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.campaignAmount(), 200e18, "campaign amount is the old gauge balance");
        assertEq(e.stakerReceived(), 200e18, "stakers received 200");
        assertEq(e.managerLeft(), 1000e18, "notified 1000 stayed with the manager");
        assertEq(e.NOTIFIED() - e.stakerReceived(), 800e18, "stakers were short 800");
    }

    function test_control_amount_pays_stakers_1000() public {
        EywaToken eywa = new EywaToken();
        DistributionCreator creator = new DistributionCreator(eywa, STAKER);
        GaugeV1Fixed gauge = new GaugeV1Fixed(eywa, creator, address(this));
        eywa.mint(address(gauge), 200e18);
        eywa.mint(address(this), 1000e18);
        eywa.approve(address(gauge), 1000e18);

        gauge.notifyRewardAmount(1000e18);

        assertEq(creator.lastAmount(), 1000e18, "campaign amount is amount_");
        assertEq(eywa.balanceOf(STAKER), 1000e18, "stakers received 1000");
        assertEq(eywa.balanceOf(address(this)), 0, "manager paid the 1000");
        assertEq(eywa.balanceOf(address(gauge)), 200e18, "pre-existing 200 stays in the gauge");
    }
}
