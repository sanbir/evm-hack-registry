// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    USDe,
    SUSDe,
    SupportedVault,
    PVault
} from "./57016-during-the-yield-phase-when-using-supported-vaults-users-can.sol";

contract PVaultFixed is PVault {
    constructor(USDe u, SUSDe s, SupportedVault v) PVault(u, s, v) {}

    function withdraw(address user, uint256 assets) public override returns (uint256) {
        require(yieldPhase, "phase");
        uint256 loose = usde.balanceOf(address(this));
        if (loose < assets) {
            uint256 need = assets - loose;
            uint256 have = supported.balanceOf(address(this));
            uint256 fromVault = need < have ? need : have;
            if (fromVault > 0) {
                supported.redeem(fromVault, address(this));
                need -= fromVault;
            }
            pulledFromSusde = need;
            if (need > 0) susde.withdraw(need, address(this));
        }
        usde.transfer(user, assets);
        shares[user] -= assets;
        return assets;
    }
}

contract Finding57016Test is Test {
    function test_exploit_pulls_600_from_susde() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.usde().balanceOf(address(e)), 600, "attacker extracted 600");
        assertEq(e.susde().balanceOf(address(e.p())), 400, "user1 is 600 short");
        assertEq(e.supported().balanceOf(address(e.p())), 600, "vault shares locked");
    }

    function test_control_pays_the_supported_share_and_leaves_susde() public {
        USDe usde = new USDe();
        SUSDe susde = new SUSDe(usde);
        SupportedVault supported = new SupportedVault(usde);
        PVaultFixed p = new PVaultFixed(usde, susde, supported);
        address user1 = address(0xA11CE);

        usde.mint(address(p), 1000);
        p.depositBase(user1, 1000);
        p.startYieldPhase();
        usde.mint(address(supported), 600);
        supported.credit(address(this), 600);
        p.depositSupported(address(this), 600);

        uint256 got = p.withdraw(address(this), 600);
        assertEq(got, 600, "user2 is paid their 600");
        assertEq(p.pulledFromSusde(), 0, "sUSDe was not touched");
        assertEq(susde.balanceOf(address(p)), 1000, "user1's 1000 sUSDe stays");
        assertEq(supported.balanceOf(address(p)), 0, "supported shares were redeemed");

        uint256 back = p.withdraw(user1, 1000);
        assertEq(back, 1000, "user1 withdraws 1000");
        assertEq(usde.balanceOf(user1), 1000, "user1 received 1000");
    }
}
