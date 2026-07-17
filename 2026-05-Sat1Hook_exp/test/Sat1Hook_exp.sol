// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../basetest.sol";

// @KeyInfo - Confirmed protocol loss : none demonstrated
// Triggering Seller : 0x00aac9a393ddd5504682a7077b733047ba3e5e10
// MEV Searcher : 0x612511ea2945c045b892e67d4802c865abb21ac1
// MEV Contract : 0x3774b788224a8c358e027139c301be8e5ba42c44
// Vulnerable / Reviewed Contract : 0x2a0a30dd78af7698e6f40212b8b8324fce2ee888
// Triggering Sell Tx : https://etherscan.io/tx/0xd7808d5755010cb12150ad0917b5e39d90bc9a35400ec79816fd3952812ca2b3
// Linked Backrun Tx : https://etherscan.io/tx/0xc3ec96153353c32e4ab203d086a0618a2c7e666223c008c6ebc0a6f6c39c5420

// @Analysis
// This forensic reproduction rejects the initial loss hypothesis. The triggering seller burns
// 172,796.820481397784 SAT1 and receives 11.670888368430349639 ETH exactly as the curve specifies.
// That address had paid 223 ETH across 48 earlier hook buys for this inventory; the redemption is
// not attacker profit. The immediately following linked transaction is an MEV backrun whose contract
// gains 0.006516037423174481 ETH while Sat1Hook itself gains 1.042328435113795974 ETH.
//
// The reviewed design does contain sharp edges: `swapper` comes from unauthenticated hookData and is
// used by the early-block entropy multiplier and lastBuyBlock cooldown. Those controls are grindable
// and spoofable, but the cited transactions do not prove that they caused a protocol loss.

address constant SELLER = 0x00Aac9A393Ddd5504682A7077b733047BA3e5e10;
address constant SWAP_ROUTER = 0x9c65d15a671d814ef7bE25418fD46139E7366c07;
address constant SAT1_HOOK = 0x2a0A30dd78aF7698E6f40212b8B8324fcE2ee888;
address constant SAT1_TOKEN = 0x8f66337a0c2A02202fd91Dd596c411CF977c6060;

interface IERC20View {
    function balanceOf(address account) external view returns (uint256);
}

interface ISat1Hook {
    function ethCum() external view returns (uint256);
}

interface ISat1SwapRouter {
    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    function sell(PoolKey calldata key, uint256 sat1In, uint256 minEthOut) external returns (int256 delta);
}

contract Sat1Hook_exp is BaseTestWithBalanceLog {
    uint256 private constant FORK_BLOCK = 25_050_730;
    uint256 private constant SAT1_IN = 172_796_820_481_397_784_000_000;
    uint256 private constant HISTORICAL_MIN_ETH_OUT = 11_530_347_357_617_498_005;
    uint256 private constant EXPECTED_GROSS_ETH_OUT = 11_670_888_368_430_349_639;

    ISat1SwapRouter private constant router = ISat1SwapRouter(SWAP_ROUTER);
    ISat1Hook private constant hook = ISat1Hook(SAT1_HOOK);
    IERC20View private constant sat1 = IERC20View(SAT1_TOKEN);

    function setUp() public {
        vm.createSelectFork("http://127.0.0.1:8545", FORK_BLOCK);
        fundingToken = address(0);
        attacker = SELLER;

        vm.label(SELLER, "Triggering Seller");
        vm.label(SWAP_ROUTER, "Sat1 Swap Router");
        vm.label(SAT1_HOOK, "Sat1Hook");
        vm.label(SAT1_TOKEN, "SAT1 Token");
        vm.label(0x000000000004444c5dc75cB358380D2e3dE08A90, "Uniswap v4 PoolManager");
    }

    function testExploit() public balanceLog {
        uint256 sellerEthBefore = SELLER.balance;
        uint256 hookEthBefore = SAT1_HOOK.balance;
        uint256 ethCumBefore = hook.ethCum();
        uint256 sat1Before = sat1.balanceOf(SELLER);
        assertEq(sat1Before, SAT1_IN, "historical SAT1 inventory");

        ISat1SwapRouter.PoolKey memory key = ISat1SwapRouter.PoolKey({
            currency0: address(0), currency1: SAT1_TOKEN, fee: 3000, tickSpacing: 60, hooks: SAT1_HOOK
        });

        vm.prank(SELLER);
        router.sell(key, SAT1_IN, HISTORICAL_MIN_ETH_OUT);

        uint256 grossEthOut = SELLER.balance - sellerEthBefore;
        uint256 hookReserveDecrease = hookEthBefore - SAT1_HOOK.balance;
        uint256 ethCumDecrease = ethCumBefore - hook.ethCum();

        emit log_named_decimal_uint("Gross ETH redemption", grossEthOut, 18);
        emit log_named_decimal_uint("Hook ETH balance decrease", hookReserveDecrease, 18);
        emit log_named_decimal_uint("Hook ethCum decrease", ethCumDecrease, 18);
        emit log_named_decimal_uint("SAT1 burned", sat1Before - sat1.balanceOf(SELLER), 18);

        assertEq(grossEthOut, EXPECTED_GROSS_ETH_OUT, "historical gross ETH redemption");
        assertEq(hookReserveDecrease, EXPECTED_GROSS_ETH_OUT, "hook reserve decrease");
        assertEq(ethCumDecrease, EXPECTED_GROSS_ETH_OUT, "curve accounting decrease");
        assertEq(sat1.balanceOf(SELLER), 0, "seller inventory burned");
    }
}
