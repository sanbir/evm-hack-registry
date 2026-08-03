// SPDX-License-Identifier: MIT
pragma solidity 0.5.11;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Detailed } from "@openzeppelin/contracts/token/ERC20/ERC20Detailed.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { CompoundStrategy } from "../src/strategies/CompoundStrategy.sol";

// -----------------------------------------------------------------------------
// AuditVault #18210 - Origin Dollar (Trail of Bits TOB-OUSD-019)
// "Lack of return value checks can lead to unexpected results"
//
// Vulnerable line (real audited source, commit 06ed1650, parent of the fix
// ed83f5d6 "[TOB-OUSD-019] Check return values of external contract calls"):
//
//   src/strategies/CompoundStrategy.sol : liquidate()  (L73-L87)
//       cToken.redeem(cToken.balanceOf(address(this)));   // <-- return IGNORED
//
// Compound's cToken.redeem returns an ERROR CODE (0 = success, non-zero = error)
// and DOES NOT revert when a redemption fails (e.g. the market has no cash to pay
// out - TOKEN_INSUFFICIENT_CASH = 9). Because the audited strategy never checks
// the returned code, a FAILED redemption is treated as SUCCESS: liquidate() runs
// to completion without reverting while 0 underlying is actually withdrawn, and the
// deposited funds stay stranded in Compound. The fix wraps the call in
// `require(cToken.redeem(...) == 0, "Redeem failed")`, which makes the same call
// REVERT and surface the failure.
//
// This PoC deploys the REAL audited CompoundStrategy + InitializableAbstractStrategy
// + Governable, a minimal opaque ERC20 (USDC), and a faithful Compound cToken that
// reproduces the error-code-on-insufficient-cash semantics. It then proves the
// concrete harm with numbers.
// -----------------------------------------------------------------------------

/// @dev Minimal opaque underlying token (real ERC20, 6 decimals like USDC).
contract MockUSDC is ERC20, ERC20Detailed {
    constructor() public ERC20Detailed("USD Coin", "USDC", 6) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Faithful minimal Compound CErc20. Mirrors the two behaviours the exploit
///      depends on and that the audited strategy relies upon:
///        * mint  : pulls underlying, credits cTokens = amount * 1e18 / exchangeRate
///        * redeem: returns underlying IF the market holds enough cash, otherwise
///                  returns error code 9 (TOKEN_INSUFFICIENT_CASH) WITHOUT reverting,
///                  WITHOUT burning cTokens and WITHOUT transferring anything - exactly
///                  as the real CToken.redeemFresh() does.
contract MockCErc20 {
    uint256 internal constant NO_ERROR = 0;
    uint256 internal constant TOKEN_INSUFFICIENT_CASH = 9; // Compound Error enum index

    IERC20 public underlying;
    uint256 public exchangeRate; // scaled by 1e18
    mapping(address => uint256) public balanceOf; // cToken balances (auto getter == ICERC20.balanceOf)
    uint256 public lastRedeemError;

    constructor(IERC20 _underlying, uint256 _exchangeRate) public {
        underlying = _underlying;
        exchangeRate = _exchangeRate;
    }

    function exchangeRateStored() external view returns (uint256) {
        return exchangeRate;
    }

    function supplyRatePerBlock() external view returns (uint256) {
        return 0;
    }

    function balanceOfUnderlying(address owner) external returns (uint256) {
        return (balanceOf[owner] * exchangeRate) / 1e18;
    }

    /// @dev cash currently held by the market (available for redemptions).
    function getCash() public view returns (uint256) {
        return underlying.balanceOf(address(this));
    }

    function mint(uint256 mintAmount) external returns (uint256) {
        require(
            underlying.transferFrom(msg.sender, address(this), mintAmount),
            "mint transferFrom failed"
        );
        uint256 cTokens = (mintAmount * 1e18) / exchangeRate;
        balanceOf[msg.sender] += cTokens;
        return NO_ERROR;
    }

    function redeem(uint256 redeemTokens) external returns (uint256) {
        uint256 redeemAmount = (redeemTokens * exchangeRate) / 1e18;
        // Real Compound: if the market lacks cash, fail() returns an error code
        // and the function returns WITHOUT reverting and WITHOUT any state change.
        if (getCash() < redeemAmount) {
            lastRedeemError = TOKEN_INSUFFICIENT_CASH;
            return TOKEN_INSUFFICIENT_CASH;
        }
        balanceOf[msg.sender] -= redeemTokens;
        require(underlying.transfer(msg.sender, redeemAmount), "redeem transfer failed");
        lastRedeemError = NO_ERROR;
        return NO_ERROR;
    }

    function redeemUnderlying(uint256 redeemAmount) external returns (uint256) {
        if (getCash() < redeemAmount) {
            return TOKEN_INSUFFICIENT_CASH;
        }
        uint256 redeemTokens = (redeemAmount * 1e18) / exchangeRate;
        balanceOf[msg.sender] -= redeemTokens;
        require(underlying.transfer(msg.sender, redeemAmount), "redeemUnderlying transfer failed");
        return NO_ERROR;
    }

    /// @dev Models a Compound borrower drawing cash out of the market, so a
    ///      subsequent redemption finds insufficient cash (a real, common state
    ///      for a highly-utilised money market).
    function borrowCashOut(address to, uint256 amount) external {
        require(underlying.transfer(to, amount), "borrow transfer failed");
    }
}

contract PoC_18210 {
    uint256 internal constant EXCHANGE_RATE = 2e14; // ~ real cUSDC exchange rate
    uint256 internal constant DEPOSIT = 100e6; // 100 USDC (6 decimals)
    uint256 internal constant EXPECTED_CTOKENS = 5e11; // 100e6 * 1e18 / 2e14
    address internal constant BORROWER = address(0xB0B);

    MockUSDC internal usdc;
    MockCErc20 internal cToken;
    CompoundStrategy internal strategy;

    // This contract is the strategy's Governor (set in Governable's constructor via
    // the strategy deploy below) AND its Vault - so it can both deposit and liquidate.
    function setUp() public {
        usdc = new MockUSDC();
        cToken = new MockCErc20(IERC20(address(usdc)), EXCHANGE_RATE);
        strategy = new CompoundStrategy(); // Governable: governor = msg.sender = this

        address[] memory assets = new address[](1);
        address[] memory pTokens = new address[](1);
        assets[0] = address(usdc);
        pTokens[0] = address(cToken);

        // vault = this (so this contract can call the onlyVault deposit()).
        strategy.initialize(address(cToken), address(this), address(0), assets, pTokens);

        // Fund the strategy and deposit 100 USDC into Compound (as the Vault).
        usdc.mint(address(strategy), DEPOSIT);
        strategy.deposit(address(usdc), DEPOSIT);
    }

    function test_liquidateIgnoresFailedCompoundRedeem() public {
        // --- Precondition: 100 USDC is invested in Compound via the strategy. ---
        require(cToken.balanceOf(address(strategy)) == EXPECTED_CTOKENS, "setup: cUSDC not minted");
        require(strategy.checkBalance(address(usdc)) == DEPOSIT, "setup: 100 USDC not invested");
        require(usdc.balanceOf(address(this)) == 0, "setup: vault not empty");

        // --- The Compound market becomes illiquid: a borrower draws out all cash. ---
        cToken.borrowCashOut(BORROWER, DEPOSIT);
        require(cToken.getCash() == 0, "setup: cToken cash not drained");

        // --- Governor calls liquidate() to pull ALL funds back to the Vault. ---
        // The real audited liquidate() ignores cToken.redeem's error code, so this
        // call does NOT revert even though the redemption fails.
        strategy.liquidate();

        // ===================== CONCRETE HARM (with numbers) =====================
        // 1) The redemption FAILED: Compound returned error code 9 (INSUFFICIENT_CASH)
        //    but the strategy ignored it and proceeded as if it succeeded.
        require(cToken.lastRedeemError() == 9, "HARM: redeem should have failed with code 9");

        // 2) The Vault received 0 of the 100 USDC liquidate() claimed to move.
        require(usdc.balanceOf(address(this)) == 0, "HARM: vault unexpectedly received funds");

        // 3) The 5000 cUSDC (= 100 USDC) were NOT burned - the funds are stranded in
        //    Compound while liquidate() reported success and returned normally.
        require(cToken.balanceOf(address(strategy)) == EXPECTED_CTOKENS, "HARM: cUSDC unexpectedly burned");
        require(strategy.checkBalance(address(usdc)) == DEPOSIT, "HARM: 100 USDC not stranded");

        // A fixed liquidate() (`require(cToken.redeem(...) == 0, "Redeem failed")`)
        // would have REVERTED here instead of silently reporting success.
    }
}
