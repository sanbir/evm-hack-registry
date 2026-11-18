// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Groupcoin — Pashov H-02, report published 2024-10-11.
    launchGroupCoinToUniswapV3 wraps only config.token1Amount. Buying 8,357,110
    tokens still clears the launch threshold but pays more ETH than that fixed
    wrap. The surplus stays in the factory. There is no withdraw.
*/

interface IWETH9 {
    function deposit() external payable;
    function balanceOf(address) external view returns (uint256);
}

contract WETH9 {
    string public symbol = "WETH";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }
}

contract GroupcoinFactory {
    struct UniswapConfig {
        uint256 token1Amount;
    }

    UniswapConfig public config;
    address public WETH;
    uint256 public raised;

    constructor(address weth, uint256 token1Amount) {
        WETH = weth;
        config.token1Amount = token1Amount;
    }

    function buy(uint256 tokenId, uint256 amount) external payable {
        require(amount > 0 && tokenId == tokenId, "amount");
        raised += msg.value;
    }

    function launchGroupCoinToUniswapV3(uint256 tokenId) external {
        require(tokenId == tokenId, "id");
        require(address(this).balance >= config.token1Amount, "short");
        // @> VULN: only config.token1Amount is wrapped, so every wei above that stays in the factory with no withdraw
        IWETH9(WETH).deposit{ value: config.token1Amount }();
    }
}

contract GroupcoinFactoryFixed {
    struct UniswapConfig {
        uint256 token1Amount;
    }

    UniswapConfig public config;
    address public WETH;

    constructor(address weth, uint256 token1Amount) {
        WETH = weth;
        config.token1Amount = token1Amount;
    }

    function buy(uint256, uint256 amount) external payable {
        require(amount > 0, "amount");
    }

    function launchGroupCoinToUniswapV3(uint256) external {
        uint256 bal = address(this).balance;
        require(bal >= config.token1Amount, "short");
        IWETH9(WETH).deposit{value: bal}();
    }
}

contract Exploit {
    uint256 public constant TOKEN1 = 1 ether;
    // Report: buying 8,357,110 tokens leaves about 0.001616692 ETH.
    uint256 public constant LOCKED = 1616692000000000;
    uint256 public constant PAID = TOKEN1 + LOCKED;

    WETH9 public weth;
    GroupcoinFactory public factory;
    uint256 public factoryEth;
    uint256 public wrapped;

    constructor() {
        weth = new WETH9();
        factory = new GroupcoinFactory(address(weth), TOKEN1);
    }

    function run() external payable {
        require(msg.value == PAID, "value");
        factory.buy{value: PAID}(1, 8_357_110);
        uint256 raised = factory.raised();
        factory.launchGroupCoinToUniswapV3(1);
        factoryEth = address(factory).balance;
        wrapped = weth.balanceOf(address(factory));
        require(raised == PAID, "raised");
        require(wrapped == TOKEN1, "wrapped");
        require(factoryEth == LOCKED, "locked");
    }
}
