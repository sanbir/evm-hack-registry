// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Velar Artha PerpDEX - fee precision (Sherlock 2024-08, H-1, finding 41278).
    SYNTHETIC, cheatcode-free. Quoted math.vy / params.vy / fees.vy:
      utilization = interest / (reserves / 100)          // whole percent
      scale       = (MAX_FEE * utilization) / 100
      apply       = (collateral * (rate * terms)) / DENOM
    DENOM = 1e9. MAX_FEE = 65. One year = 15_778_800 blocks.
    Open interest 1_099_999e18 against reserves 10_000_000e18 is 10.9999%.
    The integer path stores utilization 10 and rate 6.
    A year of borrow fee on 100_000e18 collateral is 9467.28e18.
    The same inputs with one final division pay 11281.83174378e18.
    LPs are short 1814.55174378e18. */

contract Token {
    string public name = "Collateral";
    string public symbol = "COLL";
    uint8 public decimals = 18;
    mapping(address => uint256) internal _bal;

    function balanceOf(address a) external view returns (uint256) {
        return _bal[a];
    }

    function mint(address to, uint256 n) external {
        _bal[to] += n;
    }

    function transfer(address to, uint256 n) external returns (bool) {
        _bal[msg.sender] -= n;
        _bal[to] += n;
        return true;
    }
}

contract Marker {
    string public name = "Unpaid borrow fee";
    string public symbol = "UNPAID";
    uint8 public decimals = 18;
    mapping(address => uint256) internal _bal;

    function balanceOf(address a) external view returns (uint256) {
        return _bal[a];
    }

    function mint(address to, uint256 n) external {
        _bal[to] += n;
    }
}

contract LpSink {}

contract FeeEngine {
    uint256 public constant DENOM = 1_000_000_000;
    uint256 public constant MAX_FEE = 65;
    uint256 public constant YEAR_BLOCKS = 15_778_800;
    uint256 public constant RESERVES = 10_000_000 ether;
    uint256 public constant INTEREST = 1_099_999 ether;
    uint256 public constant COLLATERAL = 100_000 ether;

    Token public token;
    address public lp;
    uint256 public util;
    uint256 public rate;
    uint256 public paid;
    uint256 public s1;
    uint256 public s2;
    uint256 public s3;

    constructor(address token_) {
        token = Token(token_);
    }

    function setLp(address lp_) external {
        lp = lp_;
    }

    function charge() external returns (uint256 fee) {
        uint256 reserves = RESERVES;
        uint256 interest = INTEREST;
        util = interest / (reserves / 100); // @> VULN: whole percent only. 10.9999 becomes 10.
        s1 = util;
        rate = (MAX_FEE * s1) / 100;
        s2 = s1 + rate;
        fee = (COLLATERAL * rate * YEAR_BLOCKS) / DENOM;
        paid = fee;
        s3 = s2 + paid;
        token.transfer(lp, fee);
    }
}

contract FeeEngineFixed {
    uint256 public constant DENOM = 1_000_000_000;
    uint256 public constant MAX_FEE = 65;
    uint256 public constant YEAR_BLOCKS = 15_778_800;
    uint256 public constant RESERVES = 10_000_000 ether;
    uint256 public constant INTEREST = 1_099_999 ether;
    uint256 public constant COLLATERAL = 100_000 ether;

    Token public token;
    address public lp;
    uint256 public paid;

    constructor(address token_, address lp_) {
        token = Token(token_);
        lp = lp_;
    }

    function charge() external returns (uint256 fee) {
        fee = (COLLATERAL * MAX_FEE * INTEREST * YEAR_BLOCKS) / (RESERVES * DENOM);
        paid = fee;
        token.transfer(lp, fee);
    }
}

contract Exploit {
    uint256 public constant COLLATERAL = 100_000 ether;
    uint256 public constant BUGGY = 9467280000000000000000;
    uint256 public constant FAIR = 11281831743780000000000;
    uint256 public constant SHORT = 1814551743780000000000;
    address public constant SINK = 0x000000000000000000000000000000000000D00d;

    Token public token;
    FeeEngine public engine;
    Marker public marker;
    address public lp;

    uint256 public b0;
    uint256 public b1;
    uint256 public fairPaid;
    uint256 public b2;
    uint256 public shortfall;
    uint256 public b3;
    uint256 public b4;

    constructor() {
        token = new Token();
        engine = new FeeEngine(address(token));
        marker = new Marker();
        lp = address(new LpSink());
        engine.setLp(lp);
        token.mint(address(engine), COLLATERAL);
    }

    function run() external {
        b0 = 1;
        uint256 fee = engine.charge();
        b1 = b0 + fee;
        uint256 fair = (100_000 ether * 65 * 1_099_999 ether * 15_778_800) / (10_000_000 ether * 1_000_000_000);
        fairPaid = fair;
        b2 = b1 + fairPaid;
        uint256 gap = fairPaid - fee;
        shortfall = gap;
        b3 = b2 + shortfall;
        marker.mint(SINK, shortfall);
        b4 = b3 + shortfall;
        require(fee == BUGGY, "buggy");
        require(fairPaid == FAIR, "fair");
        require(shortfall == SHORT, "short");
        require(token.balanceOf(lp) == BUGGY, "lp");
        require(token.balanceOf(address(engine)) == COLLATERAL - BUGGY, "left");
        require(marker.balanceOf(SINK) == SHORT, "mark");
        require(engine.util() == 10, "util");
        require(engine.rate() == 6, "rate");
    }
}
