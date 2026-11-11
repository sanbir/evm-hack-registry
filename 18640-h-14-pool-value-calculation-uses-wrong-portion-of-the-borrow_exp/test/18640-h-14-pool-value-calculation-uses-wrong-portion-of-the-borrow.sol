// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  GMX Synthetics — H-14 (Sherlock 2023-02, issue 131)
    MarketUtils.getPoolValue adds Precision.applyFactor(totalBorrowingFees,
    borrowingFeeReceiverFactor). That product is the fee receiver's slice.
    The pool's slice is totalBorrowingFees minus that product. The fix in
    gmx-synthetics PR 84 subtracts the receiver slice from the total.

    Here the pool holds 10,000 collateral plus 1,000 of collected borrowing
    fees. The receiver factor is 30%, so the receiver is owed 300 and the
    pool is owed 700. The buggy pool value is 10,300. The fair value is
    10,700. A full withdrawal pays 10,300 and leaves the LP 400 short.
*/

library Precision {
    uint256 internal constant FLOAT_PRECISION = 10 ** 30;

    function applyFactor(uint256 value, uint256 factor) internal pure returns (uint256) {
        return (value * factor) / FLOAT_PRECISION;
    }
}

contract Usd {
    string public symbol = "USD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MarketBase {
    uint256 public constant BASE = 10_000e18;
    uint256 public constant FEES = 1_000e18;
    uint256 public constant RECEIVER_FACTOR = 3 * 10 ** 29;
    uint256 public constant SUPPLY = 10_000e18;

    Usd public immutable token;
    uint256 public longTokenUsd;
    uint256 public shortTokenUsd;
    uint256 public borrowingFeesLong;
    uint256 public borrowingFeesShort;
    uint256 public borrowingFeeReceiverFactor;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    uint256 public poolValue;
    uint256 public fairPoolValue;
    uint256 public paid;

    constructor(Usd _token) {
        token = _token;
    }

    function seed(address lp) external {
        longTokenUsd = BASE / 2;
        shortTokenUsd = BASE / 2;
        borrowingFeesLong = FEES / 2;
        borrowingFeesShort = FEES / 2;
        borrowingFeeReceiverFactor = RECEIVER_FACTOR;
        totalSupply = SUPPLY;
        balanceOf[lp] = SUPPLY;
        token.mint(address(this), BASE + FEES);
    }

    function _receiverSlice() internal view returns (uint256) {
        return Precision.applyFactor(borrowingFeesLong + borrowingFeesShort, borrowingFeeReceiverFactor);
    }

    function _fairValue() internal view returns (uint256) {
        uint256 fees = borrowingFeesLong + borrowingFeesShort;
        return longTokenUsd + shortTokenUsd + fees - Precision.applyFactor(fees, borrowingFeeReceiverFactor);
    }

    function getPoolValue() public view virtual returns (uint256) {}

    function withdraw(address lp) external {
        uint256 value = getPoolValue();
        poolValue = value;
        fairPoolValue = _fairValue();
        uint256 shares = balanceOf[lp];
        paid = (value * shares) / totalSupply;
        balanceOf[lp] = 0;
        totalSupply -= shares;
        token.transfer(lp, paid);
    }
}

contract Market is MarketBase {
    constructor(Usd _token) MarketBase(_token) {}

    function getPoolValue() public view override returns (uint256) {
        uint256 value = longTokenUsd + shortTokenUsd;
        uint256 totalBorrowingFees = borrowingFeesLong;
        totalBorrowingFees += borrowingFeesShort;
        uint256 borrowingFeeReceiverFactor_ = borrowingFeeReceiverFactor;
        value += Precision.applyFactor(totalBorrowingFees, borrowingFeeReceiverFactor_); // @> VULN: fee-receiver slice added as pool value
        return value;
    }
}

contract MarketFixed is MarketBase {
    constructor(Usd _token) MarketBase(_token) {}

    function getPoolValue() public view override returns (uint256) {
        uint256 value = longTokenUsd + shortTokenUsd;
        uint256 totalBorrowingFees = borrowingFeesLong + borrowingFeesShort;
        uint256 receiver = Precision.applyFactor(totalBorrowingFees, borrowingFeeReceiverFactor);
        value += totalBorrowingFees - receiver;
        return value;
    }
}

contract Exploit {
    Usd public token;
    Market public market;

    constructor() {
        token = new Usd();
        market = new Market(token);
    }

    function run() external {
        market.seed(msg.sender);
        uint256 receiverSlice = Precision.applyFactor(market.FEES(), market.RECEIVER_FACTOR());
        require(receiverSlice == 300e18, "receiver slice");
        market.withdraw(msg.sender);
        require(market.poolValue() == 10_300e18, "buggy value");
        require(market.fairPoolValue() == 10_700e18, "fair value");
        require(market.paid() == 10_300e18, "withdrawn");
        require(token.balanceOf(msg.sender) == 10_300e18, "lp balance");
        require(market.fairPoolValue() - market.paid() == 400e18, "short 400");
        require(token.balanceOf(address(market)) == 700e18, "pool slice left behind");
    }
}
