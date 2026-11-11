// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    AccountSystem,
    EscrowToken,
    NameNFT,
    GigaNameNFTBeforeUpdateHandler
} from "./53285-h-02-unauthorized-access-to-update-function-pashov-audit-gro.sol";

/// @dev Auditor fix: only GigaNameNFT may call update().
contract HandlerFixed {
    AccountSystem public accountSystem;
    NameNFT public nameNft;

    constructor(AccountSystem _account, NameNFT _nft) {
        accountSystem = _account;
        nameNft = _nft;
    }

    function update(address tokenContract, address to, uint256 tokenId, address) external {
        require(msg.sender == address(nameNft), "not name nft");
        NameNFT gigaNameNFT = NameNFT(tokenContract);
        if (gigaNameNFT.exists(tokenId)) {
            address prevOwner = gigaNameNFT.ownerOf(tokenId);
            if (prevOwner != address(0) && accountSystem.getPlayerUsernameId(prevOwner) == tokenId) {
                accountSystem.removeUsername(prevOwner);
            }
        }
        if (accountSystem.getPlayerUsernameId(to) == 0) {
            accountSystem.setUsername(to, tokenId);
        }
    }
}

contract Finding53285Test is Test {
    address internal constant VICTIM = address(0xBEEF);
    address internal constant STRANGER = address(0xA11CE);
    uint256 internal constant TOKEN_ID = 7;
    uint256 internal constant N = 100 ether;

    function test_exploit_takes_the_escrow() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.victimBefore(), N, "started at 100");
        assertEq(e.victimAfter(), 0, "victim escrow cleared");
        assertEq(e.taken(), N, "attacker withdrew 100");
        assertEq(e.token().balanceOf(address(e)), N, "100 ACCT on the attacker");
        assertEq(e.account().usernameId(address(e)), TOKEN_ID, "name record stolen");
        assertEq(e.account().usernameId(VICTIM), 0, "victim unlinked");
        assertEq(e.account().escrow(VICTIM), 0, "victim balance is 0");
    }

    function test_control_update_requires_the_name_nft() public {
        EscrowToken token = new EscrowToken();
        NameNFT nft = new NameNFT();
        AccountSystem account = new AccountSystem(token);
        HandlerFixed fixedHandler = new HandlerFixed(account, nft);
        account.setHandler(address(fixedHandler));

        nft.mint(VICTIM, TOKEN_ID);
        token.mint(address(this), N);
        token.approve(address(account), N);
        account.seed(VICTIM, TOKEN_ID, N);

        vm.prank(STRANGER);
        vm.expectRevert(bytes("not name nft"));
        fixedHandler.update(address(nft), STRANGER, TOKEN_ID, address(0));
        assertEq(account.escrow(VICTIM), N, "stranger moved nothing");
        assertEq(account.usernameId(VICTIM), TOKEN_ID, "victim still linked");

        vm.prank(address(nft));
        fixedHandler.update(address(nft), STRANGER, TOKEN_ID, address(0));
        assertEq(account.escrow(VICTIM), 0, "authorized call does clear the old row");
        assertEq(account.escrow(STRANGER), N, "and credits the transfer recipient");
    }
}
