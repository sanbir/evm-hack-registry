// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  DaosLive finalize — ExactInputSingleParams omits deadline
    (Shieldify, C-02, finding 57867).
    SYNTHETIC, cheatcode-free. One transaction, no warp.

    The audited call does not set deadline, so the field is 0.
    SwapRouter.checkDeadline requires block.timestamp <= deadline.
    0 is before the replay timestamp, the snipe reverts, and 0 of
    the 1000 tokens move. A stored deadline of 0 is the same past
    instant: the fixed router rejects it. Passing block.timestamp
    lets the swap move the 1000 tokens. */

contract SnipeToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

struct ExactInputSingleParams {
    address tokenIn;
    address tokenOut;
    uint24 fee;
    address recipient;
    uint256 amountIn;
    uint256 amountOutMinimum;
    uint160 sqrtPriceLimitX96;
    uint256 deadline;
}

contract SwapRouter {
    SnipeToken public token;

    constructor(SnipeToken token_) {
        token = token_;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external returns (uint256 amountOut) {
        // Uniswap PeripheryValidation.checkDeadline
        require(block.timestamp <= params.deadline, "Transaction too old");
        amountOut = params.amountIn;
        token.mint(params.recipient, amountOut);
        require(amountOut >= params.amountOutMinimum, "Too little received");
    }
}

contract DaosLive {
    SwapRouter public router;
    SnipeToken public token;
    uint256 public snipeAmount;
    uint256 public storedDeadline;
    bool public passNow;

    constructor(SwapRouter router_, SnipeToken token_, uint256 snipeAmount_, bool passNow_) {
        router = router_;
        token = token_;
        snipeAmount = snipeAmount_;
        passNow = passNow_;
    }

    function arm(uint256 deadline) external {
        storedDeadline = deadline;
    }

    function finalize() external returns (uint256 amountOut) {
        // @> VULN: deadline is omitted on the audited struct, so it is 0 and already expired.
        uint256 deadline = passNow ? block.timestamp : 0;
        amountOut = router.exactInputSingle(
            ExactInputSingleParams({
                tokenIn: address(0),
                tokenOut: address(token),
                fee: 3000,
                recipient: address(this),
                amountIn: snipeAmount,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0,
                deadline: deadline
            })
        );
    }

    function finalizeAtStored() external returns (uint256 amountOut) {
        amountOut = router.exactInputSingle(
            ExactInputSingleParams({
                tokenIn: address(0),
                tokenOut: address(token),
                fee: 3000,
                recipient: address(this),
                amountIn: snipeAmount,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0,
                deadline: storedDeadline
            })
        );
    }
}

contract Exploit {
    uint256 public constant N = 1000 ether;

    SnipeToken public token; // nonce 1
    SwapRouter public router; // nonce 2
    DaosLive public dao; // nonce 3

    bool public past;
    bool public snipeReverted;
    uint256 public moved;

    constructor() {
        token = new SnipeToken();
        router = new SwapRouter(token);
        dao = new DaosLive(router, token, N, false);
    }

    function run() external {
        dao.arm(0);
        past = block.timestamp > dao.storedDeadline();
        require(past, "stored deadline is in the past");
        (bool ok,) = address(dao).call(abi.encodeWithSelector(dao.finalize.selector));
        snipeReverted = !ok;
        moved = token.balanceOf(address(dao));
        require(snipeReverted, "snipe reverts");
        require(moved == 0, "0 of N tokens moved");
    }
}
