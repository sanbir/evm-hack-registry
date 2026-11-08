// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Hyperhyper — option collateral is locked with no unlock when payoff is 0
    (Pashov, Hyperhyper 2025-03-30, C-01). SYNTHETIC, cheatcode-free.
    _lockLiquidity and isPayoffAvailable are the blamed lines (@> VULN).

    A call locks `sizeUa` of the underlying. The only release path is
    exerciseOrLiquidatePosition, and that runs only when isPayoffAvailable:
    payoff > 0 and timestamp inside [maturity, maturity + window].
    A worthless option (payoff 0) fails that check inside the window, and
    this contract has no other withdraw. The locked tokens stay in the pool. */

contract Asset {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] = balanceOf[to] + amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        allowance[from][msg.sender] = allowance[from][msg.sender] - amount;
        balanceOf[from] = balanceOf[from] - amount;
        balanceOf[to] = balanceOf[to] + amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] = balanceOf[msg.sender] - amount;
        balanceOf[to] = balanceOf[to] + amount;
    }
}

contract Pool {
    uint8 public constant CALL = 1;
    uint8 public constant PUT = 2;
    uint256 public constant maturity = 1;
    uint256 public constant exerciseWindow = 7 days;

    Asset public token;
    uint256 public lockedToken;
    uint256 public lockedUsd;

    constructor(Asset _token) {
        token = _token;
    }

    function openCall(uint256 sizeUa) external {
        token.transferFrom(msg.sender, address(this), sizeUa);
        _lockLiquidity(CALL, sizeUa);
    }

    function _lockLiquidity(uint8 opType, uint256 size) internal {
        if (opType == CALL) {
            // @> VULN: locked underlying has no unlock when payoff is 0 or the window is missed.
            lockedToken = lockedToken + size;
        } else if (opType == PUT) {
            lockedUsd = lockedUsd + size;
        }
    }

    /// @dev Payoff is available only for a profitable option inside the window.
    function isPayoffAvailable(uint256 payoff) public view returns (bool) {
        bool inWindow = block.timestamp >= maturity && block.timestamp <= maturity + exerciseWindow;
        bool profitable = payoff > 0;
        return inWindow && profitable;
    }

    function exerciseOrLiquidate(uint256 payoff) external returns (uint256 released) {
        if (!isPayoffAvailable(payoff)) {
            return 0;
        }
        uint256 out = lockedToken;
        lockedToken = 0;
        token.transfer(msg.sender, out);
        return out;
    }
}

contract Exploit {
    uint256 public constant N = 1000 ether;

    Asset public token; // nonce 1
    Pool public pool; // nonce 2
    uint256 public locked;
    bool public exercisable;
    uint256 public released;
    uint256 public stuck;

    constructor() {
        token = new Asset();
        pool = new Pool(token);
    }

    function run() external {
        token.mint(address(this), N);
        token.approve(address(pool), N);
        pool.openCall(N);
        locked = pool.lockedToken();
        exercisable = pool.isPayoffAvailable(0);
        released = pool.exerciseOrLiquidate(0);
        stuck = token.balanceOf(address(pool));
        require(locked == N, "not locked");
        require(exercisable == false, "worthless option looked exercisable");
        require(released == 0, "withdraw succeeded");
        require(stuck == N, "locked tokens left the pool");
        require(token.balanceOf(address(this)) == 0, "depositor got the tokens back");
    }
}
