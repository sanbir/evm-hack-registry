// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Burve weight normalization — mulDivX256 reverts when weight == totalWeight
    (Pashov, finding 55213).
    SYNTHETIC, cheatcode-free reduction.
    Root cause: a one-element weight array sets that element equal to
    totalWeight. mulDivX256 requires denominator > numerator, so the swap
    reverts and the 1000 underlying stays in the pool. Two weights (1 and 3
    of total 4) pass the check and the swap pays the trader.
    The blamed require is preserved (@> VULN). */

contract MockERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Sink {}

contract Closure {
    MockERC20 public token;
    uint256[] public weights;
    uint256 public totalWeight;
    uint256 public constant LIQ = 1000 ether;

    constructor(MockERC20 token_, uint256[] memory weights_) {
        token = token_;
        uint256 sum;
        for (uint256 i; i < weights_.length; ++i) {
            weights.push(weights_[i]);
            sum += weights_[i];
        }
        totalWeight = sum;
    }

    function mulDivX256(uint256 num, uint256 denominator) public pure returns (uint256) {
        // @> VULN: equal weight and totalWeight fail denominator > num
        require(denominator > num, "0");
        return num * 1e18 / denominator;
    }

    function normalize() public {
        uint256 n = weights.length;
        for (uint256 i; i < n; ++i) {
            weights[i] = mulDivX256(weights[i], totalWeight);
        }
    }

    function swap(address to) external {
        normalize();
        token.transfer(to, LIQ);
    }
}

contract Exploit {
    MockERC20 public token; // nonce 1
    Closure public pool; // nonce 2
    Closure public control; // nonce 3
    Sink public trader; // nonce 4

    bool public swapReverted;
    uint256 public stuck;
    uint256 public controlPaid;

    constructor() {
        token = new MockERC20();
        uint256[] memory one = new uint256[](1);
        one[0] = 100;
        pool = new Closure(token, one);
        uint256[] memory two = new uint256[](2);
        two[0] = 1;
        two[1] = 3;
        control = new Closure(token, two);
        trader = new Sink();
        token.mint(address(this), 1000 ether);
        token.mint(address(control), 1000 ether);
    }

    function run() external {
        require(pool.weights(0) == pool.totalWeight(), "not a single weight");
        token.transfer(address(pool), 1000 ether);
        try pool.swap(address(trader)) {
            revert("single weight swapped");
        } catch {
            swapReverted = true;
        }
        stuck = token.balanceOf(address(pool));
        require(swapReverted, "swap did not revert");
        require(stuck == 1000 ether, "liquidity did not stay");
        require(token.balanceOf(address(trader)) == 0, "trader was paid");

        control.swap(address(trader));
        controlPaid = token.balanceOf(address(trader));
        require(controlPaid == 1000 ether, "control did not pay the trader");
        require(token.balanceOf(address(control)) == 0, "control pool not empty");
    }
}
