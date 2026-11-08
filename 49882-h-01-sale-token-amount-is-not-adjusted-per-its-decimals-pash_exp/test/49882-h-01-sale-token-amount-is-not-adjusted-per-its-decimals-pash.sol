// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  DefiApp PublicSale — _computeTokens ignores sale-token decimals
    (Pashov Audit Group, finding #49882)
    SYNTHETIC, cheatcode-free. The return is the audited expression.
    1000 USDC at price 0.01e18 should buy 100000 tokens of an 18-decimal
    token (1e23 raw). The function returns 1e11. */

contract MockToken {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        allowance[from][msg.sender] -= amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract PublicSale {
    MockToken public usdc;
    MockToken public saleToken;
    uint256 public constant PRICE = 0.01 ether;
    uint256 public sold;

    constructor(MockToken usdc_, MockToken saleToken_) {
        usdc = usdc_;
        saleToken = saleToken_;
    }

    function depositUSDC(uint256 amount) external {
        usdc.transferFrom(msg.sender, address(this), amount);
        uint256 tokens = _purchase(amount);
        sold = tokens;
        saleToken.transfer(msg.sender, tokens);
    }

    /// Audited path: depositUSDC -> _purchase -> _computeTokens.
    function _purchase(uint256 amount) internal pure returns (uint256) {
        return _computeTokens(amount, PRICE);
    }

    function _computeTokens(uint256 _amountUSDC, uint256 _price) private pure returns (uint256) {
        // _price = price * 10^18 --> precision scaling
        // _amount = (input_amount * 10^6 (USDC/T)) * 10^18 (_price)
        // (_amount * 1e18) / _price = (10^6 * 10^18) / 10^18 = 10^6 precision
        // 10^6 * 10^12 = 10^18 --> scale for future token's decimals
        // @> VULN: the 1e12 scale named in the comment is never applied
        return ((_amountUSDC * 1e18) / _price);
        // FIX: return ((_amountUSDC * 1e18) / _price) * 1e12; // 18-decimal sale token, 6-decimal USDC
    }

    function _computeTokensFixed(uint256 _amountUSDC, uint256 _price) public pure returns (uint256) {
        return ((_amountUSDC * 1e18) / _price) * 1e12;
    }

    function depositUSDCFixed(uint256 amount) external {
        usdc.transferFrom(msg.sender, address(this), amount);
        uint256 tokens = _computeTokensFixed(amount, PRICE);
        sold = tokens;
        saleToken.transfer(msg.sender, tokens);
    }
}

contract Exploit {
    MockToken public usdc; // CREATE nonce 1
    MockToken public home; // CREATE nonce 2
    PublicSale public sale; // CREATE nonce 3

    uint256 public constant PAID = 1000 * 1e6;
    uint256 public constant DUST = 1e11;
    uint256 public constant FAIR = 100000 ether;

    constructor() {
        usdc = new MockToken("USDC", "USDC", 6);
        home = new MockToken("HOME", "HOME", 18);
        sale = new PublicSale(usdc, home);
        home.mint(address(sale), FAIR);
    }

    function run() external {
        usdc.mint(address(this), PAID);
        usdc.approve(address(sale), PAID);
        sale.depositUSDC(PAID);
        uint256 got = home.balanceOf(address(this));
        uint256 fair = sale._computeTokensFixed(PAID, sale.PRICE());
        uint256 spent = usdc.balanceOf(address(sale));
        require(spent == PAID, "usdc");
        require(got == DUST, "dust");
        require(fair == FAIR, "fair");
        require(got * 1e12 == fair, "short 1e12");
    }
}
