// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Casimir — finalizeReport (Cyfrin, 2024-07-10)
    Report period 2 of the published PoC. Rewards are 64 ETH because
    reportRecoveredEffectiveBalance (0.2 ETH of slashing covered by operators)
    is not added. The withdrawal adjustment then underflows by 0.2 ETH and the
    report cannot be finalized. The fixed formula ends at 0.
    Fixed in casimirlabs/casimir-contracts eb31b4349e69eb401615e0eca253e9ab8cc0999d.
*/

contract CasimirManager {
    uint256 public reportRecoveredEffectiveBalance;
    uint256 public latestActiveBalanceAfterFee;
    uint256 public rewardsBuggy;
    uint256 public activeRewards;
    uint256 public startBal;
    uint256 public sweptRewards;
    uint256 public withdrawal;
    bool public finalized;

    function loadPeriod2() external {
        reportRecoveredEffectiveBalance = 0.2 ether; // STORY: recovered
        startBal = 32.1 ether;
        rewardsBuggy = 64 ether;
        activeRewards = 0.1 ether;
        sweptRewards = 64.2 ether;
        withdrawal = 32 ether;
        latestActiveBalanceAfterFee = startBal;
    }

    function finalizeReport() external {
        uint256 recovered = reportRecoveredEffectiveBalance; // STORY: read recovery
        int256 rewards = int256(rewardsBuggy); // @> VULN: reportRecoveredEffectiveBalance is omitted from rewards
        recovered;
        int256 change = rewards - int256(activeRewards); // STORY: change
        uint256 bal = startBal + uint256(change); // STORY: reward adj
        bal -= sweptRewards; // STORY: swept
        bal -= withdrawal; // STORY: withdrawal underflows by 0.2 ether
        latestActiveBalanceAfterFee = bal;
        finalized = true;
    }

    function finalizeReportFixed() external returns (uint256 bal) {
        int256 rewards = int256(rewardsBuggy + reportRecoveredEffectiveBalance);
        int256 change = rewards - int256(activeRewards);
        bal = startBal + uint256(change);
        bal -= sweptRewards;
        bal -= withdrawal;
        latestActiveBalanceAfterFee = bal;
        finalized = true;
    }
}

contract Exploit {
    CasimirManager public manager;
    bool public bricked;
    uint256 public fixedBalance;

    constructor() {
        manager = new CasimirManager();
    }

    function run() external {
        manager.loadPeriod2(); // STORY: load
        try manager.finalizeReport() {
            bricked = false;
        } catch {
            bricked = true; // STORY: catch
        }
        require(bricked, "finalized");
        require(manager.finalized() == false, "flag"); // STORY: harm
        // Control is not part of the attack. The forge test calls it on a fresh manager.
    }
}
