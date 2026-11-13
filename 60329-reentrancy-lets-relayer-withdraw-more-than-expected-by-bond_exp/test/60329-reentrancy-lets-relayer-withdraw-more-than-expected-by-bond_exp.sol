// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, CallbackToken, BondManagerFixed} from "./60329-reentrancy-lets-relayer-withdraw-more-than-expected-by-bond.sol";

interface IRecv {
    function onTokenReceived(address from, uint256 amount) external;
}

contract RelayerFixed {
    BondManagerFixed public bond;
    CallbackToken public token;
    uint256 public constant AMOUNT = 30 ether;

    constructor(BondManagerFixed _bond, CallbackToken _token) {
        bond = _bond;
        token = _token;
    }

    function onTokenReceived(address, uint256) external {
        if (token.balanceOf(address(bond)) >= AMOUNT) {
            try bond.finalizeWithdrawalBond() {} catch {}
        }
    }

    function go() external {
        bond.executeWithdrawBond(AMOUNT);
        bond.finalizeWithdrawalBond();
    }
}

contract Finding60329Test is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    function test_exploit_pulls_90_of_100() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.pulled(), 90 ether, "three withdrawals of 30");
        assertEq(e.token().balanceOf(ATTACKER), 90 ether, "attacker balance");
        assertEq(e.token().balanceOf(address(e.bond())), 10 ether, "only 100 % 30 left");
        assertEq(e.pulled() - 30 ether, 60 ether, "60 taken beyond the one allowed withdrawal");
    }

    function test_control_only_one_withdrawal() public {
        CallbackToken token = new CallbackToken();
        BondManagerFixed bond = new BondManagerFixed(token);
        RelayerFixed relayer = new RelayerFixed(bond, token);
        bond.depositFor(address(relayer), 30 ether);
        bond.depositFor(address(0x8888), 70 ether);
        relayer.go();
        assertEq(token.balanceOf(address(relayer)), 30 ether, "only A");
        assertEq(token.balanceOf(address(bond)), 70 ether, "victim bond intact");
        assertEq(bond.totalLocked(), 70 ether, "accounting matches");
    }
}
