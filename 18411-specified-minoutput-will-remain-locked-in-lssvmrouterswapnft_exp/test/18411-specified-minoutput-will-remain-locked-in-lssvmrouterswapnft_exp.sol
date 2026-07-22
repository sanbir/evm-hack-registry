// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./18411-specified-minoutput-will-remain-locked-in-lssvmrouterswapnft.sol";

/*//////////////////////////////////////////////////////////////////////////
    Cyfrin Sudoswap finding #18411 — "Specified `minOutput` will remain locked
    in LSSVMRouter::swapNFTsForSpecificNFTsThroughETH".

    Fully local, no fork, no RPC, no cheatcode-funded balances. The synthetic
    `Exploit` deploys a MockWETH / MockNFT / MockPair / LSSVMRouter, plays the
    user "Alice", and demonstrates that a non-zero `minOutput` slippage guard is
    silently stranded in the router.
//////////////////////////////////////////////////////////////////////////*/
contract MinOutputLockedTest is Test {
    /// @notice The attack/harm path: Alice does a legit NFT->NFT swap with a
    ///         0.79 ether minOutput and loses exactly that to the router.
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        // Re-assert the harm from the test's vantage point.
        MockWETH weth = e.weth();
        MockNFT nft = e.nft();
        LSSVMRouter router = e.router();

        // Alice received the specific NFT she paid for — the swap "worked".
        assertEq(nft.ownerOf(e.BUY_ID()), address(e), "alice should own the bought NFT");

        // Exactly minOutput (0.79 ether) is frozen in the router, unreachable.
        assertEq(weth.balanceOf(address(router)), e.MIN_OUTPUT(), "router must hold locked minOutput");
        assertEq(weth.balanceOf(address(router)), 0.79 ether, "locked amount == 0.79 ether");

        // Alice was refunded only 0.21 ether where a correct router refunds 1.0.
        uint256 fairRefund = (e.SALE_PRICE() + e.MSG_VALUE()) - e.SPOT_PRICE(); // 1.0 ether
        assertEq(e.aliceRefund(), 0.21 ether, "alice got shorted refund");
        assertEq(fairRefund - e.aliceRefund(), e.MIN_OUTPUT(), "shortfall equals the locked minOutput");

        emit log_named_decimal_uint("router locked (frozen) WETH", weth.balanceOf(address(router)), 18);
        emit log_named_decimal_uint("alice actual refund       ", e.aliceRefund(), 18);
        emit log_named_decimal_uint("alice fair refund         ", fairRefund, 18);
    }

    /// @notice Control: with minOutput = 0 the router refunds the full surplus
    ///         and nothing is stranded — proving the deduction is what locks funds.
    function test_zeroMinOutput_locksNothing() public {
        // Rebuild the same scene by hand with minOutput = 0.
        MockWETH weth = new MockWETH();
        MockNFT nft = new MockNFT();
        MockPair pair = new MockPair(nft, weth, 0.9 ether, 0.9 ether);
        LSSVMRouter router = new LSSVMRouter(weth);

        // pool inventory + user funds
        nft.mint(address(pair), 4);
        weth.mint(address(pair), 100 ether);
        nft.mint(address(this), 1);
        weth.mint(address(this), 1 ether);

        nft.setApprovalForAll(address(pair), true);
        weth.approve(address(router), type(uint256).max);

        uint256[] memory sellIds = new uint256[](1);
        sellIds[0] = 1;
        uint256[] memory buyIds = new uint256[](1);
        buyIds[0] = 4;

        LSSVMRouter.PairSwapSpecific[] memory nftToToken = new LSSVMRouter.PairSwapSpecific[](1);
        nftToToken[0] = LSSVMRouter.PairSwapSpecific({pair: pair, nftIds: sellIds});
        LSSVMRouter.PairSwapSpecific[] memory tokenToNFT = new LSSVMRouter.PairSwapSpecific[](1);
        tokenToNFT[0] = LSSVMRouter.PairSwapSpecific({pair: pair, nftIds: buyIds});
        LSSVMRouter.NFTsForSpecificNFTsTrade memory trade =
            LSSVMRouter.NFTsForSpecificNFTsTrade({nftToTokenTrades: nftToToken, tokenToNFTTrades: tokenToNFT});

        router.swapNFTsForSpecificNFTsThroughETH(trade, 0, address(this), address(this), 1 ether);

        // With minOutput = 0 the router refunds the entire surplus: nothing stuck.
        assertEq(weth.balanceOf(address(router)), 0, "router should hold nothing when minOutput == 0");
        assertEq(nft.ownerOf(4), address(this), "should own the bought NFT");
        // Full surplus refunded: 0.9 (sale) + 1.0 (value) - 0.9 (buy) = 1.0 ether.
        assertEq(weth.balanceOf(address(this)), 1 ether, "full surplus refunded");
    }
}
